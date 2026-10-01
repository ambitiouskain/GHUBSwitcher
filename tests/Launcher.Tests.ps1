BeforeAll {
    & (Join-Path $PSScriptRoot '../build/Build-Launcher.ps1')
    $launcher=Join-Path $PSScriptRoot '../build/GHUBSwitcher.exe'
}
Describe 'Relocatable executable entry point' {
    BeforeEach {
        $folder=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+' 软件 文件夹')
        [IO.Directory]::CreateDirectory($folder)|Out-Null
        Copy-Item -LiteralPath $launcher -Destination (Join-Path $folder 'GHUBSwitcher.exe')
        $exe=Join-Path $folder 'GHUBSwitcher.exe'
    }
    It 'runs the script beside the executable and forwards read-only mode and exit status' {
        $fixture='param([switch]$ReadOnly); @{ReadOnly=$ReadOnly.IsPresent;Directory=(Get-Location).Path}|ConvertTo-Json|Set-Content -LiteralPath "launch-result.json" -Encoding UTF8; exit 7'
        [IO.File]::WriteAllText((Join-Path $folder 'Start-GHUBSwitcher.ps1'),$fixture,[Text.UTF8Encoding]::new($true))
        $null=& $exe --read-only
        $LASTEXITCODE | Should -Be 7
        $result=Get-Content -Raw -LiteralPath (Join-Path $folder 'launch-result.json')|ConvertFrom-Json
        $result.ReadOnly | Should -BeTrue
        $result.Directory | Should -BeExactly $folder
    }
    It 'opens the ordinary menu without turning on read-only mode' {
        $fixture='param([switch]$ReadOnly); $ReadOnly.IsPresent|Set-Content -LiteralPath "read-only.txt"; exit 0'
        [IO.File]::WriteAllText((Join-Path $folder 'Start-GHUBSwitcher.ps1'),$fixture,[Text.UTF8Encoding]::new($true))
        $null=& $exe
        $LASTEXITCODE | Should -Be 0
        Get-Content -LiteralPath (Join-Path $folder 'read-only.txt')|Should -BeExactly 'False'
    }
}
