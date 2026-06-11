#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $RepoRoot "config\Config.ps1"
. $configPath

function Resolve-RepoPath {
    param([string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    Join-Path $RepoRoot $Path
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script from an elevated PowerShell session."
    }
}

function Get-FreeDriveLetter {
    $used = Get-Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }
    foreach ($letter in [char[]]([char]'S'..[char]'Z')) {
        if ($letter -notin $used) {
            return [string]$letter
        }
    }

    throw "Cannot find a free drive letter for the cloud-init seed disk."
}

function ConvertTo-Base64Text {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value.Replace("`r`n", "`n")))
}

function Expand-Template {
    param(
        [string]$Template,
        [hashtable]$Values
    )

    $result = $Template
    foreach ($key in $Values.Keys) {
        $result = $result.Replace("{{${key}}}", [string]$Values[$key])
    }

    $result
}

function New-CloudInitSeedDisk {
    param(
        [string]$Path,
        [int]$SizeMB,
        [System.Collections.IDictionary]$Files
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Host "Seed disk already exists, skipping: $Path"
        return
    }

    foreach ($fileName in @("user-data", "meta-data", "network-config")) {
        if (-not $Files.Contains($fileName)) {
            throw "Missing cloud-init seed file content: $fileName"
        }
    }

    Write-Host "Creating cloud-init seed disk..."
    New-VHD -Path $Path -SizeBytes ($SizeMB * 1MB) -Dynamic | Out-Null

    $mount = Mount-VHD -Path $Path -Passthru
    try {
        $diskNumber = $mount.DiskNumber
        $disk = Get-Disk -Number $diskNumber
        if ($disk.PartitionStyle -eq "RAW") {
            Initialize-Disk -Number $diskNumber -PartitionStyle MBR
            $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize
            Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel "cidata" -Confirm:$false | Out-Null
        }
        else {
            $partition = Get-Partition -DiskNumber $diskNumber | Select-Object -First 1
        }

        $volume = Get-Volume -Partition $partition

        if (-not $volume.DriveLetter) {
            $partition | Set-Partition -NewDriveLetter (Get-FreeDriveLetter)
            $volume = Get-Volume -Partition $partition
        }

        $seedRoot = "$($volume.DriveLetter):\"

        foreach ($fileName in $Files.Keys) {
            $noNewline = $fileName -eq "user-data"
            Set-Content -Path (Join-Path $seedRoot $fileName) -Value $Files[$fileName] -Encoding ascii -NoNewline:$noNewline
        }
    }
    finally {
        Dismount-VHD -Path $Path
    }
}

function Connect-AdapterIfSwitchExists {
    param(
        [string]$VmName,
        [string]$AdapterName,
        [string]$SwitchName
    )

    if ([string]::IsNullOrWhiteSpace($SwitchName)) {
        Write-Host "No switch configured for '$AdapterName'. Leaving adapter disconnected."
        return
    }

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $switch) {
        Write-Host "VMSwitch '$SwitchName' not found. Leaving '$AdapterName' disconnected."
        return
    }

    Connect-VMNetworkAdapter -VMName $VmName -Name $AdapterName -SwitchName $SwitchName
}

function Ensure-VMNetworkAdapter {
    param(
        [string]$VmName,
        [string]$AdapterName
    )

    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $AdapterName -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Add-VMNetworkAdapter -VMName $VmName -Name $AdapterName
        return
    }
}

function Ensure-VMHardDiskDrive {
    param(
        [string]$VmName,
        [string]$Path
    )

    $existing = Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -eq $Path }
    if ($existing) {
        Write-Host "Disk already attached: $Path"
        return
    }

    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $Path
}

function Ensure-VMSystemDisk {
    param(
        [string]$VmName,
        [string]$Path
    )

    $existing = Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -eq $Path }
    if ($existing) {
        Write-Host "System disk already attached: $Path"
        return
    }

    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $Path
}

Assert-Admin

$VmName = [string]$NetworkConfig.GatewayVmName
$InternalSwitchName = [string]$NetworkConfig.InternalSwitchName
$NatSwitchName = [string]$NetworkConfig.NatSwitchName
$VmGateway = [string]$NetworkConfig.VmGateway
$VmMemoryMB = [int]$VMCreateConfig.VmMemoryMB
$MemoryMinimumMB = [Math]::Min(512, $VmMemoryMB)
$EnableCloudInit = [bool]$CloudInitConfig.EnableCloudInit

$vmDir = Join-Path $RepoRoot "_run"
$SystemDiskPath = Join-Path $vmDir "$VmName-system.vhdx"
$SeedDiskPath = Join-Path $vmDir "$VmName-seed.vhdx"

New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

if ($EnableCloudInit) {
    $ImagePath = Resolve-RepoPath ([string]$CloudInitConfig.ImagePath)
    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw "VHDX image not found: $ImagePath"
    }
    if (-not (Test-Path -LiteralPath $SystemDiskPath)) {
        Write-Host "Creating differencing disk from base image..."
        New-VHD -Path $SystemDiskPath -ParentPath $ImagePath -Differencing | Out-Null
    }
} elseif (-not (Test-Path -LiteralPath $SystemDiskPath)) {
    throw "System disk not found and EnableCloudInit is false: $SystemDiskPath"
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "Creating VM '$VmName'..."
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($VmMemoryMB * 1MB) -VHDPath $SystemDiskPath | Out-Null
}
else {
    Write-Host "VM '$VmName' already exists. Updating configuration..."
    Ensure-VMSystemDisk -VmName $VmName -Path $SystemDiskPath
}

Set-VM -Name $VmName `
    -ProcessorCount ([int]$VMCreateConfig.ProcessorCount) `
    -CheckpointType Disabled `
    -DynamicMemory `
    -MemoryMinimumBytes ($MemoryMinimumMB * 1MB) `
    -MemoryStartupBytes ($VmMemoryMB * 1MB) `
    -MemoryMaximumBytes ($VmMemoryMB * 1MB) `
    -AutomaticStartAction Start `
    -AutomaticStartDelay 0
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
Set-VMComPort -VMName $VmName -Number 1 -Path "\\.\pipe\$VmName-com1"

$defaultAdapter = Get-VMNetworkAdapter -VMName $VmName -Name "Network Adapter" -ErrorAction SilentlyContinue
if ($defaultAdapter -and -not (Get-VMNetworkAdapter -VMName $VmName -Name "internal" -ErrorAction SilentlyContinue)) {
    Rename-VMNetworkAdapter -VMName $VmName -Name "Network Adapter" -NewName "internal"
}

Ensure-VMNetworkAdapter -VmName $VmName -AdapterName "internal"
Connect-AdapterIfSwitchExists -VmName $VmName -AdapterName "internal" -SwitchName $InternalSwitchName

Ensure-VMNetworkAdapter -VmName $VmName -AdapterName "outbound"
Connect-AdapterIfSwitchExists -VmName $VmName -AdapterName "outbound" -SwitchName $NatSwitchName

if ($EnableCloudInit) {
    $CloudInitDir = Resolve-RepoPath ([string]$CloudInitConfig.CloudInitDir)
    $VmUser = [string]$CloudInitConfig.VmUser
    $VmPassword = [string]$CloudInitConfig.VmPassword

    $sshPublicKeyPaths = @()
    if ($CloudInitConfig.ContainsKey("SshPublicKeyPath") -and $null -ne $CloudInitConfig.SshPublicKeyPath) {
        $sshPublicKeyPaths = @($CloudInitConfig.SshPublicKeyPath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Resolve-RepoPath ([string]$_) })
    }

    $sshPublicKeys = @()
    foreach ($sshPublicKeyPath in $sshPublicKeyPaths) {
        if (Test-Path -LiteralPath $sshPublicKeyPath) {
            $sshPublicKey = (Get-Content -LiteralPath $sshPublicKeyPath -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($sshPublicKey)) {
                $sshPublicKeys += $sshPublicKey
                Write-Host "SSH public key found: $sshPublicKeyPath"
            }
            else {
                Write-Host "SSH public key is empty, skipping: $sshPublicKeyPath"
            }
        }
        else {
            Write-Host "SSH public key not found, skipping: $sshPublicKeyPath"
        }
    }

    if ($sshPublicKeys.Count -eq 0) {
        Write-Host "No SSH public keys found. Creating VM without SSH key injection."
    }

    # Base64 every raw file under vm-files (normalized to LF) into the file map.
    $vmFilesDir = Resolve-RepoPath "vm-files"
    $files = [ordered]@{}
    foreach ($file in (Get-ChildItem -LiteralPath $vmFilesDir -File | Sort-Object Name)) {
        $files[$file.Name] = ConvertTo-Base64Text -Value (Get-Content -LiteralPath $file.FullName -Raw)
    }

    # meta-data carries all Config.ps1 settings plus the file payloads. user-data
    # consumes them in-guest via jinja (ds.meta_data.*). JSON is valid YAML, so
    # cloud-init parses it without any extra tooling on the host side.
    $metaData = [ordered]@{
        # Required datasource field; no cloud-config equivalent, so it stays here.
        # hostname comes from user-data, so local-hostname is omitted.
        "instance-id"         = [string]$NetworkConfig.GatewayVmName
        "NetworkConfig"       = $NetworkConfig
        "VMCreateConfig"      = $VMCreateConfig
        "CloudInitConfig"     = $CloudInitConfig
        "SshAuthorizedKeys" = @($sshPublicKeys)
        "VmFiles"               = $files
    }
    $metaDataText = $metaData | ConvertTo-Json -Depth 12

    # Keep a copy for debugging/inspection.
    Set-Content -LiteralPath (Join-Path $vmDir "meta-data") -Value $metaDataText -Encoding ascii
    Write-Host "Wrote meta-data for inspection: $(Join-Path $vmDir 'meta-data')"

    # network-config is not jinja-rendered in-guest, so expand it host-side.
    $networkConfigTemplate = Get-Content -LiteralPath (Join-Path $CloudInitDir "network-config") -Raw
    $networkConfigText = Expand-Template -Template $networkConfigTemplate -Values $NetworkConfig

    $cloudInitFiles = [ordered]@{
        "user-data"      = (Get-Content -LiteralPath (Join-Path $CloudInitDir "user-data") -Raw).Replace("`r`n", "`n")
        "meta-data"      = $metaDataText
        "network-config" = $networkConfigText
    }

    New-CloudInitSeedDisk -Path $SeedDiskPath -SizeMB ([int]$CloudInitConfig.SeedDiskSizeMB) -Files $cloudInitFiles
    Ensure-VMHardDiskDrive -VmName $VmName -Path $SeedDiskPath
}

Write-Host ""
Write-Host "Done."
Write-Host "VM: $VmName"
if ($EnableCloudInit) {
    Write-Host "Console login: $VmUser / $VmPassword"
}

Write-Host ""
Write-Host "Starting VM '$VmName'..."
try {
    Start-VM -Name $VmName
    Write-Host "VM started."
}
catch {
    Write-Host "WARNING: Failed to start VM: $_"
    Write-Host "Start it manually: Start-VM -Name '$VmName'"
}

if ($EnableCloudInit -and $sshPublicKeys.Count -gt 0) {
    Write-Host ""
    Write-Host "SSH (after cloud-init completes):"
    Write-Host "  ssh -i `"$((Join-Path $RepoRoot "_run\vm_ssh_key"))`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VmUser}@$VmGateway"
}
