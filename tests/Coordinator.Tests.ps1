BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    $path="$PSScriptRoot/../src/Modules/Coordinator.psm1"
    if (Test-Path $path) { Import-Module $path -Force -DisableNameChecking }
}
Describe 'Full coordinator on isolated real directories' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
        Import-Module "$PSScriptRoot/../src/Modules/Storage.psm1" -Force -DisableNameChecking
        Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    }
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $ctx; $state.TransactionId=$null; Write-SwitchState $ctx $state
        foreach($slot in @('modern','legacy')) {
            $inventory=[pscustomobject]@{ProductVersion=$slot;CapturedAt='fixture';Directories=(Get-ActiveDirectories $ctx);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@()}
            $manifest=New-EnvironmentManifest $ctx $slot $inventory
            $manifest.Qualification='Prepared'
            $manifest.UpdatePolicy=[pscustomobject]@{Verified=$true;ProductVersion=$slot;Method='ObservedUI';Evidence=@('fixture')}
            Write-AtomicJson (Join-Path $ctx.Root "Manifests/$slot.json") $manifest
        }
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Get-BootId -ModuleName Coordinator {'boot-a'}
        Mock Get-GHUBInventory -ModuleName Coordinator { [pscustomobject]@{ProductVersion='modern';Processes=@();Devices=@();AllDevices=@();Services=@();Startup=@();Tasks=@();KernelServices=@();CapturedAt='fixture';Directories=@{}} }
        Mock Get-GHUBInventory -ModuleName Lifecycle { [pscustomobject]@{Processes=@()} }
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle { [pscustomobject]@{Roots=@();Values=@()} }
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {New-OperationResult}
        Mock Apply-EnvironmentRegistry -ModuleName Coordinator {New-OperationResult}
        Mock Apply-EnvironmentServices -ModuleName Coordinator {New-OperationResult}
        Mock Assert-GHUBDriverPlanSource -ModuleName Coordinator {}
        Mock Invoke-DriverPlan -ModuleName Coordinator {New-OperationResult}
        Mock Get-GHUBHealth -ModuleName Coordinator {[pscustomobject]@{TechnicalPassed=$true;FunctionalStatus='Unverified';Checks=@()}}
        Mock Start-GHUBUserSession -ModuleName Coordinator {New-OperationResult}
    }
    It 'switches without copying any new backup and retains the existing recovery pointer' {
        $manifest=Read-EnvironmentManifest $ctx modern
        $manifest | Add-Member -NotePropertyName BackupPath -NotePropertyValue 'existing-recovery-copy' -Force
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/modern.json') $manifest
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be Ok
        (Read-EnvironmentManifest $ctx modern).BackupPath | Should -Be 'existing-recovery-copy'
        @(Get-ChildItem -LiteralPath (Join-Path $ctx.Root 'Backups') -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
        Get-Content (Join-Path $ctx.Root 'Environments/modern/LocalData/slot.txt') | Should -Be modern
    }
    It 'commits only after all folders have switched and launch checks passed' {
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be Ok
        $state=Read-SwitchState $ctx
        $state.Active | Should -Be legacy
        $state.Phase | Should -Be Idle
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be legacy
    }
    It 'rejects source drift before starting a transaction or stopping the installed program' {
        Mock Assert-GHUBDriverPlanSource -ModuleName Coordinator {throw 'ExternalChange: source binding changed.'}
        {Invoke-GHUBSwitch $ctx legacy} | Should -Throw '*ExternalChange*'
        Should -Invoke Stop-GHUBEnvironment -ModuleName Coordinator -Times 0 -Exactly
        (Read-SwitchState $ctx).Phase | Should -Be Idle
        (Read-SwitchState $ctx).TransactionId | Should -BeNullOrEmpty
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be modern
    }
    It 'checks for source drift again after backup and before exchanging directories' {
        $script:sourceGuardCalls=0
        Mock Assert-GHUBDriverPlanSource -ModuleName Coordinator {
            $script:sourceGuardCalls++
            if($script:sourceGuardCalls -eq 2){throw 'ExternalChange: source binding changed during backup.'}
        }
        Mock Invoke-DirectoryExchange -ModuleName Coordinator {throw 'Directory exchange must not start after source drift.'}
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Status | Should -Be RecoveryRequired
        Should -Invoke Assert-GHUBDriverPlanSource -ModuleName Coordinator -Times 2 -Exactly
        Should -Invoke Invoke-DirectoryExchange -ModuleName Coordinator -Times 0 -Exactly
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be modern
    }
    It 'does not commit a driver change before reboot' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {New-OperationResult PendingReboot RebootRequired 'restart'}
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be PendingReboot
        (Read-SwitchState $ctx).Active | Should -Be modern
        (Read-SwitchState $ctx).Target | Should -Be legacy
    }
    It 'returns the original folders after a driver-stage failure' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {throw 'driver-stage failure'}
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Status | Should -Be Blocked
        $result.Code | Should -Be SwitchFailedRecovered
        $result.Evidence.RequestedTarget | Should -Be legacy
        $result.Evidence.RestoredSlot | Should -Be modern
        (Read-SwitchState $ctx).LastError | Should -Match 'driver-stage failure'
        (Read-SwitchState $ctx).Active | Should -Be modern
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be modern
    }
    It 'retains recovery evidence without overwriting an externally changed environment' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {throw 'ExternalChange: active driver binding changed after capture.'}
        Mock Undo-DirectoryExchange -ModuleName Coordinator {throw 'Automatic rollback must not mutate an externally changed environment.'}
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Status | Should -Be RecoveryRequired
        (Read-SwitchState $ctx).Health | Should -Be Unverified
        (Read-SwitchState $ctx).LastError | Should -Match 'ExternalChange'
        Should -Invoke Undo-DirectoryExchange -ModuleName Coordinator -Times 0 -Exactly
        Should -Invoke Stop-GHUBEnvironment -ModuleName Coordinator -Times 1 -Exactly
        Get-Content (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be legacy
    }
    It 'saves settings written during process exit in the manifest and source journal' {
        $runtimePath="Registry::HKEY_USERS\$($ctx.OwnerSid)\SOFTWARE\Logitech\LGHUB\Data"
        $manifest=Read-EnvironmentManifest $ctx modern
        $manifest.RegistryValues=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value='old'})
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/modern.json') $manifest
        $script:exitSetting='running'
        Mock Stop-GHUBEnvironment -ModuleName Coordinator { $script:exitSetting='saved-on-exit'; New-OperationResult }
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle { [pscustomobject]@{Roots=@();Values=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value=$script:exitSetting})} }
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be Ok
        $saved=Read-EnvironmentManifest $ctx modern
        $saved.RegistryValues[0].Value | Should -Be saved-on-exit
        @(Get-ChildItem -LiteralPath (Join-Path $ctx.Root 'Backups') -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
        $journal=Get-ChildItem -LiteralPath (Join-Path $ctx.Root 'Transactions') -Filter '*.jsonl' | Select-Object -First 1
        (Get-SourceCheckpoint $ctx $journal.BaseName).RegistryValues[0].Value | Should -Be saved-on-exit
    }
    It 'passes the refreshed settings to same-slot launch instead of restoring the old manifest' {
        $runtimePath="Registry::HKEY_USERS\$($ctx.OwnerSid)\SOFTWARE\Logitech\LGHUB\Data"
        $manifest=Read-EnvironmentManifest $ctx modern
        $manifest.RegistryValues=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value='old'})
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/modern.json') $manifest
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle { [pscustomobject]@{Roots=@();Values=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value='latest'})} }
        Mock Complete-GHUBTransaction -ModuleName Coordinator { param($Context,$Manifest) New-OperationResult Ok Ok '' $Manifest }
        $result=Invoke-GHUBSwitch $ctx modern
        $result.Status | Should -Be Ok
        $result.Evidence[0].RegistryValues[0].Value | Should -Be latest
    }
    It 'recovers with the stopped application settings when directory metadata capture fails' {
        $runtimePath="Registry::HKEY_USERS\$($ctx.OwnerSid)\SOFTWARE\Logitech\LGHUB\Data"
        $manifest=Read-EnvironmentManifest $ctx modern
        $manifest.RegistryValues=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value='old'})
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/modern.json') $manifest
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle { [pscustomobject]@{Roots=@();Values=@(@{Path=$runtimePath;Name='setting';Exists=$true;Kind='String';Value='latest'})} }
        Mock Get-TreeFiles -ModuleName Coordinator { throw 'directory metadata capture failed' }
        Mock Complete-GHUBTransaction -ModuleName Coordinator { param($Context,$Manifest) New-OperationResult Ok Ok '' $Manifest }
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Evidence[0].RegistryValues[0].Value | Should -Be latest
        $journal=Get-ChildItem -LiteralPath (Join-Path $ctx.Root 'Transactions') -Filter '*.jsonl' | Select-Object -First 1
        (Get-SourceCheckpoint $ctx $journal.BaseName).RegistryValues[0].Value | Should -Be latest
    }
}
Describe 'Boot and launch gates' {
    It 'resumes a legacy reboot instead of immediately selecting modern' {
        $s=@{Phase='PendingReboot';Target='legacy';Active='modern';BootId='a';RebootRequestedAtBootId='a';TransactionId='tx'}
        $d=Get-BootDecision $s b
        $d.Action | Should -Be Resume
        $d.TargetSlot | Should -Be legacy
    }
    It 'refuses to verify in the same boot' {
        $s=@{Phase='PendingReboot';Target='legacy';Active='modern';BootId='a';RebootRequestedAtBootId='a';TransactionId='tx'}
        (Get-BootDecision $s a).Action | Should -Be WaitForReboot
    }
    It 'recovers an interrupted exchange rather than launching either program' {
        $s=@{Phase='Swapping';Target='legacy';Active='modern';BootId='a';TransactionId='tx'}
        (Get-BootDecision $s b).Action | Should -Be Recover
    }
    It 'chooses modern on an ordinary boot after a completed legacy session' {
        $s=@{Phase='Idle';Target=$null;Active='legacy';BootId='a';TransactionId=$null}
        $d=Get-BootDecision $s b
        $d.Action | Should -Be SwitchModern
    }
    It 'does not switch away from a completed legacy transaction in the same boot' {
        $s=@{Phase='Idle';Target=$null;Active='legacy';BootId='b';TransactionId=$null}
        (Get-BootDecision $s b).Action | Should -Be StartActive
    }
    It 'ignores stale monitor evidence after a switch' {
        Test-MonitorGeneration @{Phase='Idle';Sequence=5;Active='modern'} @{Phase='Idle';Sequence=9;Active='legacy'} | Should -BeFalse
    }
    It 'does not allow an expired or foreign-session launch ticket' {
        $ticket=@{OwnerSid='owner';Enabled=$true;ExpiresUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Slot='legacy'}
        Test-LaunchTicket $ticket owner | Should -BeFalse
        $ticket.ExpiresUtc=[DateTime]::UtcNow.AddMinutes(1).ToString('o')
        Test-LaunchTicket $ticket another | Should -BeFalse
        Test-LaunchTicket $ticket owner | Should -BeTrue
    }
}

Describe 'Quiesced source recovery checkpoints' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $source=[pscustomobject]@{Slot='modern';OwnerSid=$ctx.OwnerSid;ProductVersion='2026.6';RegistryValues=@(@{Path='product-data';Name='setting';Exists=$true;Kind='String';Value='old'})}
        $quiesced=$source | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $quiesced.RegistryValues[0].Value='latest'
    }
    It 'recovers the fresh registry snapshot if backup failed after quiescence' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        (Get-SourceCheckpoint $ctx fixture).RegistryValues[0].Value | Should -Be latest
    }
    It 'continues to recover old journals with only their original source' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        (Get-SourceCheckpoint $ctx fixture).RegistryValues[0].Value | Should -Be old
    }
    It 'rejects ambiguous quiesced snapshots instead of choosing an arbitrary one' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        { Get-SourceCheckpoint $ctx fixture } | Should -Throw '*RecoveryRequired*'
    }
    It 'rejects a quiesced snapshot for a different source identity' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        $quiesced.Slot='legacy'
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        { Get-SourceCheckpoint $ctx fixture } | Should -Throw '*RecoveryRequired*'
    }
    It 'rejects a quiesced snapshot inserted after registry mutation began' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        Add-JournalEntry $ctx fixture Intent registry-setting $null $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        { Get-SourceCheckpoint $ctx fixture } | Should -Throw '*RecoveryRequired*'
    }
    It 'uses the completed backup from this transaction without replacing fresh registry values' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        $backup=@{Slot='modern';OwnerSid=$ctx.OwnerSid;Path='latest-backup';Trees=@(@{Role='Program'});Manifest=$quiesced}
        Add-JournalEntry $ctx fixture Checkpoint bootstrap-backup $backup $null
        $actual=Get-SourceCheckpoint $ctx fixture
        $actual.BackupPath | Should -Be latest-backup
        $actual.RegistryValues[0].Value | Should -Be latest
    }
    It 'rejects a backup that contains the stale registry snapshot' {
        Add-JournalEntry $ctx fixture Checkpoint source $source $null
        Add-JournalEntry $ctx fixture Checkpoint source-quiesced $quiesced $null
        Add-JournalEntry $ctx fixture Checkpoint update-backup @{Slot='modern';OwnerSid=$ctx.OwnerSid;Path='stale-backup';Trees=@();Manifest=$source} $null
        { Get-SourceCheckpoint $ctx fixture } | Should -Throw '*RecoveryRequired*'
    }
}
