# SqlWriteBack

For a job that reads rows from SQL and writes each one back through a stored procedure. Each dataset names its queries and the command it runs once per returned row, with every command parameter mapped to a row column. The module has no queries, procedures, connection strings or retained state of its own.

## Usage

```powershell
Import-Module SqlWriteBack -RequiredVersion 0.1.0
Invoke-SqlWriteBack "$PSScriptRoot/settings.json"
```

The module pins DataAgent 0.10.0, Add-PrefixForLogging 1.0.0.3, Clear-Files 1.2.0.0 and SqlServer 22.4.5.1. Install packages separately from the job. The runner writes `yyyyMMdd.log` in the settings folder.

```json
{
  "keepdays": 10,
  "purgefiles": "*.log,[0-9]*.json",
  "file_format": "{0:yyyyMMddHHmmss}.json",
  "filename_date_format": "yyyyMMdd",
  "cs": { "main": "env:CONNECTION_STRING" },
  "datasets": [
    {
      "name": "Charges",
      "csname": "main",
      "command": "exec add_charge @order, @qty",
      "parameters": { "@order": "order_id", "@qty": "qty" },
      "tables": [ { "name": "Charges-Daily", "sql": "charges-daily.sql" } ]
    }
  ]
}
```

`env:NAME` references are resolved by DataAgent when the run starts, and a missing one fails the run. `query_timeout` defaults to 1800 seconds.

## A run

Every query of every dataset runs first. When none returns a row, the log says `No data available` and nothing is written. Otherwise `file_format` names a json record of every dataset and table, empty ones included, and then each dataset's rows are written in order on one connection.

A connection that cannot open stops the run. A row the command rejects becomes a result with the exception, a `::warning` annotation on a GitHub Actions run, and the job goes on. Nothing marks a row as done, so a query that still selects a rejected row selects it again on the next run. Write the query to exclude what the command already added.

`-WhatIf` on the entrypoint runs no query, cleanup or write. Tests stub the SQL read and the per-row command, so they need no database.
