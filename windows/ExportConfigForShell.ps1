param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
. $ConfigPath

function ConvertTo-ShellSingleQuoted {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    return "'" + $text.Replace("'", "'\''") + "'"
}

$values = [ordered]@{
    CONFIG_INTERNAL_SWITCH_NAME = $NetworkConfig.InternalSwitchName
    CONFIG_VM_GATEWAY = $NetworkConfig.VmGateway
    CONFIG_PREFIX_LENGTH = $NetworkConfig.PrefixLength
    CONFIG_WSL_ADDRESS = $NetworkConfig.WslAddress
}

foreach ($entry in $values.GetEnumerator()) {
    "{0}={1}" -f $entry.Key, (ConvertTo-ShellSingleQuoted $entry.Value)
}
