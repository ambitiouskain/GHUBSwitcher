BeforeAll {
    $repository = Split-Path $PSScriptRoot -Parent
    $engine = (Get-Process -Id $PID).Path
}

Describe 'Development test runner exit status' {
    It 'fails when the test report cannot be written even though the tests passed' {
        $fixture = Join-Path $TestDrive 'report-failure'
        foreach ($dir in @('build/test-results.xml','tests','tools')) {
            [IO.Directory]::CreateDirectory((Join-Path $fixture $dir)) | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $repository 'build/Test.ps1') -Destination (Join-Path $fixture 'build/Test.ps1')
        Copy-Item -LiteralPath (Join-Path $repository 'tools/Pester') -Destination (Join-Path $fixture 'tools/Pester') -Recurse
        [IO.File]::WriteAllText((Join-Path $fixture 'tests/Fixture.Tests.ps1'), "Describe 'Fixture' { It 'passes' { 1 | Should -Be 1 } }")
        $log = Join-Path $fixture 'runner.log'
        & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'build/Test.ps1') *> $log
        $runnerExit = $LASTEXITCODE
        $runnerLog = [IO.File]::ReadAllText($log)
        $runnerLog | Should -Match 'Tests Passed: 1, Failed: 0'
        $runnerExit | Should -Not -Be 0
    }
}
