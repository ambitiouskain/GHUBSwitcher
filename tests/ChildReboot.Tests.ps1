BeforeAll {
    foreach($name in @('Core','Inventory','Storage','Drivers','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'Completed child installs without a Windows reboot requirement' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $boot='2026-09-30T08:08:02.5Z'
        $device=[pscustomobject]@{InstanceId='LGHUBDEVICE\VID_046D&PID_C232\captured';InfPath='oem21.inf';UpperFilters=@();LowerFilters=@()}
        $before=[pscustomobject]@{InstanceId='LGHUBDEVICE\VID_046D&PID_C232\actual';InfPath='oem118.inf';UpperFilters=@();LowerFilters=@()}
        $action=[pscustomobject]@{DeviceIdentity=$device;TargetPackageId='old-hid';TargetSection='LGVirHid_Device';ExpectedService='logi_joy_vir_hid'}
        $targetKernel=[pscustomobject]@{Name='logi_joy_vir_hid';Path=(Join-Path $env:WINDIR 'System32/drivers/old_hid.sys');Sha256='old'}
        $sourceKernel=[pscustomobject]@{Name='logi_joy_vir_hid';Path=(Join-Path $env:WINDIR 'System32/drivers/new_hid.sys');Sha256='new'}
        $manifest=[pscustomobject]@{Slot='legacy';KernelServices=@($targetKernel);Services=@()}
        $plan=[pscustomobject]@{PlanId='plan-one';DeferredChildren=@($action);SourceEvidence=[pscustomobject]@{KernelServices=@($sourceKernel)}}
        $step='driver-child-'+(Get-TextHash $device.InstanceId)
        $native=[pscustomobject]@{Success=$true;NeedReboot=$false;InfPath=(Join-Path $env:WINDIR 'INF/oem21.inf');Section='LGVirHid_Device'}
        $script:childRecords=@(
            [pscustomobject]@{Sequence=1;Kind='Intent';StepId=$step;Before=$before;After=$action;TimestampUtc='2026-09-30T08:09:00Z'},
            [pscustomobject]@{Sequence=2;Kind='Checkpoint';StepId='child-driver-reboot';Before=@{PlanId='plan-one';BootId=$boot;InstanceId=$before.InstanceId};After=$null;TimestampUtc='2026-09-30T08:09:01Z'},
            [pscustomobject]@{Sequence=3;Kind='Done';StepId=$step;Before=$before;After=$native;TimestampUtc='2026-09-30T08:09:02Z'}
        )
        $state=Read-SwitchState $ctx;$state.Phase='PendingReboot';$state.Target='legacy';$state.RebootRequestedAtBootId=$boot;Write-SwitchState $ctx $state
        Mock Get-BootId -ModuleName Drivers {$boot}
        Mock Get-DriverTransactionPlan -ModuleName Drivers {$plan}
        Mock Read-ValidJournal -ModuleName Drivers {$script:childRecords}
        Mock Test-DriverState -ModuleName Drivers {[pscustomobject]@{TechnicalPassed=$true}}
    }
    It 'continues a completely verified child-only change without requiring another boot' {
        Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@($targetKernel.Path)}
        Test-GHUBChildRebootSatisfied $ctx $manifest | Should -BeTrue
    }
    It 'reads source kernel evidence from the transaction checkpoint for previously saved plans' {
        Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@($targetKernel.Path)}
        $plan.SourceEvidence.PSObject.Properties.Remove('KernelServices')
        $plan|Add-Member SourceSlot modern
        $script:childRecords+=@([pscustomobject]@{Sequence=4;Kind='Checkpoint';StepId='source';Before=@{Slot='modern';OwnerSid=$ctx.OwnerSid;KernelServices=@($sourceKernel)};TimestampUtc='2026-09-30T08:00:00Z'})
        Test-GHUBChildRebootSatisfied $ctx $manifest | Should -BeTrue
    }
    It 'retains the gate for an unsafe completion: <Case>' -TestCases @(
        @{Case='WindowsRequiresReboot'},@{Case='MissingRebootFlag'},@{Case='Interrupted'},@{Case='WrongInstance'},
        @{Case='WrongSection'},@{Case='WrongInf'},@{Case='ChangedFilters'},@{Case='LaterParentMutation'},
        @{Case='AuxiliaryMutation'},@{Case='NoChildGate'},@{Case='LaterUnfinishedChild'},@{Case='WrongPlan'},@{Case='StringFalse'}
    ) {
        param($Case)
        Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@($targetKernel.Path)}
        switch($Case){
            WindowsRequiresReboot {$native.NeedReboot=$true}
            MissingRebootFlag {$native.PSObject.Properties.Remove('NeedReboot')}
            Interrupted {$script:childRecords=$script:childRecords[0..1]}
            WrongInstance {$script:childRecords[1].Before.InstanceId='another-child'}
            WrongSection {$native.Section='another-section'}
            WrongInf {$native.InfPath='C:\Windows\INF\oem999.inf'}
            ChangedFilters {$before.UpperFilters=@('logi_joy_filter')}
            LaterParentMutation {$script:childRecords+=@([pscustomobject]@{Sequence=4;Kind='Intent';StepId='driver-parent';TimestampUtc='2026-09-30T08:10:00Z'})}
            AuxiliaryMutation {$script:childRecords+=@([pscustomobject]@{Sequence=4;Kind='Intent';StepId='auxiliary-logi_joy_vir_hid';TimestampUtc='2026-09-30T08:10:00Z'})}
            NoChildGate {$script:childRecords=@()}
            LaterUnfinishedChild {$script:childRecords+=@([pscustomobject]@{Sequence=4;Kind='Intent';StepId=$step;Before=$before;After=$action;TimestampUtc='2026-09-30T08:10:00Z'})}
            WrongPlan {$script:childRecords[1].Before.PlanId='another-plan'}
            StringFalse {$native.NeedReboot='false'}
        }
        Test-GHUBChildRebootSatisfied $ctx $manifest | Should -BeFalse
    }
    It 'retains the gate when loaded images are inconclusive or stale: <Case>' -TestCases @(
        @{Case='SourceLoaded'},@{Case='TargetMissing'},@{Case='EnumerationFailed'},@{Case='SamePathDifferentVersion'},@{Case='HealthFailed'}
    ) {
        param($Case)
        Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@($targetKernel.Path)}
        switch($Case){
            SourceLoaded {Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@($targetKernel.Path,$sourceKernel.Path)}}
            TargetMissing {Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {@()}}
            EnumerationFailed {Mock Get-GHUBLoadedDriverPaths -ModuleName Drivers {throw 'unavailable'}}
            SamePathDifferentVersion {$sourceKernel.Path=$targetKernel.Path}
            HealthFailed {Mock Test-DriverState -ModuleName Drivers {[pscustomobject]@{TechnicalPassed=$false}}}
        }
        Test-GHUBChildRebootSatisfied $ctx $manifest | Should -BeFalse
    }
}
