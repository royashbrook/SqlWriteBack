@{
  RootModule = 'SqlWriteBack.psm1'
  ModuleVersion = '0.1.0'
  GUID = '525072de-75cd-49d2-a16e-1b3a681fbb40'
  Author = 'Roy Ashbrook'
  CompanyName = 'ashbrook.io'
  Copyright = '(c) 2026 royashbrook. MIT License.'
  Description = 'Run configured SQL queries, then run a parameterized command once per returned row, with a json record of each run.'
  PowerShellVersion = '7.4'
  RequiredModules = @(
    @{ ModuleName = 'DataAgent'; RequiredVersion = '0.10.0' }
    @{ ModuleName = 'Add-PrefixForLogging'; RequiredVersion = '1.0.0.3' }
    @{ ModuleName = 'Clear-Files'; RequiredVersion = '1.2.0.0' }
    @{ ModuleName = 'SqlServer'; RequiredVersion = '22.4.5.1' }
  )
  FunctionsToExport = @('Invoke-SqlWriteBack', 'New-SqlWriteBackConfig')
  AliasesToExport = @()
  CmdletsToExport = @()
  VariablesToExport = @()
  FileList = @('SqlWriteBack.psd1', 'SqlWriteBack.psm1', 'adapters/queries.ps1', 'adapters/save.ps1', 'adapters/write.ps1')
  PrivateData = @{
    PSData = @{
      Tags = @('sql', 'writeback', 'dataagent', 'PSEdition_Core')
      LicenseUri = 'https://github.com/royashbrook/SqlWriteBack/blob/main/LICENSE'
      ProjectUri = 'https://github.com/royashbrook/SqlWriteBack'
    }
  }
}
