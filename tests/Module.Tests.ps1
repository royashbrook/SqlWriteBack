BeforeAll {
  $manifest = "$PSScriptRoot/../SqlWriteBack/SqlWriteBack.psd1"
  Import-Module $manifest -Force

  function New-TestFeed($Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    foreach ($name in 'a.sql', 'b.sql', 'c.sql') { Set-Content -LiteralPath (Join-Path $Root $name) -Value 'select 1' }
    @{
      keepdays    = 10
      file_format = '{0:yyyyMMddHHmmss}.json'
      cs          = @{ main = 'env:SWB_TEST_CS' }
      datasets    = @(
        @{
          name = 'Charges'; csname = 'main'; command = 'exec add_charge @o,@q'
          parameters = @{ '@o' = 'order'; '@q' = 'qty' }
          tables = @(@{ name = 'Charges-A'; sql = 'a.sql' }, @{ name = 'Charges-B'; sql = 'b.sql' })
        }
        @{
          name = 'Pay'; csname = 'main'; command = 'exec add_pay @o'
          parameters = @{ '@o' = 'order' }
          tables = @(@{ name = 'Pay-A'; sql = 'c.sql' })
        }
      )
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Root 'settings.json')
    Join-Path $Root 'settings.json'
  }
}

Describe 'dependency pins' {
  It 'pins every required module to the exact version its tests ran against' {
    $data = Import-PowerShellDataFile $manifest
    foreach ($required in @($data.RequiredModules)) {
      $required | Should -BeOfType [hashtable] -Because 'a bare name loads whatever version is installed'
      $required.RequiredVersion | Should -Not -BeNullOrEmpty -Because "$($required.ModuleName) needs an exact version, not a minimum"
    }
  }
}

Describe 'Invoke-SqlWriteBack' {
  BeforeEach {
    $script:root = Join-Path ([IO.Path]::GetTempPath()) ('swb-' + [guid]::NewGuid())
    $script:settings = New-TestFeed $script:root
    $script:location = Get-Location
    $env:SWB_TEST_CS = 'Server=fixture.invalid;Password=SWB_TEST_ONLY'
    $global:SwbWrites = [Collections.Generic.List[object]]::new()
    Mock Invoke-Sqlcmd -ModuleName SqlWriteBack {
      switch ($InputFile) {
        'a.sql' { [pscustomobject]@{ order = 1; qty = 2.0 }; [pscustomobject]@{ order = 2; qty = 1.0 } }
        'b.sql' { }
        'c.sql' { [pscustomobject]@{ order = 3 } }
      }
    }
    Mock Invoke-SqlWriteBackCommand -ModuleName SqlWriteBack {
      $global:SwbWrites.Add([pscustomobject]@{ set = $Set.name; rows = @($Rows); cs = $ConnectionString })
      foreach ($row in $Rows) {
        $ok = $row.order -ne 3
        $resp = if ($ok) { '1' } else { 'no match in assignment' }
        [pscustomobject]@{ start = Get-Date; finish = Get-Date; row = ($row | ConvertTo-Json); sql = $Set.command; params = '[]'; ok = $ok; resp = $resp }
      }
    }
  }
  AfterEach {
    Set-Location $script:location
    Remove-Item -LiteralPath $script:root -Recurse -Force
    Remove-Item Env:SWB_TEST_CS -ErrorAction SilentlyContinue
    Remove-Variable SwbWrites -Scope Global
  }

  It 'records every dataset and table, empty ones included' {
    Invoke-SqlWriteBack $script:settings 6>$null
    $file = @(Get-ChildItem $script:root -Filter '*.json' | Where-Object Name -ne 'settings.json')
    $file.Count | Should -Be 1
    $record = Get-Content $file[0].FullName -Raw | ConvertFrom-Json
    @($record.PSObject.Properties.Name) | Should -Be @('Charges', 'Pay')
    @($record.Charges.PSObject.Properties.Name) | Should -Be @('Charges-A', 'Charges-B')
    @($record.Charges.'Charges-A').Count | Should -Be 2
    @($record.Charges.'Charges-B').Count | Should -Be 0
    $record.Pay.'Pay-A'[0].order | Should -Be 3
  }

  It 'writes each dataset with its own rows and the resolved connection string' {
    Invoke-SqlWriteBack $script:settings 6>$null
    $global:SwbWrites.Count | Should -Be 2
    $global:SwbWrites[0].set | Should -Be 'Charges'
    @($global:SwbWrites[0].rows.order) | Should -Be @(1, 2)
    $global:SwbWrites[1].set | Should -Be 'Pay'
    $global:SwbWrites[0].cs | Should -BeExactly $env:SWB_TEST_CS
  }

  It 'warns on a rejected row and stays green' {
    $out = Invoke-SqlWriteBack $script:settings 6>&1 | Out-String
    $out | Should -Match '::warning title=Pay write rejected::no match in assignment'
    $out | Should -Not -Match '::warning title=Charges'
  }

  It 'keeps the connection string out of the log' {
    Invoke-SqlWriteBack $script:settings 6>$null
    $log = Get-Content (Join-Path $script:root ('{0:yyyyMMdd}.log' -f (Get-Date))) -Raw
    $log | Should -Match 'Processing Dataset.Table: Charges.Charges-A'
    $log | Should -Not -Match 'SWB_TEST_ONLY|fixture.invalid'
  }

  It 'logs no data, writes nothing and records nothing when every query is empty' {
    Mock Invoke-Sqlcmd -ModuleName SqlWriteBack { }
    Invoke-SqlWriteBack $script:settings 6>$null
    $global:SwbWrites.Count | Should -Be 0
    @(Get-ChildItem $script:root -Filter '*.json' | Where-Object Name -ne 'settings.json').Count | Should -Be 0
    Get-Content (Join-Path $script:root ('{0:yyyyMMdd}.log' -f (Get-Date))) -Raw | Should -Match 'No data available'
  }

  It 'fails red when the connection string variable is missing' {
    Remove-Item Env:SWB_TEST_CS
    { Invoke-SqlWriteBack $script:settings 6>$null } | Should -Throw '*SWB_TEST_CS is not set*'
  }

  It 'does nothing under -WhatIf' {
    Invoke-SqlWriteBack $script:settings -WhatIf 6>$null
    Should -Invoke Invoke-Sqlcmd -ModuleName SqlWriteBack -Times 0 -Exactly
    @(Get-ChildItem $script:root -Filter '*.log').Count | Should -Be 0
  }
}

Describe 'the write command' {
  It 'maps each named parameter to its row column' {
    $set = @{ command = 'exec add_charge @o,@q'; parameters = @{ '@o' = 'order'; '@q' = 'qty' } }
    $row = '{"order":10,"qty":1.5,"other":"x"}' | ConvertFrom-Json
    $cm = & (Get-Module SqlWriteBack) { param($s, $r) New-SqlWriteBackCommand $s $r } $set $row
    $cm.CommandText | Should -BeExactly 'exec add_charge @o,@q'
    $cm.Parameters['@o'].Value | Should -Be 10
    $cm.Parameters['@q'].Value | Should -Be 1.5
    $cm.Parameters.Count | Should -Be 2
  }

  It 'keeps the database message and drops the powershell wrapper on a rejected row' {
    $command = [pscustomobject]@{}
    $command | Add-Member ScriptMethod ExecuteNonQuery { throw [Data.DataException]::new('no match in assignment') }
    $result = & (Get-Module SqlWriteBack) { param($c) Invoke-SqlWriteBackRow $c } $command
    $result.ok | Should -BeFalse
    $result.resp | Should -BeExactly 'no match in assignment'
    ([pscustomobject]$result | Format-List * | Out-String) | Should -Not -Match 'Exception calling|FullyQualifiedErrorId'
  }

  It 'reports an accepted row' {
    $command = [pscustomobject]@{}
    $command | Add-Member ScriptMethod ExecuteNonQuery { 1 }
    $result = & (Get-Module SqlWriteBack) { param($c) Invoke-SqlWriteBackRow $c } $command
    $result.ok | Should -BeTrue
    $result.resp | Should -Be '1'
  }

  It 'stops the run when the connection cannot open' {
    $set = @{ name = 'Charges'; command = 'exec add_charge @o'; parameters = @{ '@o' = 'order' } }
    $rows = @([pscustomobject]@{ order = 1 })
    { & (Get-Module SqlWriteBack) { param($r, $s) Invoke-SqlWriteBackCommand $r $s 'Server=127.0.0.1,1;Connect Timeout=1;User ID=x;Password=y' } $rows $set } |
      Should -Throw
  }
}
