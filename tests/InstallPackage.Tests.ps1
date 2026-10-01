BeforeAll {
    $installerSource=Join-Path $PSScriptRoot '../src/Install-GHUBSwitcher.ps1'
    foreach($name in @('Core','Storage','Release')){Import-Module (Join-Path $PSScriptRoot "../src/Modules/$name.psm1") -Force -DisableNameChecking}
}
Describe 'First installation from a shared package' {
    BeforeEach {
        $fixture=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $package=Join-Path $fixture '解压 包'
        $profile=Join-Path $fixture 'recipient'
        [IO.Directory]::CreateDirectory((Join-Path $package 'Installers'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $package 'Modules'))|Out-Null
        [IO.Directory]::CreateDirectory($profile)|Out-Null
        $savedProgramData=$env:ProgramData
        $env:ProgramData=Join-Path $fixture 'ProgramData'
        [IO.Directory]::CreateDirectory($env:ProgramData)|Out-Null
        $managedRoot=Join-Path $package 'Data'
        $script=Join-Path $package 'Install-GHUBSwitcher.ps1'
        # Keep the real installer body and real modules; bind its import boundary
        # to the source module instances so Pester can isolate Windows privileges.
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../src/PackagePreflight.ps1') -Destination (Join-Path $package 'PackagePreflight.ps1')
        $checkerHash=(Get-FileHash -LiteralPath (Join-Path $package 'PackagePreflight.ps1')).Hash
        $body=[regex]::Replace([IO.File]::ReadAllText($installerSource),'(?m)^foreach\(\$name in .*Import-Module[^\r\n]*','').Replace('__GHUB_PACKAGE_CHECK_SHA256__',$checkerHash)
        [IO.File]::WriteAllText($script,$body,[Text.UTF8Encoding]::new($true))
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../src/Modules') -File){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package ('Modules/'+$file.Name))}
        foreach($name in @('Start-GHUBSwitcher.ps1','Invoke-GHUBWorker.ps1','Start-GHUBUserSession.ps1')){
            [IO.File]::WriteAllText((Join-Path $package $name),[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('../src/'+$name))).Replace('__GHUB_PACKAGE_CHECK_SHA256__',$checkerHash),[Text.UTF8Encoding]::new($true))
        }
        [IO.Directory]::CreateDirectory((Join-Path $package 'Native'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $package 'Native/GHubSwitcher.Native.dll'),'native DLL fixture')
        $legacy=Join-Path $package 'Installers/lghub_installer_2021.3.exe'
        [IO.File]::WriteAllText($legacy,'recipient legacy installer')
        [IO.File]::WriteAllText((Join-Path $package 'GHUBSwitcher.exe'),'launcher fixture')
        $entries=@(Get-ChildItem -LiteralPath $package -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($package.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
        @{SchemaVersion=1;Files=$entries}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        $owner='S-1-5-21-100-200-300-400'
        Mock Assert-Administrator {}
        Mock Get-ItemProperty { [pscustomobject]@{ProfileImagePath=$profile} } -ParameterFilter { $LiteralPath -like 'HKLM:*ProfileList*' }
        Mock Set-Acl {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Logitech Inc, O=Logitech Inc'}} }
        Mock Get-AuthenticodeSignature -ModuleName Release { [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Logitech Inc, O=Logitech Inc'}} }
        Mock Get-Item -ModuleName Release { [pscustomobject]@{FullName=$LiteralPath;VersionInfo=[pscustomobject]@{FileVersion='2021.3.5164'}} } -ParameterFilter { $LiteralPath -like '*lghub_installer_2021.3.exe' }
    }
    AfterEach { $env:ProgramData=$savedProgramData }
    It 'installs the included legacy installer without any Downloads folder' {
        & $script -OwnerSid $owner
        (Read-AtomicJson (Join-Path $managedRoot 'registration.json')).OwnerSid | Should -BeExactly 'S-1-5-21-100-200-300-400'
        (Read-AtomicJson (Join-Path $managedRoot 'registration.json')).ProfileRoot | Should -BeExactly $profile
        [IO.File]::ReadAllText((Join-Path $managedRoot 'Installers/lghub_installer_2021.3.exe'))|Should -BeExactly 'recipient legacy installer'
        Test-Path -LiteralPath (Join-Path $managedRoot 'App/Installers')|Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:ProgramData 'GHUBSwitcher')|Should -BeFalse
        (Read-AtomicJson (Join-Path $managedRoot 'registration.json')).Portable | Should -BeTrue
        (Read-AtomicJson (Join-Path $managedRoot 'registration.json')).Root | Should -BeExactly $managedRoot
    }
    It 'does not create a broken installation when the bundled installer is absent' {
        Remove-Item -LiteralPath $legacy
        $entries=@(Get-ChildItem -LiteralPath $package -Recurse -File|Where-Object Name -NE 'release-manifest.json'|ForEach-Object {@{Path=$_.FullName.Substring($package.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
        @{SchemaVersion=1;Files=$entries}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        {& $script -OwnerSid $owner}|Should -Throw '*required*'
        Test-Path -LiteralPath $managedRoot | Should -BeFalse
    }
    It 'keeps an existing installation and configuration intact' {
        [IO.Directory]::CreateDirectory($managedRoot)|Out-Null
        [IO.File]::WriteAllText((Join-Path $managedRoot 'keep.txt'),'latest recipient configuration')
        {& $script -OwnerSid $owner}|Should -Throw '*AlreadyInstalled*'
        [IO.File]::ReadAllText((Join-Path $managedRoot 'keep.txt'))|Should -BeExactly 'latest recipient configuration'
    }
    It 'removes only its incomplete staging directory if copying fails, allowing retry' {
        Mock Copy-Item {throw 'fixture disk failure'} -ParameterFilter {$Destination -like '*GHUBSwitcher.Install-*'}
        {& $script -OwnerSid $owner}|Should -Throw '*disk failure*'
        Test-Path -LiteralPath $managedRoot | Should -BeFalse
        @(Get-ChildItem -LiteralPath $package -Directory -Filter 'GHUBSwitcher.Install-*').Count|Should -Be 0
    }
    It 'rejects an untrusted installer without creating the installation directory' {
        Mock Get-AuthenticodeSignature -ModuleName Release { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
        {& $script -OwnerSid $owner}|Should -Throw '*Invalid legacy installer*'
        Test-Path -LiteralPath $managedRoot | Should -BeFalse
    }
    It 'rejects a package missing the executable even if its manifest entry is removed' {
        Remove-Item -LiteralPath (Join-Path $package 'GHUBSwitcher.exe')
        $record=Get-Content -Raw -LiteralPath (Join-Path $package 'release-manifest.json')|ConvertFrom-Json
        $record.Files=@($record.Files|Where-Object Path -NE 'GHUBSwitcher.exe')
        $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        {& $script -OwnerSid $owner}|Should -Throw '*required*'
        Test-Path -LiteralPath $managedRoot|Should -BeFalse
    }
    It 'rejects replacing the source installer during its signature check' {
        Mock Get-AuthenticodeSignature -ModuleName Release {
            [IO.File]::WriteAllText($LiteralPath,'unsigned replacement')
            [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Logitech Inc, O=Logitech Inc'}}
        } -ParameterFilter {$LiteralPath -eq $legacy}
        {& $script -OwnerSid $owner}|Should -Throw
        Test-Path -LiteralPath $managedRoot|Should -BeFalse
    }
    It 'uses a valid Entra account with a registered profile' {
        & $script -OwnerSid 'S-1-12-1-100-200-300-400'
        (Read-AtomicJson (Join-Path $managedRoot 'registration.json')).OwnerSid|Should -BeExactly 'S-1-12-1-100-200-300-400'
    }
    It 'rejects a modified module before its top-level code can execute' {
        $marker=Join-Path $fixture 'module-executed.txt'
        $module=Join-Path $package 'Modules/Core.psm1'
        [IO.File]::AppendAllText($module,("`n[IO.File]::WriteAllText('"+$marker.Replace("'","''")+"','executed')`n"))
        [IO.File]::WriteAllText($script,[IO.File]::ReadAllText($installerSource).Replace('__GHUB_PACKAGE_CHECK_SHA256__',$checkerHash),[Text.UTF8Encoding]::new($true))
        $record=Get-Content -Raw -LiteralPath (Join-Path $package 'release-manifest.json')|ConvertFrom-Json
        ($record.Files|Where-Object Path -EQ 'Install-GHUBSwitcher.ps1').Sha256=(Get-FileHash -LiteralPath $script).Hash.ToLowerInvariant()
        $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        $process=Start-Process -FilePath "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -OwnerSid '+$owner) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt') -Wait -PassThru
        $process.ExitCode|Should -Be 1
        Get-Content -Raw -LiteralPath (Join-Path $fixture 'stderr.txt')|Should -Match 'Release file hash mismatch'
        Test-Path -LiteralPath $marker|Should -BeFalse
    }
    It 'rejects a modified module at the menu entry before execution with manifest present=<Present>' -TestCases @(@{Present=$true},@{Present=$false}) {
        param($Present)
        $marker=Join-Path $fixture 'menu-module-executed.txt'
        [IO.File]::AppendAllText((Join-Path $package 'Modules/Core.psm1'),("`n[IO.File]::WriteAllText('"+$marker.Replace("'","''")+"','executed')`n"))
        $entry=Join-Path $package 'Start-GHUBSwitcher.ps1'
        if(-not $Present){Remove-Item -LiteralPath (Join-Path $package 'release-manifest.json')}
        $process=Start-Process -FilePath "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ReadOnly') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt') -Wait -PassThru
        $process.ExitCode|Should -Be 1
        $message=Get-Content -Raw -LiteralPath (Join-Path $fixture 'stderr.txt')
        if($Present){$message|Should -Match 'Release file hash mismatch'}else{$message|Should -Match 'release-manifest'}
        Test-Path -LiteralPath $marker|Should -BeFalse
    }
    It 'starts through the executable when the inherited path contains an incompatible utility module' {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../build/GHUBSwitcher.exe') -Destination (Join-Path $package 'GHUBSwitcher.exe') -Force
        $record=Get-Content -Raw -LiteralPath (Join-Path $package 'release-manifest.json')|ConvertFrom-Json
        ($record.Files|Where-Object Path -EQ 'GHUBSwitcher.exe').Sha256=(Get-FileHash -LiteralPath (Join-Path $package 'GHUBSwitcher.exe')).Hash.ToLowerInvariant()
        $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
        $savedModulePath=$env:PSModulePath
        $shadow=Join-Path $fixture 'other-PowerShell/Modules/Microsoft.PowerShell.Utility'
        [IO.Directory]::CreateDirectory($shadow)|Out-Null
        [IO.File]::WriteAllText((Join-Path $shadow 'Microsoft.PowerShell.Utility.psm1'),'function Get-FileHash {throw "incompatible inherited utility"}; Export-ModuleMember -Function Get-FileHash')
        [IO.File]::WriteAllText((Join-Path $shadow 'Microsoft.PowerShell.Utility.psd1'),'@{ModuleVersion="9.0";RootModule="Microsoft.PowerShell.Utility.psm1";FunctionsToExport=@("Get-FileHash");CmdletsToExport=@()}')
        try{
            $env:PSModulePath=(Split-Path $shadow -Parent)+';'+$savedModulePath
            $process=Start-Process -FilePath (Join-Path $package 'GHUBSwitcher.exe') -ArgumentList '--read-only' -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt') -Wait -PassThru
        }finally{$env:PSModulePath=$savedModulePath}
        $process.ExitCode|Should -Be 0
        Get-Content -Raw -LiteralPath (Join-Path $fixture 'stdout.txt')|Should -Match '尚未安装'
    }
}
