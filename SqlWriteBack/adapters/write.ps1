param($Data, [hashtable]$Options)
& (Get-Module SqlWriteBack) { param($p, $o) Write-SqlWriteBackFile $p $o } ([string]$Data) $Options
