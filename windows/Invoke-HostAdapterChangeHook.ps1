[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$EnableHookLog = $false

$RepoRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $RepoRoot "config\Config.ps1"
. $configPath

$logDir = Join-Path $RepoRoot "logs"
$logPath = Join-Path $logDir "HostAdapterChangeHook.log"
$outputPath = Join-Path $logDir "HostAdapterChangeHook.last.out"

function Write-HookLog {
    param([string]$Message)

    if (-not $EnableHookLog) {
        return
    }

    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logPath -Value "[$timestamp] $Message"
}

try {
    $OutboundSwitchName = $NetworkConfig.OutboundSwitchName
    $BridgeAdapterName = $NetworkConfig.BridgeAdapterName
    $OutboundAllowManagementOS = [bool]$NetworkConfig.OutboundAllowManagementOS

    if ([string]::IsNullOrWhiteSpace($OutboundSwitchName)) {
        throw "OutboundSwitchName is empty."
    }
    if ([string]::IsNullOrWhiteSpace($BridgeAdapterName)) {
        throw "BridgeAdapterName is empty."
    }

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, "Global\LoopVHostAdapterChangeHook", [ref]$createdNew)
    if (-not $mutex.WaitOne(0)) {
        Write-HookLog "Another hook run is already active; skipping."
        exit 0
    }

    try {
        $hostAdapter = Get-NetAdapter -Name $BridgeAdapterName

        Write-HookLog "Reconnecting VMSwitch '$OutboundSwitchName' on host adapter '$BridgeAdapterName'."

        $existing = Get-VMSwitch -Name $OutboundSwitchName -ErrorAction SilentlyContinue
        if ($existing) {
            Set-VMSwitch -Name $OutboundSwitchName -SwitchType Internal | Out-Null
            Start-Sleep -Seconds 2
        }
        else {
            New-VMSwitch -Name $OutboundSwitchName -SwitchType Internal | Out-Null
            Start-Sleep -Seconds 2
        }

        Enable-NetAdapterBinding -Name $BridgeAdapterName -ComponentID "vms_pp" -ErrorAction SilentlyContinue
        Set-VMSwitch -Name $OutboundSwitchName -NetAdapterName $BridgeAdapterName -AllowManagementOS $OutboundAllowManagementOS | Out-Null
        Set-VMSwitch -Name $OutboundSwitchName -AllowManagementOS $OutboundAllowManagementOS | Out-Null
        Start-Sleep -Seconds 2

        $switch = Get-VMSwitch -Name $OutboundSwitchName
        if ($switch.SwitchType -ne "External") {
            throw "VMSwitch '$OutboundSwitchName' is $($switch.SwitchType), expected External."
        }
        if ($switch.NetAdapterInterfaceDescription -ne $hostAdapter.InterfaceDescription) {
            throw "VMSwitch '$OutboundSwitchName' is not attached to '$BridgeAdapterName'."
        }
        if ($switch.AllowManagementOS -ne $OutboundAllowManagementOS) {
            throw "Failed to apply OutboundAllowManagementOS for '$OutboundSwitchName'. Actual value is $($switch.AllowManagementOS), expected config value $OutboundAllowManagementOS."
        }

        Write-HookLog "Reconnected VMSwitch '$OutboundSwitchName'."
        exit 0
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
catch {
    Write-HookLog "ERROR: $($_.Exception.Message)"
    throw
}
