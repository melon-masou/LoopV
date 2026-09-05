#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $RepoRoot "config\Config.ps1"
. $configPath

$portForwards = @()
if (Test-Path variable:WslPortForwards) {
    $portForwards = @($WslPortForwards)
}

if ($portForwards.Count -eq 0) {
    exit 0
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class LoopVHcn
{
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)]
    public static extern int HcnOpenEndpoint(
        ref Guid id,
        out IntPtr endpoint,
        out IntPtr errorRecord);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)]
    public static extern int HcnModifyEndpoint(
        IntPtr endpoint,
        string settings,
        out IntPtr errorRecord);

    [DllImport("computenetwork.dll")]
    public static extern int HcnCloseEndpoint(IntPtr endpoint);
}
"@

function Read-HcnString {
    param([IntPtr]$Pointer)

    if ($Pointer -eq [IntPtr]::Zero) {
        return ""
    }

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($Pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($Pointer)
    }
}

function ConvertTo-ProtocolNumber {
    param([object]$Protocol)

    switch ([string]$Protocol) {
        "TCP" { return 6 }
        "UDP" { return 17 }
        default { throw "Unsupported protocol '$Protocol'." }
    }
}

$wslEndpoint = Get-HnsEndpoint |
    Where-Object {
        $_.VirtualNetworkName -like "WSL*" -and
        $_.State -eq 2 -and
        $_.IPAddress -and
        $_.GatewayAddress
    } |
    Select-Object -First 1

if ($null -eq $wslEndpoint) {
    Write-Warning "No active WSL NAT endpoint found."
    exit 0
}

$endpointId = [Guid]$wslEndpoint.ID
$endpointHandle = [IntPtr]::Zero
$errorPointer = [IntPtr]::Zero
$openResult = [LoopVHcn]::HcnOpenEndpoint(
    [ref]$endpointId,
    [ref]$endpointHandle,
    [ref]$errorPointer)
$openError = Read-HcnString $errorPointer

if ($openResult -lt 0) {
    Write-Warning "Cannot open WSL HNS endpoint: $openError"
    exit 0
}

try {
    foreach ($rule in $portForwards) {
        try {
            $protocol = ConvertTo-ProtocolNumber $rule.Protocol
            $hostPort = [int]$rule.HostPort
            $guestPort = [int]$rule.GuestPort
            $policies = @()
            $allowedRemoteAddresses = @(
                @($rule.AllowedRemoteAddresses) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
            )

            if ($allowedRemoteAddresses.Count -gt 0) {
                $policies += [ordered]@{
                    Type = "ACL"
                    Settings = [ordered]@{
                        Protocols = [string]$protocol
                        Action = "Allow"
                        Direction = "In"
                        RemoteAddresses = $allowedRemoteAddresses -join ","
                        LocalPorts = [string]$guestPort
                        RuleType = "Host"
                        Priority = 100
                    }
                }
                $policies += [ordered]@{
                    Type = "ACL"
                    Settings = [ordered]@{
                        Protocols = [string]$protocol
                        Action = "Block"
                        Direction = "In"
                        RemoteAddresses = "0.0.0.0/0"
                        LocalPorts = [string]$guestPort
                        RuleType = "Host"
                        Priority = 200
                    }
                }
            }

            $policies += [ordered]@{
                Type = "PortMapping"
                Settings = [ordered]@{
                    Protocol = $protocol
                    InternalPort = $guestPort
                    ExternalPort = $hostPort
                }
            }

            $request = [ordered]@{
                ResourceType = "Policy"
                RequestType = "Add"
                Settings = [ordered]@{
                    Policies = $policies
                }
            } | ConvertTo-Json -Depth 12 -Compress

            $errorPointer = [IntPtr]::Zero
            $result = [LoopVHcn]::HcnModifyEndpoint(
                $endpointHandle,
                $request,
                [ref]$errorPointer)
            $errorRecord = Read-HcnString $errorPointer

            if ($result -lt 0) {
                Write-Warning "Skipped WSL port forward $hostPort/$($rule.Protocol): $errorRecord"
                continue
            }

            Write-Host "Applied WSL port forward $hostPort/$($rule.Protocol) -> $guestPort."
        } catch {
            Write-Warning "Skipped invalid WSL port forward: $_"
        }
    }
} finally {
    if ($endpointHandle -ne [IntPtr]::Zero) {
        [void][LoopVHcn]::HcnCloseEndpoint($endpointHandle)
    }
}
