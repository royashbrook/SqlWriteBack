function Invoke-SqlWriteBack {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $file = Get-Item -LiteralPath $Settings
  if (-not $PSCmdlet.ShouldProcess($file.DirectoryName, 'Invoke-SqlWriteBack')) { return }
  $config = New-SqlWriteBackConfig $file.FullName
  $config.directory = $file.DirectoryName
  Invoke-DataAgent $config
}

function New-SqlWriteBackConfig {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)]$Settings)
  if ($Settings -is [string]) { $Settings = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable }
  $config = @{
    src = @{ adapter = "$PSScriptRoot/adapters/queries.ps1"; args = @{ Settings = $Settings } }
    fmt = @{ adapter = "$PSScriptRoot/adapters/save.ps1"; args = @{ Settings = $Settings } }
    dst = @{ adapter = "$PSScriptRoot/adapters/write.ps1"; args = @{ Settings = $Settings } }
  }
  foreach ($key in 'keepdays', 'purgefiles', 'file_format', 'filename_date_format', 'filename_date_pattern') {
    if ($Settings.ContainsKey($key)) { $config[$key] = $Settings[$key] }
  }
  $config
}

# every query of every dataset, each row tagged with where it came from
function Get-SqlWriteBackRows($Settings) {
  $timeout = if ($Settings.query_timeout) { $Settings.query_timeout } else { 1800 }
  foreach ($set in $Settings.datasets) {
    foreach ($table in $set.tables) {
      l "Processing Dataset.Table: $($set.name).$($table.name)" | Write-Host
      $rows = @(Invoke-Sqlcmd -QueryTimeout $timeout -ConnectionString $Settings.cs[$set.csname] -InputFile $table.sql |
        Select-Object * -ExcludeProperty ItemArray, Table, RowError, RowState, HasErrors)
      if (-not $rows.Count) { l "$($set.name).$($table.name) is empty." | Write-Host }
      foreach ($row in $rows) { [pscustomobject]@{ dataset = $set.name; table = $table.name; row = $row } }
    }
  }
}

# the run's record: every configured dataset and table, empty ones included
function Save-SqlWriteBackRows($Data, $Options) {
  $record = [ordered]@{}
  foreach ($set in $Options.Settings.datasets) {
    $record[$set.name] = [ordered]@{}
    foreach ($table in $set.tables) {
      $record[$set.name][$table.name] = @(foreach ($item in $Data) { if ($item.dataset -eq $set.name -and $item.table -eq $table.name) { $item.row } })
    }
  }
  $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Options.Path
}

function Write-SqlWriteBackFile($Path, $Options) {
  $Settings = $Options.Settings
  $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  foreach ($set in $Settings.datasets) {
    $rows = @(foreach ($table in $set.tables) { $data.($set.name).($table.name) })
    l $set.name | Write-Host
    if (-not $rows.Count) { l 'No Data Skip' | Write-Host; continue }
    $rows | Format-Table -AutoSize * | Out-String -Width 4096 | Write-Host
    $results = @(Invoke-SqlWriteBackCommand $rows $set $Settings.cs[$set.csname])
    $results | Format-List * | Out-String -Width 4096 | Write-Host
    foreach ($result in $results.Where({ -not $_.ok })) {
      Write-Host "::warning title=$($set.name) write rejected::$($result.resp)"
    }
  }
}

# each named parameter takes the row column the settings map it to. a null column is sql NULL,
# a column the row does not have is a settings mistake and stops the run
function New-SqlWriteBackCommand($Set, $Row) {
  $cm = [System.Data.SqlClient.SqlCommand]::new($Set.command)
  foreach ($name in $Set.parameters.Keys) {
    $column = $Set.parameters[$name]
    $property = $Row.PSObject.Properties[$column]
    if (-not $property) { throw "$($Set.name): parameter $name maps to column '$column', which the row does not have" }
    $value = if ($null -eq $property.Value) { [DBNull]::Value } else { $property.Value }
    $cm.Parameters.AddWithValue($name, $value) > $null
  }
  $cm
}

# a rejected row keeps the database's own message, not the powershell wrapper around it
function Invoke-SqlWriteBackRow($Command) {
  try { @{ ok = $true; resp = $Command.ExecuteNonQuery() | ConvertTo-Json } }
  catch { @{ ok = $false; resp = $_.Exception.GetBaseException().Message } }
}

# one connection per dataset: failing to open it stops the run, a rejected row is a result
function Invoke-SqlWriteBackCommand($Rows, $Set, $ConnectionString) {
  $cn = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
  try {
    $cn.Open()
    foreach ($row in $Rows) {
      $start = Get-Date
      $cm = New-SqlWriteBackCommand $Set $row
      $cm.Connection = $cn
      $params = $cm.Parameters | Select-Object ParameterName, Value | ConvertTo-Json
      try { $result = Invoke-SqlWriteBackRow $cm }
      finally { $cm.Dispose() }
      [pscustomobject]@{
        start  = $start
        finish = Get-Date
        row    = $row | ConvertTo-Json
        sql    = $Set.command
        params = $params
        ok     = $result.ok
        resp   = $result.resp
      }
    }
  } finally { $cn.Dispose() }
}

Export-ModuleMember -Function Invoke-SqlWriteBack, New-SqlWriteBackConfig
