#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Init", "Cleanup", "VmNat", "L3Gateway")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$PauseAfterRun = $false
$ShowNetworkStateAfterRun = $false

$RepoRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $RepoRoot "config\Config.ps1"
. $configPath

$InternalSwitchName = $NetworkConfig.InternalSwitchName
$OutboundSwitchName = $NetworkConfig.OutboundSwitchName
$NatSwitchName = $NetworkConfig.NatSwitchName
$BridgeAdapterName = $NetworkConfig.BridgeAdapterName
$OutboundAllowManagementOS = $NetworkConfig.OutboundAllowManagementOS
$HostAddress = $NetworkConfig.HostAddress
$PrefixLength = $NetworkConfig.PrefixLength
$VmGateway = $NetworkConfig.VmGateway
$InternalNatName = "LoopV-$InternalSwitchName"
$L3GatewayRouteMetric = $null
if ($NetworkConfig.ContainsKey("L3GatewayRouteMetric")) {
    $L3GatewayRouteMetric = $NetworkConfig.L3GatewayRouteMetric
}
$VmName = [string]$NetworkConfig.GatewayVmName

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script from an elevated PowerShell session."
    }
}

function Wait-HostVNic {
    param([string]$Name)

    $alias = "vEthernet ($Name)"
    for ($i = 0; $i -lt 30; $i++) {
        $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        if ($adapter) {
            return $alias
        }
        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for host adapter '$alias'."
}

function Ensure-InternalSwitch {
    param([string]$Name)

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.SwitchType -eq "Internal") {
        Write-Host "VMSwitch '$Name' is already Internal."
        return
    }

    if ($existing) {
        Write-Host "Changing VMSwitch '$Name' from $($existing.SwitchType) to Internal..."
        Set-VMSwitch -Name $Name -SwitchType Internal | Out-Null
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "Creating Internal VMSwitch '$Name'..."
    New-VMSwitch -Name $Name -SwitchType Internal | Out-Null
    Start-Sleep -Seconds 2
}

function Ensure-PrivateSwitch {
    param([string]$Name)

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.SwitchType -eq "Private") {
        Write-Host "VMSwitch '$Name' is already Private."
        return
    }

    if ($existing) {
        Write-Host "Changing VMSwitch '$Name' from $($existing.SwitchType) to Private..."
        # Set-VMSwitch -SwitchType can fail with 0x80071A2D (transaction not active)
        # if a preceding Connect-VMNetworkAdapter left an NDIS transaction in flight.
        # Retry with backoff to let the transaction settle.
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Set-VMSwitch -Name $Name -SwitchType Private | Out-Null
                break
            } catch {
                if ($i -eq 4) { throw }
                Write-Host "Set-VMSwitch failed (attempt $($i+1)/5), retrying in 3s..."
                Start-Sleep -Seconds 3
            }
        }
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "Creating Private VMSwitch '$Name'..."
    New-VMSwitch -Name $Name -SwitchType Private | Out-Null
    Start-Sleep -Seconds 2
}

function Ensure-ExternalSwitch {
    param(
        [string]$Name,
        [string]$AdapterName,
        [bool]$AllowManagementOS
    )

    $hostAdapter = Get-NetAdapter -Name $AdapterName
    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    Enable-NetAdapterBinding -Name $AdapterName -ComponentID "vms_pp" -ErrorAction SilentlyContinue

    if ($existing -and
        $existing.SwitchType -eq "External" -and
        $existing.NetAdapterInterfaceDescription -eq $hostAdapter.InterfaceDescription -and
        $existing.AllowManagementOS -eq $AllowManagementOS) {
        Write-Host "VMSwitch '$Name' is already External on '$AdapterName'."
        Assert-ExternalSwitchManagementOS -Name $Name -Expected $AllowManagementOS
        return
    }

    if ($existing) {
        Write-Host "Changing VMSwitch '$Name' to External on host adapter '$AdapterName'..."
        Set-VMSwitch -Name $Name -NetAdapterName $AdapterName -AllowManagementOS $AllowManagementOS | Out-Null
        Set-VMSwitch -Name $Name -AllowManagementOS $AllowManagementOS | Out-Null
        Start-Sleep -Seconds 2
        Assert-ExternalSwitchManagementOS -Name $Name -Expected $AllowManagementOS
        return
    }

    Write-Host "Creating External VMSwitch '$Name' on host adapter '$AdapterName'..."
    New-VMSwitch -Name $Name -NetAdapterName $AdapterName -AllowManagementOS $AllowManagementOS | Out-Null
    Set-VMSwitch -Name $Name -AllowManagementOS $AllowManagementOS | Out-Null
    Start-Sleep -Seconds 2
    Assert-ExternalSwitchManagementOS -Name $Name -Expected $AllowManagementOS
}

function Assert-ExternalSwitchManagementOS {
    param(
        [string]$Name,
        [bool]$Expected
    )

    $switch = Get-VMSwitch -Name $Name
    if ($switch.SwitchType -ne "External") {
        throw "VMSwitch '$Name' is $($switch.SwitchType), expected External."
    }

    if ($switch.AllowManagementOS -ne $Expected) {
        throw "Failed to apply OutboundAllowManagementOS for '$Name'. Actual value is $($switch.AllowManagementOS), expected config value $Expected."
    }
}

function Set-L3GatewayHostNetwork {
    param(
        [string]$Name,
        [string]$Address,
        [int]$Prefix,
        [string]$Gateway,
        [Nullable[int]]$RouteMetric
    )

    $alias = Wait-HostVNic -Name $Name

    Write-Host "Configuring '$alias' with static IP $Address/$Prefix and gateway $Gateway..."
    Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false

    Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false

    Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $Address -PrefixLength $Prefix -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $Gateway

    if ($null -ne $RouteMetric) {
        Write-Host "Setting default route metric on '$alias' to $RouteMetric..."
        Set-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -NextHop $Gateway -RouteMetric $RouteMetric
    }
}

function Set-InternalHostNetwork {
    param(
        [string]$Name,
        [string]$Address,
        [int]$Prefix
    )

    $alias = Wait-HostVNic -Name $Name

    Write-Host "Configuring '$alias' as internal host-to-VM network $Address/$Prefix with no default gateway..."
    Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false

    Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false

    Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $Address -PrefixLength $Prefix | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses
}

function Clear-SwitchHostNetwork {
    param([string]$Name)

    $alias = Wait-HostVNic -Name $Name

    Write-Host "Clearing default route and DNS on '$alias'..."
    Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses
}

function Reset-SwitchHostNetworkToDhcp {
    param([string]$Name)

    $alias = "vEthernet ($Name)"
    $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Host "Host switch adapter '$alias' does not exist."
        return
    }

    Write-Host "Resetting '$alias' to DHCP and default DNS..."
    Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false
    Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses
}

function Remove-LegacyNetworkBridgeForAdapter {
    param([string]$AdapterName)

    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
    if (-not $adapter.MacAddress) {
        throw "Cannot identify legacy Network Bridge for '$AdapterName' because the adapter has no MAC address."
    }

    # A stale Windows Network Bridge can keep TCP/IP on its multiplexor adapter
    # after the Hyper-V external switch binding has already been released.
    $bridges = @(
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceDescription -eq "Microsoft Network Adapter Multiplexor Driver" -and
                $_.MacAddress -eq $adapter.MacAddress
            }
    )

    foreach ($bridge in $bridges) {
        $bridgeGuid = ([guid]$bridge.InterfaceGuid).ToString("B")
        Write-Host "Destroying stale Network Bridge '$($bridge.Name)' ($bridgeGuid) for '$AdapterName'..."
        & netsh.exe bridge destroy $bridgeGuid | Out-Host
        $destroyExitCode = $LASTEXITCODE

        for ($i = 0; $i -lt 30; $i++) {
            $remaining = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceGuid -eq $bridge.InterfaceGuid }
            if (-not $remaining) { break }
            Start-Sleep -Seconds 1
        }

        if ($remaining) {
            throw "Failed to destroy stale Network Bridge '$($bridge.Name)' ($bridgeGuid); netsh exit code was $destroyExitCode."
        }

        if ($destroyExitCode -ne 0) {
            Write-Warning "netsh returned exit code $destroyExitCode, but Network Bridge '$($bridge.Name)' was removed successfully."
        }
    }
}

function Release-HostAdapter {
    param([string]$AdapterName)

    $adapter = $null
    for ($i = 0; $i -lt 8; $i++) {
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if ($adapter) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $adapter) {
        Write-Host "Host adapter '$AdapterName' is not currently visible. Skipping binding release."
        return
    }

    $binding = Get-NetAdapterBinding -Name $AdapterName -ComponentID "vms_pp" -ErrorAction SilentlyContinue
    if ($binding -and $binding.Enabled) {
        Write-Host "Disabling Hyper-V external switch binding on '$AdapterName'..."
        Disable-NetAdapterBinding -Name $AdapterName -ComponentID "vms_pp" -ErrorAction SilentlyContinue
    }

    Remove-LegacyNetworkBridgeForAdapter -AdapterName $AdapterName

    $multiplexorBinding = Get-NetAdapterBinding -Name $AdapterName -ComponentID "ms_implat" -ErrorAction SilentlyContinue
    if ($multiplexorBinding -and $multiplexorBinding.Enabled) {
        Write-Host "Disabling stale multiplexor binding on '$AdapterName'..."
        Disable-NetAdapterBinding -Name $AdapterName -ComponentID "ms_implat" -ErrorAction Stop
    }

    foreach ($componentId in @("ms_tcpip", "ms_tcpip6")) {
        $protocolBinding = Get-NetAdapterBinding -Name $AdapterName -ComponentID $componentId -ErrorAction SilentlyContinue
        if ($protocolBinding -and -not $protocolBinding.Enabled) {
            Write-Host "Enabling '$componentId' on '$AdapterName'..."
            Enable-NetAdapterBinding -Name $AdapterName -ComponentID $componentId -ErrorAction Stop
        }
    }

    # Restart the adapter to force a full NDIS stack rebuild. This is more reliable
    # than rebinding ms_tcpip because vms_pp removal leaves the NDIS stack in a
    # transitional state where protocol-level rebinds can race and not take effect.
    Write-Host "Restarting '$AdapterName' to reapply stored IP configuration..."
    Disable-NetAdapter -Name $AdapterName -Confirm:$false
    Start-Sleep -Seconds 2
    Enable-NetAdapter -Name $AdapterName -Confirm:$false

    Write-Host "Waiting for '$AdapterName' to come back up..."
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $current = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if ($current -and $current.Status -eq "Up") { break }
    }

    if (-not $current -or $current.Status -ne "Up") {
        throw "Timed out waiting for '$AdapterName' to come back up."
    }

    Set-NetIPInterface -InterfaceAlias $AdapterName -AddressFamily IPv4 -Dhcp Enabled

    Write-Host "Waiting for '$AdapterName' to obtain an IPv4 address and default route..."
    for ($i = 0; $i -lt 30; $i++) {
        $address = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.AddressState -eq "Preferred" -and $_.IPAddress -notlike "169.254.*" } |
            Select-Object -First 1
        $defaultRoute = Get-NetRoute -InterfaceAlias $AdapterName -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq "Alive" } |
            Select-Object -First 1
        if ($address -and $defaultRoute) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $address -or -not $defaultRoute) {
        throw "'$AdapterName' did not obtain both an IPv4 address and a default route after bridge cleanup."
    }

    Write-Host "'$AdapterName' is using $($address.IPAddress) with gateway $($defaultRoute.NextHop)."
}

function Remove-LoopVSwitch {
    param([string]$Name)

    $switch = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if (-not $switch) {
        Write-Host "VMSwitch '$Name' does not exist."
        return
    }

    Write-Host "Removing VMSwitch '$Name'..."
    Remove-VMSwitch -Name $Name -Force
}

function Convert-IPv4ToUInt32 {
    param([string]$Address)

    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4 {
    param([uint32]$Address)

    $bytes = [BitConverter]::GetBytes($Address)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-IPv4Prefix {
    param(
        [string]$Address,
        [int]$Prefix
    )

    if ($Prefix -lt 0 -or $Prefix -gt 32) {
        throw "Invalid IPv4 prefix length: $Prefix"
    }

    $addressValue = Convert-IPv4ToUInt32 -Address $Address
    $mask = if ($Prefix -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $Prefix)) }
    $networkValue = $addressValue -band $mask
    return "$(Convert-UInt32ToIPv4 -Address $networkValue)/$Prefix"
}

function Remove-InternalNat {
    param([string]$Name)

    $existing = Get-NetNat -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Removing NAT '$Name'..."
        Remove-NetNat -Name $Name -Confirm:$false
    }
}

function Set-InternalNat {
    param(
        [string]$Name,
        [string]$Address,
        [int]$Prefix,
        [bool]$Enabled
    )

    $natPrefix = Get-IPv4Prefix -Address $Address -Prefix $Prefix

    if (-not $Enabled) {
        Remove-InternalNat -Name $Name
        return
    }

    $existing = Get-NetNat -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.InternalIPInterfaceAddressPrefix -eq $natPrefix) {
        Write-Host "NAT '$Name' is already configured for $natPrefix."
        return
    }

    if ($existing) {
        Write-Host "Replacing NAT '$Name' with prefix $natPrefix..."
        Remove-NetNat -Name $Name -Confirm:$false
    }
    else {
        Write-Host "Creating NAT '$Name' for $natPrefix..."
    }

    New-NetNat -Name $Name -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null
}

function Connect-VmOutboundAdapter {
    param(
        [string]$VmName,
        [string]$SwitchName
    )

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM '$VmName' not found. Skipping outbound adapter switch connection."
        return
    }

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $switch) {
        throw "VMSwitch '$SwitchName' not found."
    }

    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name "outbound" -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Host "Creating VM '$VmName' outbound adapter..."
        Add-VMNetworkAdapter -VMName $VmName -Name "outbound"
    }

    Write-Host "Connecting VM '$VmName' outbound adapter to '$SwitchName'..."
    Connect-VMNetworkAdapter -VMName $VmName -Name "outbound" -SwitchName $SwitchName
}

function Show-NetworkState {
    param(
        [string]$InternalName,
        [string]$OutboundName,
        [string]$AdapterName
    )

    $aliases = @(
        $AdapterName
        "vEthernet ($InternalName)"
        "vEthernet ($OutboundName)"
    ) | Select-Object -Unique

    Write-Host ""
    Write-Host "===== Network mode state ====="

    Write-Host ""
    Write-Host "[VMSwitch]"
    @($InternalName, $OutboundName) |
        ForEach-Object { Get-VMSwitch -Name $_ -ErrorAction SilentlyContinue } |
        Select-Object Name, SwitchType, NetAdapterInterfaceDescription, AllowManagementOS |
        Format-Table -AutoSize | Out-Host

    Write-Host "[Adapters]"
    Get-NetAdapter -Name $aliases -ErrorAction SilentlyContinue |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex |
        Format-Table -AutoSize | Out-Host

    Write-Host "[IPv4]"
    Get-NetIPConfiguration |
        Where-Object { $_.InterfaceAlias -in $aliases } |
        Select-Object InterfaceAlias, InterfaceIndex, IPv4Address, IPv4DefaultGateway, DNSServer |
        Format-List | Out-Host

    Write-Host "[IPv4 default routes]"
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -in $aliases } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object InterfaceAlias, NextHop, RouteMetric, InterfaceMetric, PolicyStore |
        Format-Table -AutoSize | Out-Host

    Write-Host "[NAT]"
    Get-NetNat -Name $InternalNatName -ErrorAction SilentlyContinue |
        Select-Object Name, InternalIPInterfaceAddressPrefix |
        Format-Table -AutoSize | Out-Host

    Write-Host "[Host adapter Hyper-V binding]"
    Get-NetAdapterBinding -Name $AdapterName -ComponentID "vms_pp" -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, ComponentID, Enabled |
        Format-Table -AutoSize | Out-Host
}

function Wait-BeforeExit {
    param([bool]$Enabled)

    if ($Enabled) {
        Write-Host ""
        Read-Host "Press Enter to exit"
    }
}

function Use-L3GatewayMode {
    Remove-InternalNat -Name $InternalNatName

    Ensure-InternalSwitch -Name $InternalSwitchName
    Set-L3GatewayHostNetwork `
        -Name $InternalSwitchName `
        -Address $HostAddress `
        -Prefix $PrefixLength `
        -Gateway $VmGateway `
        -RouteMetric $L3GatewayRouteMetric

    Ensure-ExternalSwitch `
        -Name $OutboundSwitchName `
        -AdapterName $BridgeAdapterName `
        -AllowManagementOS $OutboundAllowManagementOS
    Connect-VmOutboundAdapter -VmName $VmName -SwitchName $OutboundSwitchName

    Write-Host ""
    Write-Host "L3Gateway mode is active."
    Write-Host "'$InternalSwitchName' is the host-to-VM network. VM '$VmName' outbound is connected to External switch '$OutboundSwitchName' on host adapter '$BridgeAdapterName'."
}

function Use-VmNatMode {
    # Disconnect VM from LoopvNet-out before changing its type.
    # Set-VMSwitch fails if any VM adapter is still connected to the switch.
    Connect-VmOutboundAdapter -VmName $VmName -SwitchName $NatSwitchName

    Ensure-InternalSwitch -Name $InternalSwitchName
    Set-InternalHostNetwork -Name $InternalSwitchName -Address $HostAddress -Prefix $PrefixLength
    Remove-InternalNat -Name $InternalNatName

    Ensure-PrivateSwitch -Name $OutboundSwitchName
    Clear-SwitchHostNetwork -Name $InternalSwitchName

    Release-HostAdapter -AdapterName $BridgeAdapterName

    Write-Host ""
    Write-Host "VmNat mode is active."
    Write-Host "VM '$VmName' outbound is connected to '$NatSwitchName'. Host adapter '$BridgeAdapterName' is released for native DHCP."
}

function Use-InitMode {
    Ensure-InternalSwitch -Name $InternalSwitchName
    Set-InternalHostNetwork -Name $InternalSwitchName -Address $HostAddress -Prefix $PrefixLength

    Ensure-PrivateSwitch -Name $OutboundSwitchName

    Write-Host ""
    Write-Host "Network init is complete."
    Write-Host "'$InternalSwitchName' is Internal with host address $HostAddress/$PrefixLength."
    Write-Host "'$OutboundSwitchName' is a Private placeholder switch. It is not visible to the host OS."
}

function Use-CleanupMode {
    Remove-InternalNat -Name $InternalNatName

    Connect-VmOutboundAdapter -VmName $VmName -SwitchName $NatSwitchName

    Remove-LoopVSwitch -Name $OutboundSwitchName
    Remove-LoopVSwitch -Name $InternalSwitchName

    Release-HostAdapter -AdapterName $BridgeAdapterName

    Write-Host ""
    Write-Host "Network cleanup is complete."
}

Assert-Admin

if ($PSCmdlet.ShouldProcess("$InternalSwitchName / $OutboundSwitchName", "switch to $Mode")) {
    switch ($Mode) {
        "Init" { Use-InitMode }
        "Cleanup" { Use-CleanupMode }
        "L3Gateway" { Use-L3GatewayMode }
        "VmNat" { Use-VmNatMode }
    }

    if ($ShowNetworkStateAfterRun) {
        Show-NetworkState -InternalName $InternalSwitchName -OutboundName $OutboundSwitchName -AdapterName $BridgeAdapterName
    }

    Wait-BeforeExit -Enabled $PauseAfterRun
}
