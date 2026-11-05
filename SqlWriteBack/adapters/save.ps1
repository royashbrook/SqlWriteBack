param($Data, [hashtable]$Options)
& (Get-Module SqlWriteBack) { param($d, $o) Save-SqlWriteBackRows $d $o } $Data $Options
