BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Storage.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Release.psm1" -Force -DisableNameChecking
}
Describe 'Recipient package preflight' {
    BeforeEach {
        $package=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+' 解压目录')
        [IO.Directory]::CreateDirectory((Join-Path $package 'Installers'))|Out-Null
        foreach($name in @('GHUBSwitcher.exe','Start-GHUBSwitcher.ps1','Install-GHUBSwitcher.ps1','Invoke-GHUBWorker.ps1','Start-GHUBUserSession.ps1','PackagePreflight.ps1','Native/GHubSwitcher.Native.dll','Modules/Core.psm1','Modules/Inventory.psm1','Modules/Storage.psm1','Modules/Drivers.psm1','Modules/Lifecycle.psm1','Modules/Coordinator.psm1','Modules/Bootstrap.psm1','Modules/InstallerAudit.psm1','Modules/ExternalRecovery.psm1','Modules/Release.psm1')){
            $path=Join-Path $package $name
            [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
            [IO.File]::WriteAllText($path,'runtime fixture')
        }
        [IO.File]::WriteAllText((Join-Path $package 'Installers/lghub_installer_2021.3.exe'),'legacy fixture')
        $files=Get-ChildItem -LiteralPath $package -Recurse -File|ForEach-Object {
            @{Path=$_.FullName.Substring($package.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
        }
        @{SchemaVersion=1;Files=@($files)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
    }
    It 'verifies the same complete package after moving it to a new path' {
        $relocated=Join-Path $TestDrive '别人电脑的 文件夹'
        Move-Item -LiteralPath $package -Destination $relocated
        (Get-VerifiedRelease $relocated).Files.Count | Should -Be 18
    }
    It 'rejects a changed bundled installer before installation' {
        [IO.File]::AppendAllText((Join-Path $package 'Installers/lghub_installer_2021.3.exe'),'changed')
        {Get-VerifiedRelease $package}|Should -Throw '*hash mismatch*'
    }
    It 'rejects missing runtime files' {
        Remove-Item -LiteralPath (Join-Path $package 'Start-GHUBSwitcher.ps1')
        {Get-VerifiedRelease $package}|Should -Throw
    }
    It 'rejects paths escaping the package' {
        @{SchemaVersion=1;Files=@(@{Path='../outside.exe';Sha256=('a'*64)})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        {Get-VerifiedRelease $package}|Should -Throw '*Invalid release*'
    }
    It 'rejects an empty manifest rather than accepting an incomplete package' {
        @{SchemaVersion=1;Files=@()}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        {Get-VerifiedRelease $package}|Should -Throw '*Invalid release*'
    }
    It 'reads a UTF-8 manifest without BOM containing a Chinese file name' {
        $name='使用说明.md'
        [IO.File]::WriteAllText((Join-Path $package $name),'instructions')
        $record=Get-Content -Raw -LiteralPath (Join-Path $package 'release-manifest.json')|ConvertFrom-Json
        $record.Files+=@{Path=$name;Sha256=(Get-FileHash -LiteralPath (Join-Path $package $name)).Hash.ToLowerInvariant()}
        [IO.File]::WriteAllText((Join-Path $package 'release-manifest.json'),($record|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        (Get-VerifiedRelease $package).Files.Count|Should -Be 19
    }
}
