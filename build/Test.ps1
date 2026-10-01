param([string]$Filter='*')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/Pester/5.7.1/Pester.psd1') -Force
$config=New-PesterConfiguration
$config.Run.Path=@(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter "$Filter.Tests.ps1" | ForEach-Object FullName)
$config.Run.PassThru=$true
$config.Output.Verbosity='Detailed'
$config.TestResult.Enabled=$true
$config.TestResult.OutputPath=Join-Path $PSScriptRoot 'test-results.xml'
$result=Invoke-Pester -Configuration $config
if ($null -eq $result -or $result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0 -or $result.PassedCount -eq 0) { exit 1 }
