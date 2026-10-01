BeforeAll {
    foreach($name in @('Core','Inventory','Storage')) {Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    $path="$PSScriptRoot/../src/Modules/Bootstrap.psm1"
    if(Test-Path $path){Import-Module $path -Force -DisableNameChecking}
}
Describe 'Preparation guards' {
    It 'does not begin maintenance from legacy or while a switch is pending' {
        { Assert-ModernMaintenance @{Phase='Idle';Active='legacy'} } | Should -Throw '*Busy*'
        { Assert-ModernMaintenance @{Phase='PendingReboot';Active='modern'} } | Should -Throw '*Busy*'
    }
    It 'does not allow an installer before a verified modern backup' {
        { Assert-LegacyPreparation $false $true '2021.3.5164' } | Should -Throw '*BackupInvalid*'
    }
    It 'rejects a renamed installer from a different release' {
        { Assert-LegacyPreparation $true $true '2026.6.974819' } | Should -Throw '*InstallerVersionMismatch*'
    }
    It 'rejects an invalid installer signature' {
        { Assert-LegacyPreparation $true $false '2021.3.5164' } | Should -Throw '*InvalidSignature*'
    }
}
Describe 'First backup serialization' {
    BeforeEach {
        $initialContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Get-Item -ModuleName Bootstrap {@{FullName='fixture.exe';VersionInfo=@{FileVersion='2021.3.5164'}}}
        Mock Get-AuthenticodeSignature -ModuleName Bootstrap {@{Status='Valid';SignerCertificate=@{Subject='O=Logitech Inc'}}}
        Mock Capture-CurrentEnvironment -ModuleName Bootstrap {throw 'Capture must not start.'}
    }
    It 'refuses to capture or stop G HUB while another operation holds the lease' {
        $lease=Enter-SwitchLock $initialContext
        try{
            {Initialize-GHUBSwitcher $initialContext 'fixture.exe' -AutomaticUpdatesObservedOff}|Should -Throw '*Busy*'
            Should -Invoke Capture-CurrentEnvironment -ModuleName Bootstrap -Times 0 -Exactly
        }finally{$lease.Dispose()}
    }
    It 'rejects another portable instance before capturing any configuration' {
        Mock Assert-PortableInstance -ModuleName Bootstrap {Throw-SwitchError OtherInstance 'Another folder manages G HUB.'}
        {Initialize-GHUBSwitcher $initialContext 'fixture.exe' -AutomaticUpdatesObservedOff}|Should -Throw '*OtherInstance*'
        Should -Invoke Capture-CurrentEnvironment -ModuleName Bootstrap -Times 0 -Exactly
        $lease=Enter-SwitchLock $initialContext;$lease.Dispose()
    }
}
Describe 'Independent backup restoration' {
    It 'restores a verified backup while preserving the displaced environment' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $manifest=@{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $backup=New-EnvironmentBackup $ctx $manifest
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/slot.txt'),'installer-changed')
        (Restore-BackupDirectories $ctx $backup fixture).Status | Should -Be Ok
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be modern
        @(Get-ChildItem (Join-Path $ctx.Root 'Rescue') -Recurse -Filter slot.txt | Where-Object { (Get-Content $_.FullName) -eq 'installer-changed' }).Count | Should -Be 1
        (Restore-BackupDirectories $ctx $backup fixture).Status | Should -Be Ok
    }
    It 'cannot restore a damaged backup over working files' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        [IO.File]::WriteAllText((Join-Path $backup.Path 'Program/slot.txt'),'bad')
        { Restore-BackupDirectories $ctx $backup fixture } | Should -Throw '*BackupInvalid*'
        Get-Content (Join-Path $ctx.Root 'active/Program/slot.txt') | Should -Be modern
    }
}
Describe 'Legacy data isolation and slot repair' {
    It 'parks retained modern databases before an installer can see data roots' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Initialize-LegacyDataRoots $ctx fixture
        foreach($role in @('LocalData','RoamingData','MachineData')) {
            @(Get-ChildItem -LiteralPath (Join-Path $ctx.Root "active/$role")).Count | Should -Be 0
            Get-Content (Join-Path $ctx.Root "Rescue/fixture/pre-legacy/$role/slot.txt") | Should -Be modern
        }
        Initialize-LegacyDataRoots $ctx fixture
        Get-Content (Join-Path $ctx.Root 'active/Program/slot.txt') | Should -Be modern
    }
    It 'restores modern after an exchange and keeps the next full exchange usable' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $null=Restore-BackupDirectories $ctx $backup fixture
        foreach($role in @('Program','LocalData','RoamingData','MachineData')) {
            Test-Path (Join-Path $ctx.Root "Environments/modern/$role") | Should -BeFalse
            Get-Content (Join-Path $ctx.Root "Environments/legacy/$role/slot.txt") | Should -Be legacy
        }
        $state=Read-SwitchState $ctx; $state.TransactionId='next'; Write-SwitchState $ctx $state
        (Invoke-DirectoryExchange $ctx modern legacy).Status | Should -Be Ok
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be legacy
    }
    It 'reconciles copies parked during interrupted first preparation without losing them' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $park=Join-Path $ctx.Root 'Environments/modern/Program'
        [IO.Directory]::CreateDirectory((Split-Path $park -Parent))|Out-Null
        Copy-Item -LiteralPath (Join-Path $backup.Path 'Program') -Destination $park -Recurse
        $null=Restore-BackupDirectories $ctx $backup fixture
        Test-Path $park | Should -BeFalse
        Get-Content (Join-Path $ctx.Root 'Rescue/fixture/parked-modern/Program/slot.txt') | Should -Be modern
        (Restore-BackupDirectories $ctx $backup fixture).Status | Should -Be Ok
    }
}
Describe 'Installer change classification gate' {
    It 'retains a report and blocks unrelated registry or shared component changes' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $source=@{Services=@();KernelServices=@();Devices=@();RegistryValues=@();ProductVersion='modern'}
        $target=@{Services=@();KernelServices=@();Devices=@();RegistryValues=@();ProductVersion='2021.3'}
        $before=@{Items=@();Errors=@();Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}
        foreach($kind in @('Registry','Service','SharedFile','ClassFilter')) {
            $after=@{Items=@(@{Kind=$kind;Key='unrelated';Hash='changed';Path='C:\Shared\outside.dll'});Errors=@();Coverage=$before.Coverage}
            { Confirm-InstallerChanges $ctx $before $after $source $target fixture } | Should -Throw '*UnclassifiedInstallerChange*'
            (Read-AtomicJson (Join-Path $ctx.Root 'Transactions/fixture-installer-report.json')).Passed | Should -BeFalse
        }
    }
    It 'allows changes confined to the recorded G HUB registry and application services' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $source=@{Services=@();KernelServices=@();Devices=@();RegistryValues=@();ProductVersion='modern'}
        $target=@{Services=@(@{Name='LGHUBUpdaterService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe"'});KernelServices=@();Devices=@();RegistryValues=@();ProductVersion='2021.3'}
        $before=@{Items=@();Errors=@();Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}
        $after=@{Items=@(@{Kind='Registry';Key='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB|version';Hash='new';Path='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB'},@{Kind='Service';Key='LGHUBUpdaterService';Hash='new';Path='"C:\Program Files\LGHUB\lghub_updater.exe"'});Errors=@();Coverage=$before.Coverage}
        (Confirm-InstallerChanges $ctx $before $after $source $target fixture).Passed | Should -BeTrue
    }
    It 'does not register on incomplete baseline evidence' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $snapshot=@{Items=@();Errors=@('Access denied');Coverage=@('Registry')}
        { Confirm-InstallerChanges $ctx $snapshot $snapshot @{} @{ProductVersion='2021.3'} fixture } | Should -Throw '*UnclassifiedInstallerChange*'
    }
}
Describe 'Registration requires classified installer evidence' {
    It 'rejects a legacy capture even with a valid backup when installer review is missing' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $manifest=[pscustomobject]@{OwnerSid=$ctx.OwnerSid;Slot='legacy';ProductVersion='2021.3';DriverPackages=@();BackupPath=$backup.Path;Qualification='Unverified';UpdatePolicy=@{Verified=$true;ProductVersion='2021.3';Method='ObservedUI';Evidence=@('observed')}}
        { Register-Environment $ctx $manifest } | Should -Throw '*UnclassifiedInstallerChange*'
        Test-Path (Join-Path $ctx.Root 'Manifests/legacy.json') | Should -BeFalse
    }
}
Describe 'Interrupted preparation preservation' {
    It 'continues isolation after a rename completes before its completion record' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:injected=$false
        Mock Move-ManagedDirectory -ModuleName Bootstrap {
            param($From,$To)
            [IO.Directory]::Move($From,$To)
            if(-not $script:injected){$script:injected=$true;throw 'simulated power loss'}
        }
        { Initialize-LegacyDataRoots $ctx fixture } | Should -Throw '*simulated power loss*'
        Initialize-LegacyDataRoots $ctx fixture
        foreach($role in @('LocalData','RoamingData','MachineData')){
            @(Get-ChildItem (Join-Path $ctx.Root "active/$role")).Count | Should -Be 0
            Get-Content (Join-Path $ctx.Root "Rescue/fixture/pre-legacy/$role/slot.txt") | Should -Be modern
        }
    }
    It 'continues slot reconciliation after a parked copy has already been archived' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $script:injected=$false
        Mock Move-ManagedDirectory -ModuleName Bootstrap {
            param($From,$To)
            [IO.Directory]::Move($From,$To)
            if(-not $script:injected){$script:injected=$true;throw 'simulated power loss'}
        }
        { Restore-BackupDirectories $ctx $backup fixture } | Should -Throw '*simulated power loss*'
        (Restore-BackupDirectories $ctx $backup fixture).Status | Should -Be Ok
        Get-Content (Join-Path $ctx.Root 'Environments/legacy/Program/slot.txt') | Should -Be legacy
        Test-Path (Join-Path $ctx.Root 'Environments/modern/Program') | Should -BeFalse
    }
}
Describe 'Scoped product registry capture' {
    BeforeEach {
        InModuleScope Inventory {
            $script:registryCaptureContext=@{Root='C:\fixture';OwnerSid='S-1-5-21-1-2-3-1001'}
            $script:registryCaptureKeys=@{}
            $script:registryCaptureChildren=@{}
            function script:New-CaptureFixtureKey {param([string]$Path,[hashtable]$Values)
                $key=[pscustomobject]@{Name=$Path.Replace('Registry::','');Values=$Values;Disposed=$false}
                $key|Add-Member ScriptMethod GetValueNames { @($this.Values.Keys) }
                $key|Add-Member ScriptMethod GetValueKind {param($Name) [Microsoft.Win32.RegistryValueKind]::String}
                $key|Add-Member ScriptMethod GetValue {param($Name,$Default,$Options) $this.Values[$Name]}
                $key|Add-Member ScriptMethod Dispose { $this.Disposed=$true }
                $key
            }
            Mock Test-Path {param([string[]]$LiteralPath) $script:registryCaptureKeys.ContainsKey($LiteralPath[0]) -or $script:registryCaptureChildren.ContainsKey($LiteralPath[0])}
            Mock Get-Item {param([string[]]$LiteralPath) $script:registryCaptureKeys[$LiteralPath[0]]}
            Mock Get-ChildItem {param([string[]]$LiteralPath) @($script:registryCaptureChildren[$LiteralPath[0]]) | Where-Object { $null -ne $_ }}

        }
    }
    It 'captures product values from <Root>' -TestCases @(
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\LGHUB'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Logitech\GHUB'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Logitech\LGHUB'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Logitech\GHUB'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Logitech\LGHUB'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\WOW6432Node\Logitech\GHUB'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\WOW6432Node\Logitech\LGHUB'}
    ) {
        param($Root)
        InModuleScope Inventory -Parameters @{Root=$Root} {
            param($Root)
            $script:registryCaptureKeys[$Root]=New-CaptureFixtureKey $Root @{setting='original'}
            $result=Get-GHUBRegistryValues $script:registryCaptureContext
            $result.Roots | Should -Contain $Root
            $values=@($result.Values | Where-Object Path -EQ $Root)
            $values.Count | Should -Be 1
            $values[0].Name | Should -Be setting
            $values[0].Kind | Should -Be String
            $values[0].Value | Should -Be original
        }
    }
    It 'captures only the matching G HUB uninstall record under <Parent>' -TestCases @(
        @{Parent='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'},
        @{Parent='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'},
        @{Parent='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'},
        @{Parent='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'}
    ) {
        param($Parent)
        InModuleScope Inventory -Parameters @{Parent=$Parent} {
            param($Parent)
            $owned=$Parent+'\{GHUB}';$other=$Parent+'\{OTHER}'
            $ownedKey=New-CaptureFixtureKey $owned @{DisplayName='Logitech G HUB';DisplayVersion='2021.3'}
            $otherKey=New-CaptureFixtureKey $other @{DisplayName='Other Application';DisplayVersion='1.0'}
            $script:registryCaptureChildren[$Parent]=@($ownedKey,$otherKey)
            $script:registryCaptureKeys[$owned]=$ownedKey;$script:registryCaptureKeys[$other]=$otherKey
            $result=Get-GHUBRegistryValues $script:registryCaptureContext
            $result.Roots | Should -Contain $owned
            $result.Roots | Should -Not -Contain $other
            @($result.Values | Where-Object Path -EQ $owned).Count | Should -Be 2
            @($result.Values | Where-Object Path -EQ $other).Count | Should -Be 0
        }
    }
}
Describe 'Quiesced registry capture and maintenance recovery' {
    BeforeEach {
        $script:quiescedContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:quiescedValue='before-stop';$script:capturedBackup=$null
        $script:quiescedManifest=[pscustomobject]@{Slot='modern';OwnerSid=$quiescedContext.OwnerSid;ProductVersion='modern';Directories=(Get-ActiveDirectories $quiescedContext);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@();Files=@();DriverPackages=@();RegistryValues=@(@{Path=('Registry::HKEY_USERS\'+$quiescedContext.OwnerSid+'\SOFTWARE\Logitech\LGHUB');Name='Data';Exists=$true;Kind='String';Value='before-stop'});BackupPath='C:\fixture\original';Acls=@();UpdatePolicy=@{}}
        Write-AtomicJson (Join-Path $quiescedContext.Root 'registration.json') ([pscustomobject]@{RegistryRoots=@()})
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Get-GHUBInventory -ModuleName Bootstrap { [pscustomobject]@{ProductVersion='modern';Directories=$script:quiescedManifest.Directories;Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@();CapturedAt='fixture'} }
        Mock New-EnvironmentManifest -ModuleName Bootstrap { $copy=$script:quiescedManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $copy.Directories=$script:quiescedManifest.Directories; $copy }
        Mock Read-EnvironmentManifest -ModuleName Bootstrap { $script:quiescedManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
        Mock Get-OwnedRegistryValues -ModuleName Bootstrap { [pscustomobject]@{Roots=@();Values=@(@{Path=('Registry::HKEY_USERS\'+$script:quiescedContext.OwnerSid+'\SOFTWARE\Logitech\LGHUB');Name='Data';Exists=$true;Kind='String';Value=$script:quiescedValue})} }
        Mock Stop-GHUBEnvironment -ModuleName Bootstrap { $script:quiescedValue='after-stop' }
        Mock Update-EnvironmentRuntimeRegistry -ModuleName Bootstrap {
            param($Context,$Manifest)
            if($script:quiescedValue -ne 'after-stop'){throw 'Refresh happened before stop.'}
            $copy=$Manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $copy.RegistryValues[0].Value='after-stop';$copy
        }
        Mock New-EnvironmentBackup -ModuleName Bootstrap {
            param($Context,$Manifest)
            $script:capturedBackup=[pscustomobject]@{Path=(Join-Path $Context.Root 'Backups/refreshed');Slot=$Manifest.Slot;OwnerSid=$Context.OwnerSid;Trees=@();Manifest=($Manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json)}
            $script:capturedBackup
        }
        Mock Export-ManagedDrivers -ModuleName Bootstrap { @() }
        Mock Get-TreeFiles -ModuleName Bootstrap { @() }
        Mock Get-DirectoryIdentity -ModuleName Bootstrap { @{VolumeSerial=1;FileId=1} }
        Mock Test-EnvironmentBackup -ModuleName Bootstrap { $true }
        Mock Get-AuthenticodeSignature -ModuleName Bootstrap { @{Status='Valid';SignerCertificate=@{Subject='O=Logitech Inc'}} }
        Mock Get-Item -ModuleName Bootstrap { @{VersionInfo=@{FileVersion='2021.3.5164'}} } -ParameterFilter { $LiteralPath -eq 'C:\fixture\legacy.exe' }
        Mock Get-InstallerSnapshot -ModuleName Bootstrap { throw 'Fixture stops before official installer or update UI.' }
    }
    It 'captures final registry values after stopping while retaining original service settings' {
        $quiescedManifest.Services=@(@{Name='LGHUBUpdaterService';Native=@{StartType=2}})
        $result=Capture-CurrentEnvironment $quiescedContext modern -AutomaticUpdatesObservedOff -DeferRegistration
        $result.RegistryValues[0].Value | Should -Be 'after-stop'
        $result.Services[0].Native.StartType | Should -Be 2
        $capturedBackup.Manifest.RegistryValues[0].Value | Should -Be 'after-stop'
        (Read-AtomicJson (Join-Path $quiescedContext.Root 'State/pre-capture-modern.json')).RegistryValues[0].Value | Should -Be 'after-stop'
    }
    It 'keeps the stopped registry checkpoint and file backup consistent for <Operation>' -TestCases @(@{Operation='PrepareLegacy'},@{Operation='MaintainModern'}) {
        param($Operation)
        if($Operation -eq 'PrepareLegacy'){$null=Capture-LegacyEnvironment $quiescedContext 'C:\fixture\legacy.exe'}else{$null=Maintain-ModernEnvironment $quiescedContext}
        $state=Read-SwitchState $quiescedContext
        $journal=@(Read-ValidJournal $quiescedContext $state.TransactionId)
        @($journal | Where-Object StepId -EQ 'source-quiesced').Count | Should -Be 1
        $source=Get-SourceCheckpoint $quiescedContext $state.TransactionId
        $source.RegistryValues[0].Value | Should -Be 'after-stop'
        $capturedBackup.Manifest.RegistryValues[0].Value | Should -Be 'after-stop'
        $source.BackupPath | Should -Be $capturedBackup.Path
    }
    It 'retains the stopped checkpoint when the new file backup fails' {
        Mock New-EnvironmentBackup -ModuleName Bootstrap { throw 'Fixture backup failure.' }
        $null=Capture-LegacyEnvironment $quiescedContext 'C:\fixture\legacy.exe'
        $state=Read-SwitchState $quiescedContext
        (Get-SourceCheckpoint $quiescedContext $state.TransactionId).RegistryValues[0].Value | Should -Be 'after-stop'
    }
    It 'reaches <Launcher> confirmation when its launcher exits but G HUB descendants keep running' -TestCases @(
        @{Launcher='Uninstall';Confirmation='UNINSTALLED';Cancellation='UserCancelled.*Uninstall not confirmed'},
        @{Launcher='Install';Confirmation='AUTO-OFF';Cancellation='UpdatePolicyUnverified.*Legacy update policy was not confirmed'}
    ) {
        param($Launcher,$Confirmation,$Cancellation)
        $script:launcherKind=$Launcher;$script:launcherConfirmation=$Confirmation
        $script:confirmationReached=$false;$script:confirmationAfterExit=$false;$script:confirmationWithLiveDescendant=$false
        $script:launcherProcess=[pscustomobject]@{Exited=$false;Disposed=$false;DescendantRunning=$true}
        $launcherProcess | Add-Member ScriptMethod WaitForExit { $this.Exited=$true }
        $launcherProcess | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        Mock Get-InstallerSnapshot -ModuleName Bootstrap { @{Errors=@()} }
        Mock Test-Path -ModuleName Bootstrap { $script:launcherKind -eq 'Uninstall' } -ParameterFilter { $LiteralPath -like '*lghub_software_manager.exe' }
        Mock Test-Path -ModuleName Bootstrap { $false } -ParameterFilter { $LiteralPath -like '*lghub_agent.exe' }
        Mock Initialize-LegacyDataRoots -ModuleName Bootstrap {}
        Mock Capture-CurrentEnvironment -ModuleName Bootstrap { throw 'Capture must wait for explicit confirmation.' }
        Mock Start-Process -ModuleName Bootstrap {
            param($FilePath,[switch]$Wait,[switch]$PassThru)
            if($Wait){throw 'Waited for live G HUB descendants.'}
            if($PassThru){$script:launcherProcess}
        }
        Mock Read-Host -ModuleName Bootstrap {
            param($Prompt)
            if($Prompt -like "*$script:launcherConfirmation*"){
                $script:confirmationReached=$true
                $script:confirmationAfterExit=$script:launcherProcess.Exited
                $script:confirmationWithLiveDescendant=$script:launcherProcess.DescendantRunning
                return 'CANCEL'
            }
            if($Prompt -like '*UNINSTALLED*'){return 'UNINSTALLED'}
            if($Prompt -like '*INSTALL*'){return 'INSTALL'}
            throw "Unexpected confirmation: $Prompt"
        }

        $result=Capture-LegacyEnvironment $quiescedContext 'C:\fixture\legacy.exe'

        $result.Code | Should -Be RecoveryRequired
        $result.Message | Should -Match $Cancellation
        $confirmationReached | Should -BeTrue
        $confirmationAfterExit | Should -BeTrue
        $confirmationWithLiveDescendant | Should -BeTrue
        $launcherProcess.Disposed | Should -BeTrue
        Should -Invoke Start-Process -ModuleName Bootstrap -Times 1 -Exactly
        Should -Invoke Capture-CurrentEnvironment -ModuleName Bootstrap -Times 0 -Exactly
        if($Launcher -eq 'Uninstall'){Should -Invoke Initialize-LegacyDataRoots -ModuleName Bootstrap -Times 0 -Exactly}
    }
    It 'restores the quiesced source checkpoint instead of stale registered settings' {
        $source=$quiescedManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $source.RegistryValues[0].Value='after-stop'
        $script:recoveryBackup=[pscustomobject]@{Slot='modern';OwnerSid=$quiescedContext.OwnerSid;Path=(Join-Path $quiescedContext.Root 'Backups/refreshed');Trees=@();Manifest=$source}
        Add-JournalEntry $quiescedContext fixture Checkpoint source $quiescedManifest $null
        Add-JournalEntry $quiescedContext fixture Checkpoint source-quiesced $source $null
        Add-JournalEntry $quiescedContext fixture Checkpoint bootstrap-backup $recoveryBackup $null
        Mock Read-AtomicJson -ModuleName Bootstrap { $script:recoveryBackup } -ParameterFilter {$Path -like '*backup.json'}
        Mock Restore-BackupDirectories -ModuleName Bootstrap {}
        Mock Apply-EnvironmentServices -ModuleName Bootstrap {}
        $script:restoredRegistry=$null
        Mock Apply-EnvironmentRegistry -ModuleName Bootstrap {param($Context,$Source,$Target) $script:restoredRegistry=$Target.RegistryValues; throw 'Fixture stops before launching restored G HUB.'}
        $null=Restore-ModernBackup $quiescedContext
        $restoredRegistry[0].Value | Should -Be 'after-stop'
    }
    It 'preserves current files when preparation stopped before creating a fresh backup' {
        Mock New-EnvironmentBackup -ModuleName Bootstrap { throw 'Fixture backup failure.' }
        $null=Capture-LegacyEnvironment $quiescedContext 'C:\fixture\legacy.exe'
        Mock Restore-GHUBEnvironment -ModuleName Bootstrap { New-OperationResult Blocked WrongLockPath }
        Mock Invoke-GHUBRollback -ModuleName Bootstrap {
            param($Context,$Cause)
            {Enter-SwitchLock $Context} | Should -Throw '*Busy*'
            $source=Get-SourceCheckpoint $Context (Read-SwitchState $Context).TransactionId
            New-OperationResult Ok CurrentFilesPreserved '' $source.RegistryValues
        }
        $result=Restore-ModernBackup $quiescedContext
        $result.Code | Should -Be CurrentFilesPreserved
        $result.Evidence[0].Value | Should -Be 'after-stop'
        Get-Content -LiteralPath (Join-Path $quiescedContext.Root 'active/LocalData/slot.txt') | Should -Be modern
    }
    It 'refuses to combine a refreshed registry with an old backup after a mutation intent' {
        Mock New-EnvironmentBackup -ModuleName Bootstrap { throw 'Fixture backup failure.' }
        $null=Capture-LegacyEnvironment $quiescedContext 'C:\fixture\legacy.exe'
        $state=Read-SwitchState $quiescedContext
        Add-JournalEntry $quiescedContext $state.TransactionId Intent directory-1 @{} $null
        $result=Restore-ModernBackup $quiescedContext
        $result.Code | Should -Be RecoveryRequired
        $result.Message | Should -Match 'No fresh source backup'
    }
    It 'uses the preinstall audit copy while retaining the recovery source unchanged' {
        $script:auditedSource=$null
        Mock Get-InstallerAuditSource -ModuleName Bootstrap {
            param($Source,$CurrentTasks)
            $copy=$Source | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $copy | Add-Member -NotePropertyName AuditOnly -NotePropertyValue 'controlled-tasks'
            $copy
        }
        Mock Get-InstallerSnapshot -ModuleName Bootstrap { @{Errors=@()} }
        Mock Apply-EnvironmentServices -ModuleName Bootstrap {}
        Mock Start-GHUBUserSession -ModuleName Bootstrap { New-OperationResult }
        Mock Read-Host -ModuleName Bootstrap { 'UPDATED-AUTO-OFF' }
        Mock Capture-CurrentEnvironment -ModuleName Bootstrap { $script:quiescedManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
        Mock Confirm-InstallerChanges -ModuleName Bootstrap {param($Context,$Before,$After,$Source,$Target,$TransactionId) $script:auditedSource=$Source; @{Passed=$true} }
        Mock Register-Environment -ModuleName Bootstrap {}
        Mock Install-StartupControl -ModuleName Bootstrap {}
        Mock Get-BootId -ModuleName Bootstrap { 'fixture-boot' }
        (Maintain-ModernEnvironment $quiescedContext).Status | Should -Be PendingReboot
        (Get-ObjectValue $auditedSource AuditOnly '') | Should -Be 'controlled-tasks'
        $recovery=Get-SourceCheckpoint $quiescedContext (Read-SwitchState $quiescedContext).TransactionId
        (Get-ObjectValue $recovery AuditOnly '') | Should -Be ''
        $recovery.RegistryValues[0].Value | Should -Be 'after-stop'
    }
}
