#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $RepoRoot "config\Config.ps1"
. $configPath

$VmName = [string]$NetworkConfig.GatewayVmName
$runDir = Join-Path $RepoRoot "_run"
$SystemDiskPath = Join-Path $runDir "$VmName-system.vhdx"
$SeedDiskPath = Join-Path $runDir "$VmName-seed.vhdx"

Write-Host "This will permanently destroy:"
Write-Host "  VM:   $VmName"
Write-Host "  Disk: $SystemDiskPath"
Write-Host "  Disk: $SeedDiskPath"
Write-Host ""
$confirm = Read-Host "Type 'y' to confirm"
if ($confirm -ne 'y') {
    Write-Host "Aborted."
    exit 0
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($vm) {
    if ($vm.State -ne "Off") {
        Write-Host "Stopping VM '$VmName'..."
        Stop-VM -Name $VmName -Force
    }
    Write-Host "Removing VM '$VmName'..."
    Remove-VM -Name $VmName -Force
}
else {
    Write-Host "VM '$VmName' not found, skipping."
}

foreach ($path in @($SystemDiskPath, $SeedDiskPath)) {
    if (Test-Path -LiteralPath $path) {
        Write-Host "Deleting $path..."
        Remove-Item -LiteralPath $path -Force
    }
    else {
        Write-Host "Not found, skipping: $path"
    }
}

Write-Host ""
Write-Host "Done."
