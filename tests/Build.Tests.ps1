BeforeAll {
    $buildSource = Join-Path $PSScriptRoot '../build/Build.ps1'
}
Describe 'Development release packaging' {
BeforeEach {
    $fixture = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
    $repo = Join-Path $fixture 'repo'
    $evidence = Join-Path $fixture 'evidence'
    $output = Join-Path $fixture 'release'
    foreach ($dir in @('build','src/Native','tests/nested','docs/nested','tools/Pester/5.7.1')) {
        [IO.Directory]::CreateDirectory((Join-Path $repo $dir)) | Out-Null
    }
    [IO.Directory]::CreateDirectory($evidence) | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'build/Build.ps1'), [IO.File]::ReadAllText($buildSource), [Text.UTF8Encoding]::new($true))
    # Compilation is an external boundary; these tests exercise packaging only.
    [IO.File]::WriteAllText((Join-Path $repo 'build/Build-Native.ps1'), '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''GHubSwitcher.Native.dll''),''fixture DLL''); $global:LASTEXITCODE=0')
    [IO.File]::WriteAllText((Join-Path $repo 'build/Build-Launcher.ps1'), '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''GHUBSwitcher.exe''),''fixture launcher''); $global:LASTEXITCODE=0')
    [IO.Directory]::CreateDirectory((Join-Path $repo 'src/Modules')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'src/Modules/Release.psm1'), 'function Get-VerifiedLegacyInstaller { param([string]$Path) if(-not [IO.File]::Exists($Path)){throw ''Missing legacy installer''}; Get-Item -LiteralPath $Path }')
    [IO.File]::WriteAllText((Join-Path $repo 'docs/分发使用说明.md'), 'shareable instructions')
    foreach ($file in @('src/Start-GHUBSwitcher.ps1','src/Native/DeviceApi.cs','tests/nested/Fixture.Tests.ps1','docs/nested/detail.md','docs/操作说明.md','docs/acceptance.md','.gitignore','tools/Pester/5.7.1/LICENSE.txt')) {
        [IO.File]::WriteAllText((Join-Path $repo $file), 'fixture')
    }
    [IO.File]::WriteAllText((Join-Path $evidence 'test-results.xml'), '<test-results failures="0" />')
    $build = Join-Path $repo 'build/Build.ps1'
}
AfterEach {
    # A fixture verifier must not remain loaded beside the real Release module.
    Get-Module Release | Where-Object {$_.ModuleBase.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)} | Remove-Module -Force
}
    It 'refuses the source root itself without adding release files' {
        { & $build -OutputDirectory $repo } | Should -Throw '*separate*'
        Test-Path -LiteralPath (Join-Path $repo 'release-manifest.json') | Should -BeFalse
    }
    It 'refuses a source descendant before compiling or copying' {
        { & $build -OutputDirectory (Join-Path $repo 'nested') } | Should -Throw '*separate*'
        Test-Path -LiteralPath (Join-Path $repo 'build/GHubSwitcher.Native.dll') | Should -BeFalse
    }
    It 'refuses to mix an existing directory with a new release' {
        [IO.Directory]::CreateDirectory($output) | Out-Null
        [IO.File]::WriteAllText((Join-Path $output 'keep.txt'), 'previous release')
        { & $build -OutputDirectory $output } | Should -Throw '*empty*'
        [IO.File]::ReadAllText((Join-Path $output 'keep.txt')) | Should -Be 'previous release'
        @(Get-ChildItem -LiteralPath $output -Recurse -File).Count | Should -Be 1
    }
    It 'includes evidence and complete nested source with portable hash paths' {
        $null = & $build -OutputDirectory $output -VerificationDirectory $evidence
        foreach ($path in @('source/tests/nested/Fixture.Tests.ps1','source/docs/nested/detail.md','source/.gitignore','source/tools/Pester/5.7.1/LICENSE.txt','verification/test-results.xml','Native/GHubSwitcher.Native.dll','source/build/GHubSwitcher.Native.dll')) {
            Test-Path -LiteralPath (Join-Path $output $path) | Should -BeTrue
        }
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $output 'release-manifest.json') | ConvertFrom-Json
        $manifest.LiveValidated | Should -BeFalse
        @($manifest.Files | Where-Object { $_.Path -like 'source/*' }).Count | Should -BeGreaterThan 0
        foreach ($file in $manifest.Files) {
            $file.Path | Should -Not -Match '\\'
            (Get-FileHash -LiteralPath (Join-Path $output $file.Path)).Hash.ToLowerInvariant() | Should -BeExactly $file.Sha256
        }
        $bytes = [IO.File]::ReadAllBytes((Join-Path $output 'source/tests/nested/Fixture.Tests.ps1'))
        [BitConverter]::ToString($bytes,0,3) | Should -Be 'EF-BB-BF'
    }
    It 'builds a complete recipient package without development records or local user data' {
        $legacy=Join-Path $fixture 'legacy.exe'
        [IO.File]::WriteAllText($legacy,'official installer fixture')
        [IO.File]::WriteAllText((Join-Path $evidence 'personal-registration.json'),'private identity')
        $null=& $build -OutputDirectory $output -Distribution -LegacyInstallerPath $legacy
        [IO.File]::ReadAllText((Join-Path $output 'Installers/lghub_installer_2021.3.exe')) | Should -BeExactly 'official installer fixture'
        Test-Path -LiteralPath (Join-Path $output 'GHUBSwitcher.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $output 'source') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $output 'verification') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $output '使用说明.md')) | Should -BeExactly 'shareable instructions'
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $output 'release-manifest.json')|ConvertFrom-Json
        $manifest.Distribution | Should -BeTrue
        foreach($file in $manifest.Files){
            $file.Path | Should -Not -Match '(^|/)(registration.json|settings.db|test-results.xml)$'
            (Get-FileHash -LiteralPath (Join-Path $output $file.Path)).Hash.ToLowerInvariant() | Should -BeExactly $file.Sha256
        }
    }
    It 'rejects a recipient package without its installer before creating output' {
        { & $build -OutputDirectory $output -Distribution } | Should -Throw '*legacy installer*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
