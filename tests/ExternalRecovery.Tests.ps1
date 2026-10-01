BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Bootstrap.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    $module="$PSScriptRoot/../src/Modules/ExternalRecovery.psm1"
    if(Test-Path $module){Import-Module $module -DisableNameChecking}
    function New-ExternalFixture {param([switch]$WithService)
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $ctx;$state.Phase='RecoveryRequired';$state.Target='modern';$state.TransactionId='old-recovery';$state.Sequence=49;Write-SwitchState $ctx $state
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') @{OwnerSid=$ctx.OwnerSid;ProfileRoot=$ctx.ProfileRoot;RegistryRoots=@()}
        Add-JournalEntry $ctx old-recovery Checkpoint bootstrap-backup @{Retained='old-backup'} $null
        $inventory=[pscustomobject]@{ProductVersion='2026.6.974819';CapturedAt='fixture';Directories=(Get-ActiveDirectories $ctx);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@();Processes=@();AllDevices=@()}
        if($WithService){$inventory.Services=@([pscustomobject]@{Name='LGHUBUpdaterService';ImagePath=(Join-Path $ctx.Root 'active/Program/lghub_updater.exe');State='Running';StartMode='Auto';Start=2;Native=[pscustomobject]@{Name='LGHUBUpdaterService';ImagePath=(Join-Path $ctx.Root 'active/Program/lghub_updater.exe');StartType=2;CurrentState=4;ControlsAccepted=1;FailureActions=@()}})}
        $manifest=New-EnvironmentManifest $ctx modern $inventory
        if($WithService){$inventory.Services=@($inventory.Services|ConvertTo-Json -Depth 10|ConvertFrom-Json);$inventory.Services[0].Start=4;$inventory.Services[0].StartMode='Disabled';$inventory.Services[0].State='Stopped';$inventory.Services[0].Native.StartType=4;$inventory.Services[0].Native.CurrentState=1}
        $manifest.Files=@(Get-TreeFiles $manifest.Directories.Program|Where-Object {-not $_.IsDirectory})
        $identities=[ordered]@{};foreach($role in $manifest.Directories.Keys){$identities[$role]=Get-DirectoryIdentity $manifest.Directories[$role]}
        $manifest|Add-Member DirectoryIdentities $identities
        $manifest.UpdatePolicy=@{Verified=$true;ProductVersion=$manifest.ProductVersion;Method='ObservedUI';Evidence=@('current user observation')}
        $backup=New-EnvironmentBackup $ctx $manifest
        $manifest|Add-Member BackupPath $backup.Path
        $manifest|Add-Member Acls $backup.Trees
        $candidate=Join-Path $ctx.Root 'Transactions/current-modern.json';Write-AtomicJson $candidate $manifest
        $previous=Join-Path $ctx.Root 'Manifests/modern.json';Write-AtomicJson $previous @{OwnerSid=$ctx.OwnerSid;Slot='modern';ProductVersion='2025.old';Qualification='Prepared'}
        [pscustomobject]@{Context=$ctx;Inventory=$inventory;State=$state;Candidate=$candidate;Previous=$previous;Manifest=$manifest;Observation=@{ObserverSid=$ctx.OwnerSid;ObservedUtc=[DateTime]::UtcNow.ToString('o');ProductVersion=$manifest.ProductVersion;ConfigurationRestored=$true;AutomaticUpdatesDisabled=$true;Statement='User recovered game profiles and DPI after external reinstall.';BackupPath=$backup.Path}}
    }
}
Describe 'External modern recovery evidence' {
    BeforeEach {
        $script:fx=New-ExternalFixture
        if(Get-Module ExternalRecovery){
            Mock Get-GHUBInventory -ModuleName ExternalRecovery {$script:fx.Inventory}
            Mock Get-BootId -ModuleName ExternalRecovery {'boot-current'}
        }
    }
    It 'preserves the actual old artifacts and registers only the fully bound modern candidate' {
        $old=[IO.File]::ReadAllText($fx.Previous)
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $fx.Manifest|Add-Member ExternalRecoveryEvidence $evidence
        Register-Environment $fx.Context $fx.Manifest
        (Read-AtomicJson $fx.Previous).Qualification | Should -Be Prepared
        $report=Read-AtomicJson $evidence.Path
        $report.InstallationObserved | Should -BeFalse
        [IO.File]::ReadAllText($report.Artifacts.PreviousManifest.Path) | Should -Be $old
        (Read-SwitchState $fx.Context).TransactionId | Should -Be old-recovery
        $fx.Manifest.PSObject.Properties.Name | Should -Not -Contain InstallerEvidence
    }
    It 'rejects legacy even when external evidence claims it passed' {
        $fx.Manifest.Slot='legacy';$fx.Manifest|Add-Member ExternalRecoveryEvidence @{Passed=$true}
        {Register-Environment $fx.Context $fx.Manifest} | Should -Throw '*ExternalRecovery*'
        Test-Path (Join-Path $fx.Context.Root 'Manifests/legacy.json') | Should -BeFalse
    }
    It 'rejects missing current-version observations before preserving evidence' {
        $fx.Observation.AutomaticUpdatesDisabled=$false
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*Observation*'
        @(Get-ChildItem (Join-Path $fx.Context.Root 'Transactions') -Filter '*external-recovery-evidence.json').Count | Should -Be 0
    }
    It 'rejects a stale full state before any registration mutation' {
        $changed=Read-SwitchState $fx.Context;$changed.Sequence++;Write-SwitchState $fx.Context $changed
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*ExternalChange*'
        (Read-AtomicJson $fx.Previous).ProductVersion | Should -Be '2025.old'
    }
    It 'rechecks candidate identity instead of trusting a Passed flag' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $fx.Manifest|Add-Member ExternalRecoveryEvidence $evidence
        $fx.Manifest.Services=@(@{Name='unexpected';ImagePath='outside'})
        {Register-Environment $fx.Context $fx.Manifest} | Should -Throw '*ExternalRecovery*'
        (Read-AtomicJson $fx.Previous).ProductVersion | Should -Be '2025.old'
    }
    It 'rejects replacing the bound backup with a different complete backup' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $other=New-EnvironmentBackup $fx.Context $fx.Manifest
        $fx.Manifest.BackupPath=$other.Path;$fx.Manifest|Add-Member ExternalRecoveryEvidence $evidence
        {Register-Environment $fx.Context $fx.Manifest} | Should -Throw '*ExternalRecovery*'
    }
    It 'rejects current configuration drift and keeps the user changes untouched' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        [IO.File]::WriteAllText((Join-Path $fx.Context.Root 'active/LocalData/slot.txt'),'new DPI')
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*ExternalChange*'
        Get-Content (Join-Path $fx.Context.Root 'active/LocalData/slot.txt') | Should -Be 'new DPI'
        (Read-SwitchState $fx.Context).TransactionId | Should -Be old-recovery
    }
    It 'rejects a changed old manifest and a changed evidence artifact' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        Write-AtomicJson $fx.Previous @{Changed='outside'}
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*ExternalChange*'
        [IO.File]::AppendAllText($evidence.Path,'tamper')
        {Test-ExternalRecoveryEvidence $fx.Context $evidence $fx.Manifest} | Should -Throw '*ExternalRecovery*'
    }
    It 'accepts unchanged installation and configuration despite system driver topology drift in installation mode' {
        $registration=Read-AtomicJson (Join-Path $fx.Context.Root 'registration.json')
        $registration|Add-Member ValidationMode InstallationAndConfiguration
        Write-AtomicJson (Join-Path $fx.Context.Root 'registration.json') $registration
        $fx.Inventory.Devices=@(@{InstanceId='different-system-driver';InfPath='different.inf'})
        Mock Test-GHUBDeviceBinding -ModuleName ExternalRecovery {throw 'Unexpected runtime binding check'}
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $fx.Manifest|Add-Member ExternalRecoveryEvidence $evidence
        Register-Environment $fx.Context $fx.Manifest
        (Read-AtomicJson $fx.Previous).ProductVersion|Should -Be '2026.6.974819'
    }
    It 'rechecks driver topology before starting an adoption transaction' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $fx.Inventory.Devices=@(@{InstanceId='drift';ParentId='different';ProblemCode=0})
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*ExternalChange*'
        (Read-SwitchState $fx.Context).TransactionId | Should -Be old-recovery
    }
    It 'rejects a candidate whose saved ACLs do not belong to its backup' {
        $fx.Manifest.Acls=@();Write-AtomicJson $fx.Candidate $fx.Manifest
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*ExternalRecovery*'
    }
    It 'rejects a candidate that does not describe the current device set' {
        $fx.Inventory.Devices=@(@{InstanceId='unexpected';ProblemCode=0})
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*ExternalChange*'
    }
    It 'requires stopped writers and disabled application services before confirming the baseline' {
        $script:fx=New-ExternalFixture -WithService
        $fx.Inventory.Services[0].Start=2;$fx.Inventory.Services[0].State='Running';$fx.Inventory.Services[0].Native.StartType=2
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*Busy*'
        $fx.Inventory.Services[0].Start=4;$fx.Inventory.Services[0].State='Stopped';$fx.Inventory.Services[0].Native.StartType=4
        $fx.Inventory.Processes=@(@{Name='lghub_agent.exe';OwnerSid=$fx.Context.OwnerSid})
        {Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation} | Should -Throw '*Busy*'
    }
}
Describe 'External adoption transaction recovery' {
    BeforeEach {
        $script:fx=New-ExternalFixture
        if(Get-Module ExternalRecovery){
            Mock Get-GHUBInventory -ModuleName ExternalRecovery {$script:fx.Inventory}
            Mock Get-BootId -ModuleName ExternalRecovery {'boot-current'}
            Mock Get-GHUBHealth -ModuleName ExternalRecovery {@{TechnicalPassed=$true;Checks=@();FunctionalStatus='Unverified'}}
            Mock Start-GHUBUserSession -ModuleName ExternalRecovery {New-OperationResult}
            Mock Start-ScheduledTask -ModuleName ExternalRecovery {throw 'Monitor remains disabled during adoption.'}
        }
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Invoke-GHUBRollback -ModuleName Coordinator {throw 'UNSAFE old rollback'}
    }
    It 'defers launch in a new transaction then commits healthy modern without old rollback' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        (Adopt-ExternalModernEnvironment $fx.Context $evidence -VerifyOnly).Status | Should -Be Ok
        (Read-SwitchState $fx.Context).Sequence | Should -Be 49
        (Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch).Status | Should -Be Prepared
        $prepared=Read-SwitchState $fx.Context
        $prepared.Phase | Should -Be Maintenance
        $prepared.TransactionId | Should -Not -Be old-recovery
        (Read-AtomicJson $fx.Previous).Qualification | Should -Be Prepared
        (Complete-ExternalModernRecovery $fx.Context).Status | Should -Be Ok
        $done=Read-SwitchState $fx.Context
        $done.Phase | Should -Be Idle
        $done.Active | Should -Be modern
        $done.Health | Should -Be TechnicalPassed
        $done.TransactionId | Should -BeNullOrEmpty
        @(Read-ValidJournal $fx.Context old-recovery).Count | Should -Be 1
    }
    It 'routes coordinator recovery to adoption and retains profiles after launch interruption' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $null=Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch
        Mock Start-GHUBUserSession -ModuleName ExternalRecovery {param($Context) [IO.File]::WriteAllText((Join-Path $Context.Root 'active/LocalData/slot.txt'),'user DPI after launch');throw 'launch interruption'}
        (Complete-ExternalModernRecovery $fx.Context).Status | Should -Be RecoveryRequired
        $failed=Read-SwitchState $fx.Context
        $failed.TransactionId | Should -Not -Be old-recovery
        Mock Start-GHUBUserSession -ModuleName ExternalRecovery {New-OperationResult}
        (Resume-GHUBTransaction $fx.Context).Status | Should -Be Ok
        Get-Content (Join-Path $fx.Context.Root 'active/LocalData/slot.txt') | Should -Be 'user DPI after launch'
    }
    It 'retains adoption on failed health and does not falsely commit Idle' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $null=Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch
        Mock Get-GHUBHealth -ModuleName ExternalRecovery {@{TechnicalPassed=$false;Checks=@('bad driver')}}
        (Complete-ExternalModernRecovery $fx.Context).Status | Should -Be RecoveryRequired
        (Read-SwitchState $fx.Context).Phase | Should -Be RecoveryRequired
        (Read-AtomicJson $fx.Previous).Qualification | Should -Be Prepared
    }
    It 'retains a prepared adoption while waiting for the owner login' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $null=Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch
        Mock Start-GHUBUserSession -ModuleName ExternalRecovery {New-OperationResult AwaitingLogon AwaitingLogon 'waiting'}
        (Complete-ExternalModernRecovery $fx.Context).Status | Should -Be AwaitingLogon
        (Read-SwitchState $fx.Context).Health | Should -Be Unverified
        (Read-AtomicJson (Join-Path $fx.Context.Root 'Status/launch.json')).Enabled | Should -BeFalse
    }
    It 'recovers a journal-to-state interruption without entering the old bootstrap restoration' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        Mock Write-SwitchState -ModuleName ExternalRecovery {param($Context,$State) if($State.TransactionId -ne 'old-recovery'){throw 'state write interrupted'};Core\Write-SwitchState $Context $State}
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*state write interrupted*'
        (Read-SwitchState $fx.Context).TransactionId | Should -Be old-recovery
        (Get-ExternalRecoveryCheckpoint $fx.Context).After.AdoptionId | Should -Be $evidence.AdoptionId
        Mock Write-SwitchState -ModuleName ExternalRecovery {param($Context,$State) Core\Write-SwitchState $Context $State}
        (Resume-GHUBTransaction $fx.Context).Status | Should -Be Ok
        (Read-SwitchState $fx.Context).Phase | Should -Be Idle
    }
    It 'retries after prepared manifest persistence was interrupted' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        Mock Write-AtomicJson -ModuleName Bootstrap {param($Path,$Value) Core\Write-AtomicJson $Path $Value;throw 'manifest write interrupted'}
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*manifest write interrupted*'
        Mock Write-AtomicJson -ModuleName Bootstrap {param($Path,$Value) Core\Write-AtomicJson $Path $Value}
        (Resume-GHUBTransaction $fx.Context).Status | Should -Be Ok
        Get-Content (Join-Path $fx.Context.Root 'active/LocalData/slot.txt') | Should -Be modern
    }
    It 'accepts only the checkpointed disabled-to-manual service transition after an interrupted launch' {
        $script:fx=New-ExternalFixture -WithService
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        $null=Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch
        Mock Set-Service -ModuleName ExternalRecovery {param($Name,$StartupType) if($Name -ne 'LGHUBUpdaterService' -or $StartupType -ne 'Manual'){throw 'unexpected service mutation'};$script:fx.Inventory.Services[0].Start=3;$script:fx.Inventory.Services[0].Native.StartType=3;$script:fx.Inventory.Services[0].StartMode='Manual'}
        Mock Start-Service -ModuleName ExternalRecovery {$script:fx.Inventory.Services[0].State='Running';$script:fx.Inventory.Services[0].Native.CurrentState=4}
        Mock Start-GHUBUserSession -ModuleName ExternalRecovery {throw 'interrupted after services started'}
        (Complete-ExternalModernRecovery $fx.Context).Status | Should -Be RecoveryRequired
        $fx.Inventory.Services[0].Start | Should -Be 3
        Mock Start-GHUBUserSession -ModuleName ExternalRecovery {New-OperationResult}
        (Resume-GHUBTransaction $fx.Context).Status | Should -Be Ok
        $fx.Inventory.Services[0].State | Should -Be Running
    }
    It 'blocks direct backup restoration after the adoption marker but before the new state is saved' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        Mock Write-SwitchState -ModuleName ExternalRecovery {throw 'state write interrupted'}
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*state write interrupted*'
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Read-EnvironmentManifest -ModuleName Bootstrap {$script:fx.Manifest}
        [IO.File]::WriteAllText((Join-Path $fx.Context.Root 'active/LocalData/slot.txt'),'newest DPI')
        (Restore-ModernBackup $fx.Context).Code | Should -Be ExternalRecoveryRequired
        (Read-SwitchState $fx.Context).Sequence | Should -Be 49
        Get-Content (Join-Path $fx.Context.Root 'active/LocalData/slot.txt') | Should -Be 'newest DPI'
    }
    It 'requires dedicated resume when completion is called before the adoption state was saved' {
        $evidence=Confirm-ExternalModernRecovery $fx.Context $fx.Candidate $fx.State $fx.Previous $fx.Observation
        Mock Write-SwitchState -ModuleName ExternalRecovery {throw 'state write interrupted'}
        {Adopt-ExternalModernEnvironment $fx.Context $evidence -DeferLaunch} | Should -Throw '*state write interrupted*'
        {Complete-ExternalModernRecovery $fx.Context} | Should -Throw '*dedicated resume*'
        (Read-SwitchState $fx.Context).Sequence | Should -Be 49
        (Read-AtomicJson $fx.Previous).ProductVersion | Should -Be '2025.old'
        @(Read-ValidJournal $fx.Context old-recovery).Count | Should -Be 1
    }
}
