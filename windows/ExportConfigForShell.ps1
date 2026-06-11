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

# Emit every key of each config table as W_<Section>_<Key>=value.
$sections = "NetworkConfig", "VMCreateConfig", "CloudInitConfig"
foreach ($section in $sections) {
    $table = Get-Variable -Name $section -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $table) { continue }
    foreach ($entry in $table.GetEnumerator()) {
        "W_{0}_{1}={2}" -f $section, $entry.Key, (ConvertTo-ShellSingleQuoted $entry.Value)
    }
}
