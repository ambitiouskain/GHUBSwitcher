BeforeAll {
    foreach($module in @('Core','Inventory','Storage','Lifecycle','Drivers','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$module.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    function New-RollbackFixture {
        $system='{4d36e97d-e325-11ce-bfc1-08002be10318}';$hid='{745a17a0-74d3-11d0-b6fe-00a0c90f57da}'
        $bus=[pscustomobject]@{InstanceId='ROOT\SYSTEM\0001';HardwareIds=@('root\LGHUBVirtualBus');ContainerId='';ParentInstanceId='HTREE\ROOT\0';ClassGuid=$system;PackageId='old-bus';Service='logi_joy_bus_enum';UpperFilters=@();LowerFilters=@();InfSection='Bus';InfPath='oem1.inf';DriverVersion='2021';ProblemCode=0}
        $newBus=$bus|ConvertTo-Json -Depth 12|ConvertFrom-Json;$newBus.PackageId='new-bus';$newBus.DriverVersion='2026';$newBus.InfPath='oem2.inf'
        $child=[pscustomobject]@{InstanceId='LGHUBDEVICE\VID_046D&PID_C232\recorded';HardwareIds=@('LGHUBDevice\VID_046D&PID_C232');ContainerId='11111111-1111-1111-1111-111111111111';ParentInstanceId=$bus.InstanceId;ClassGuid=$hid;PackageId='new-child';Service='logi_joy_vir_hid';UpperFilters=@();LowerFilters=@();InfSection='Child';InfPath='oem3.inf';DriverVersion='2026';ProblemCode=0}
        $classes=@([pscustomobject]@{ClassGuid=$system;UpperFilters=@();LowerFilters=@()},[pscustomobject]@{ClassGuid=$hid;UpperFilters=@();LowerFilters=@()})
        $old=[pscustomobject]@{Slot='legacy';OwnerSid='fixture-owner';ProductVersion='2021.3';Services=@();RegistryValues=@();Devices=@($bus);DriverPackages=@([pscustomobject]@{PackageId='old-bus';ExportPath='fixture';InfRelative='old.inf';InfHash='old'});KernelServices=@();ClassFilters=@($classes[0])}
        $new=[pscustomobject]@{Slot='modern';OwnerSid='fixture-owner';ProductVersion='2026.6';Services=@();RegistryValues=@();Devices=@($newBus,$child);DriverPackages=@([pscustomobject]@{PackageId='new-bus';ExportPath='fixture';InfRelative='new.inf';InfHash='new'},[pscustomobject]@{PackageId='new-child';ExportPath='fixture';InfRelative='child.inf';InfHash='child'});KernelServices=@();ClassFilters=$classes}
        $unbound=$child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$unbound.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\recreated';$unbound.Service='';$unbound.InfPath='';$unbound.ClassGuid='';$unbound.PackageId='';$unbound.DriverVersion='';$unbound.InfSection='';$unbound.ProblemCode=28
        [pscustomobject]@{Old=$old;New=$new;Classes=$classes;Unbound=$unbound}
    }
}

Describe 'Rollback of a captured bus with a clean unbound deferred child' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $fixture=New-RollbackFixture;$fixture.Old.OwnerSid=$ctx.OwnerSid;$fixture.New.OwnerSid=$ctx.OwnerSid
        Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'old'}oem2.inf{'new'}oem3.inf{'child'}default{'uncaptured'}})} }
        $forward=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Add-JournalEntry $ctx fixture Checkpoint source $fixture.Old $fixture.New
        Save-GHUBDriverPlan $ctx $forward
        Add-JournalEntry $ctx fixture Intent driver-new-bus $fixture.Old.Devices[0] $forward.DeviceActions[0]
        $script:rollbackPresent=@($fixture.New.Devices[0],$fixture.Unbound)
        $script:rollbackEvents=[Collections.Generic.List[string]]::new()
        Mock Assert-Administrator -ModuleName Drivers {}
        Mock Initialize-NativeLibrary -ModuleName Drivers {}
        Mock Assert-DriverPackage -ModuleName Drivers {}
        Mock Get-NativeDevices -ModuleName Drivers { $script:rollbackPresent }
        Mock Get-ClassFilterInventory -ModuleName Drivers { $fixture.Classes }
        Mock Stage-GHUBDriverPackage -ModuleName Drivers {param($Context,$Package) $script:rollbackEvents.Add('stage:'+$Package.PackageId);$Package.InfRelative}
        Mock Invoke-GHUBDriverBinding -ModuleName Drivers {param($InstanceId) $script:rollbackEvents.Add('bind:'+$InstanceId);[pscustomobject]@{Success=$true;NeedReboot=$true}}
        Mock Get-GHUBInventory -ModuleName Coordinator { [pscustomobject]@{ProductVersion='2026.6';Directories=@{};CapturedAt='fixture';Processes=@();Services=@();Startup=@();Tasks=@();KernelServices=@();Devices=$script:rollbackPresent;AllDevices=$script:rollbackPresent;ClassFilters=$fixture.Classes} }
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {New-OperationResult}
        Mock Stop-EnvironmentAppLocalKernel -ModuleName Coordinator {New-OperationResult}
        Mock Restore-EnvironmentAppLocalKernel -ModuleName Coordinator {New-OperationResult}
        Mock Apply-EnvironmentServices -ModuleName Coordinator {New-OperationResult}
        Mock Export-ManagedDrivers -ModuleName Coordinator {throw 'Rollback must use captured package evidence, not export the current unbound or unknown driver.'}
        $state=Read-SwitchState $ctx;$state.Phase='AwaitingLogon';$state.Active='legacy';$state.Target='modern';Write-SwitchState $ctx $state
    }
    It 'reverses the captured parent without exporting or binding the unbound child and persists a new plan' {
        (Invoke-GHUBRollback $ctx 'Controlled launch failed.').Status | Should -Be PendingReboot
        (Read-SwitchState $ctx).Target | Should -Be legacy
        ($script:rollbackEvents -join ',') | Should -Be 'stage:old-bus,bind:ROOT\SYSTEM\0001'
        $plans=@(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ driver-plan)
        $plans.Count | Should -Be 2
        $plans[-1].After.PlanId | Should -Not -Be $forward.PlanId
        $plans[-1].After.TargetSlot | Should -Be legacy
        @($plans[-1].After.SourceEvidence.Devices).Count | Should -Be 1
        @($plans[-1].After.RemovedChildren).Count | Should -Be 1
    }
    It 'rejects unsafe intermediate child or parent evidence before rollback changes directories' -TestCases @(
        @{Mutation='ForeignBinding'},@{Mutation='UnknownParentBinding'},@{Mutation='ManagedFilter'},@{Mutation='ForeignFilter'},@{Mutation='WrongParent'},@{Mutation='UnknownHardware'},@{Mutation='DuplicateChild'},@{Mutation='ForeignClass'}
    ) {
        param($Mutation)
        switch($Mutation){
            ForeignBinding {$fixture.Unbound.Service='other';$fixture.Unbound.InfPath='oem999.inf';$fixture.Unbound.ClassGuid=$fixture.New.Devices[1].ClassGuid}
            UnknownParentBinding {$parent=$fixture.New.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$parent.InfPath='oem999.inf';$script:rollbackPresent=@($parent,$fixture.Unbound)}
            ManagedFilter {$fixture.Unbound.UpperFilters=@('logi_joy_unexpected')}
            ForeignFilter {$fixture.Unbound.UpperFilters=@('foreign-filter')}
            WrongParent {$fixture.Unbound.ParentInstanceId='ROOT\SYSTEM\foreign'}
            UnknownHardware {$fixture.Unbound.HardwareIds=@('LGHUBDevice\VID_046D&PID_9999')}
            DuplicateChild {$other=$fixture.Unbound|ConvertTo-Json -Depth 12|ConvertFrom-Json;$other.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\duplicate';$script:rollbackPresent+=@($other)}
            ForeignClass {$fixture.Unbound.ClassGuid='{4d36e96b-e325-11ce-bfc1-08002be10318}'}
        }
        Mock Undo-DirectoryExchange -ModuleName Coordinator {throw 'Rollback must not touch directories after detecting unknown driver state.'}
        $result=Invoke-GHUBRollback $ctx 'Controlled launch failed.'
        $result.Status | Should -Be RecoveryRequired
        $result.Message | Should -Match 'ExternalChange'
        Should -Invoke Undo-DirectoryExchange -ModuleName Coordinator -Times 0 -Exactly
        $script:rollbackEvents.Count | Should -Be 0
    }
    It 'does not adopt an unbound child without a recorded forward parent binding attempt' {
        $ctx2=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Add-JournalEntry $ctx2 fixture Checkpoint source $fixture.Old $fixture.New
        Save-GHUBDriverPlan $ctx2 $forward
        {New-GHUBRollbackDriverPlan $ctx2 $fixture.Old $fixture.New @{Devices=$script:rollbackPresent;AllDevices=$script:rollbackPresent;ClassFilters=$fixture.Classes;KernelServices=@()}} | Should -Throw '*ExternalChange*'
    }
    It 'checks the unbound child again after package staging before the reverse native binding' -TestCases @(@{Drift='Binding'},@{Drift='Class'},@{Drift='NewChild'}) {
        param($Drift)
        $plan=New-GHUBRollbackDriverPlan $ctx $fixture.Old $fixture.New @{Devices=$script:rollbackPresent;AllDevices=$script:rollbackPresent;ClassFilters=$fixture.Classes;KernelServices=@()}
        Mock Stage-GHUBDriverPackage -ModuleName Drivers {
            param($Context,$Package)
            switch($Drift){
                Binding {$fixture.Unbound.InfPath='oem999.inf';$fixture.Unbound.Service='other'}
                Class {$fixture.Unbound.ClassGuid='{4d36e96b-e325-11ce-bfc1-08002be10318}'}
                NewChild {$other=$fixture.Unbound|ConvertTo-Json -Depth 12|ConvertFrom-Json;$other.InstanceId='LGHUBDEVICE\VID_046D&PID_9999\new';$other.HardwareIds=@('LGHUBDevice\VID_046D&PID_9999');$script:rollbackPresent+=@($other)}
            }
            $Package.InfRelative
        }
        {Invoke-DriverPlan $ctx $plan} | Should -Throw '*ExternalChange*'
        @($script:rollbackEvents | Where-Object {$_ -like 'bind:*'}).Count | Should -Be 0
    }
    It 'checks rollback source drift after stopping the application before restoring directories' {
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {$fixture.Unbound.InfPath='oem999.inf';$fixture.Unbound.Service='other';New-OperationResult}
        Mock Undo-DirectoryExchange -ModuleName Coordinator {throw 'Directory rollback must not begin after the driver source changed.'}
        $result=Invoke-GHUBRollback $ctx 'Controlled launch failed.'
        $result.Status | Should -Be RecoveryRequired
        $result.Message | Should -Match 'ExternalChange'
        Should -Invoke Undo-DirectoryExchange -ModuleName Coordinator -Times 0 -Exactly
        $script:rollbackEvents.Count | Should -Be 0
    }
    It 'does not weaken ordinary source planning to accept an unbound captured child' {
        {New-DriverPlan $fixture.New $fixture.Old @{Devices=$script:rollbackPresent;AllDevices=$script:rollbackPresent;ClassFilters=$fixture.Classes}} | Should -Throw '*ExternalChange*'
    }
    It 'can restore modern from the old captured parent while its captured modern child is absent' {
        $reverseContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $downgrade=New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $reverseContext $downgrade
        $rollback=New-GHUBRollbackDriverPlan $reverseContext $fixture.New $fixture.Old @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes;KernelServices=@()}
        $rollback.PlanId | Should -Not -Be $downgrade.PlanId
        $rollback.TargetSlot | Should -Be modern
        @($rollback.DeferredChildren).Count | Should -Be 1
        $rollback.DeferredChildren[0].TargetPackageId | Should -Be new-child
        @($rollback.RollbackUnboundChildren).Count | Should -Be 0
    }
    It 'uses captured packages for a fully bound target rollback too' {
        $plan=New-GHUBRollbackDriverPlan $ctx $fixture.Old $fixture.New @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes;KernelServices=@()}
        $plan.DeviceActions[0].SourcePackageId | Should -Be new-bus
        $plan.DeviceActions[0].TargetPackageId | Should -Be old-bus
        @($plan.RemovedChildren).Count | Should -Be 1
        @($plan.RollbackUnboundChildren).Count | Should -Be 0
    }
    It 'rolls back a target-only child with inferred source-package state <ChildState>' -TestCases @(@{ChildState='Bound'},@{ChildState='Unbound'}) {
        param($ChildState)
        $extra=$fixture.New.Devices[1]|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $extra.InstanceId='LGHUBDEVICE\VID_046D&PID_C231\recorded';$extra.HardwareIds=@('LGHUBDevice\VID_046D&PID_C231')
        $extra.PackageId='old-child';$extra.DriverVersion='2021';$extra.InfPath='oem4.inf'
        $fixture.Old.Devices+=@($extra);$fixture.Old.ClassFilters=$fixture.Classes
        $fixture.Old.DriverPackages+=@([pscustomobject]@{PackageId='old-child';ExportPath='fixture';InfRelative='old-child.inf';InfHash='old-child'})
        Mock Get-GHUBInfModels -ModuleName Drivers { @([pscustomobject]@{Values=@('Child','LGHUBDevice\VID_046D&PID_C231')}) }
        Mock Get-FileHash -ModuleName Drivers -ParameterFilter {$LiteralPath -like '*\child.inf'} {[pscustomobject]@{Hash='child'}}
        $ctx2=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $down=New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx2 $down
        Add-JournalEntry $ctx2 fixture Intent driver-old-bus $fixture.New.Devices[0] $down.DeviceActions[0]
        $actual=$down.DeferredChildren[0].SourceIdentity|ConvertTo-Json -Depth 20|ConvertFrom-Json
        if($ChildState -eq 'Unbound'){$actual.Service='';$actual.InfPath='';$actual.ClassGuid='';$actual.ProblemCode=28}
        $present=@($fixture.Old.Devices[0],$actual)
        $plan=New-GHUBRollbackDriverPlan $ctx2 $fixture.New $fixture.Old @{Devices=$present;AllDevices=$present;ClassFilters=$fixture.Classes;KernelServices=@()}
        $plan.TargetSlot | Should -Be modern
        if($ChildState -eq 'Unbound'){@($plan.RollbackUnboundChildren).Count | Should -Be 1}
        else{@($plan.SourceEvidence.Devices|Where-Object InstanceId -EQ $actual.InstanceId).Count | Should -Be 1}
    }
    It 'rejects source or target evidence that changed after the forward plan was persisted' -TestCases @(@{Side='Old'},@{Side='New'}) {
        param($Side)
        $fixture.$Side.DriverPackages[0].InfHash='substituted'
        {New-GHUBRollbackDriverPlan $ctx $fixture.Old $fixture.New @{Devices=$script:rollbackPresent;AllDevices=$script:rollbackPresent;ClassFilters=$fixture.Classes;KernelServices=@()}} | Should -Throw '*ExternalChange*'
    }
}
