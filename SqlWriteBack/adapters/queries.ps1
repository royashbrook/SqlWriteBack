param($Data, [hashtable]$Options)
& (Get-Module SqlWriteBack) { param($o) Get-SqlWriteBackRows $o.Settings } $Options
