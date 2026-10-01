BeforeAll {
    foreach($module in @('Core','Inventory','Storage','Drivers','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$module.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    function New-TopologyFixture {
        $system='{4d36e97d-e325-11ce-bfc1-08002be10318}';$hid='{745a17a0-74d3-11d0-b6fe-00a0c90f57da}'
        $bus=[pscustomobject]@{InstanceId='ROOT\SYSTEM\0001';HardwareIds=@('root\LGHUBVirtualBus');ContainerId='';ParentInstanceId='HTREE\ROOT\0';ClassGuid=$system;PackageId='old-bus';Service='logi_joy_bus_enum';UpperFilters=@();LowerFilters=@();InfSection='Bus';InfPath='oem1.inf';DriverVersion='2021';ProblemCode=0}
        $newBus=$bus|ConvertTo-Json -Depth 12|ConvertFrom-Json;$newBus.PackageId='new-bus';$newBus.DriverVersion='2026';$newBus.InfPath='oem2.inf'
        $child=[pscustomobject]@{InstanceId='LGHUBDEVICE\VID_046D&PID_C232\recorded';HardwareIds=@('LGHUBDevice\VID_046D&PID_C232');ContainerId='11111111-1111-1111-1111-111111111111';ParentInstanceId=$bus.InstanceId;ClassGuid=$hid;PackageId='new-child';Service='logi_joy_vir_hid';UpperFilters=@();LowerFilters=@();InfSection='Child';InfPath='oem3.inf';DriverVersion='2026';ProblemCode=0}
        $classes=@([pscustomobject]@{ClassGuid=$system;UpperFilters=@();LowerFilters=@()},[pscustomobject]@{ClassGuid=$hid;UpperFilters=@();LowerFilters=@()})
        $old=[pscustomobject]@{Slot='legacy';OwnerSid='fixture-owner';ProductVersion='2021.3';Devices=@($bus);DriverPackages=@([pscustomobject]@{PackageId='old-bus';ExportPath='fixture';InfRelative='old.inf';InfHash='old'});KernelServices=@();ClassFilters=@($classes[0])}
        $new=[pscustomobject]@{Slot='modern';OwnerSid='fixture-owner';ProductVersion='2026.6';Devices=@($newBus,$child);DriverPackages=@([pscustomobject]@{PackageId='new-bus';ExportPath='fixture';InfRelative='new.inf';InfHash='new'},[pscustomobject]@{PackageId='new-child';ExportPath='fixture';InfRelative='child.inf';InfHash='child'});KernelServices=@();ClassFilters=$classes}
        [pscustomobject]@{Old=$old;New=$new;Classes=$classes;Child=$child}
    }
}

Describe 'Captured virtual children beneath the common G HUB bus' {
    BeforeEach {
        $fixture=New-TopologyFixture
        Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'old'}oem2.inf{'new'}oem3.inf{'child'}oem4.inf{'old-child'}default{'uncaptured'}})} }
    }
    It 'plans the captured modern child after binding the shared parent instead of requiring it beforehand' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        $plan.RequiresRestart | Should -BeTrue
        $plan.DeviceActions[0].TargetPackageId | Should -Be new-bus
        @($plan.DeferredChildren).Count | Should -Be 1
        $plan.DeferredChildren[0].TargetPackageId | Should -Be new-child
        @($plan.PackagesToStage).Count | Should -Be 2
    }
    It 'records removal of only the captured virtual child when switching back to the old bus' {
        $plan=New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes}
        @($plan.RemovedChildren).Count | Should -Be 1
        $plan.RemovedChildren[0].InstanceId | Should -Be $fixture.Child.InstanceId
        $plan.RequiresRestart | Should -BeTrue
    }
    It 'requires an exact source INF model for a newly enumerated child (model: <Model>, section: <Section>)' -TestCases @(
        @{Model='LGHUBDevice\VID_046D&PID_C231';Section='Child';Allowed=$true},
        @{Model='LGHUBDevice\OTHER';Section='Child';Allowed=$false},
        @{Model='LGHUBDevice\VID_046D&PID_C231';Section='OtherSection';Allowed=$false}
    ) {
        param($Model,$Section,$Allowed)
        $extra=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json
        $extra.InstanceId='LGHUBDEVICE\VID_046D&PID_C231\recorded'
        $extra.HardwareIds=@('LGHUBDevice\VID_046D&PID_C231')
        $extra.PackageId='old-child';$extra.DriverVersion='2021';$extra.InfPath='oem4.inf'
        $fixture.Old.Devices+=@($extra);$fixture.Old.ClassFilters=$fixture.Classes
        $fixture.Old.DriverPackages+=@([pscustomobject]@{PackageId='old-child';ExportPath='fixture';InfRelative='old-child.inf';InfHash='old-child'})
        # Downgrade target C231 is absent from the currently running source.
        Mock Get-GHUBInfModels -ModuleName Drivers { @([pscustomobject]@{Values=@($Section,$Model)}) }
        Mock Get-FileHash -ModuleName Drivers -ParameterFilter {$LiteralPath -like '*child.inf'} { [pscustomobject]@{Hash='child'} }
        $plan=New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes}
        if($Allowed){
            $plan.DeferredChildren[0].SourceIdentity.PackageId | Should -Be new-child
            $plan.DeferredChildren[0].SourceIdentity.HardwareIds[0] | Should -Be 'LGHUBDevice\VID_046D&PID_C231'
        }else{$plan.DeferredChildren[0].SourceIdentity | Should -BeNullOrEmpty}
    }
    It 'does not allow a virtual child under a different parent to become an optional device' {
        $fixture.New.Devices[1].ParentInstanceId='ROOT\SYSTEM\unowned'
        { New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes} } | Should -Throw
    }
    It 'rejects a topology change when the common parent package is not changing' {
        $fixture.New.Devices[0].PackageId='old-bus'
        { New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes} } | Should -Throw '*SharedDependency*'
    }
    It 'still blocks a captured child package used outside the owned parent' {
        $foreign=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$foreign.InstanceId='foreign';$foreign.ParentInstanceId='foreign-parent'
        { New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=@($fixture.New.Devices)+@($foreign);ClassFilters=$fixture.Classes} } | Should -Throw '*SharedDependency*'
    }
    It 'does not use one-sided child class evidence to overlook a changed global filter' {
        $actual=$fixture.Classes|ConvertTo-Json -Depth 12|ConvertFrom-Json;$actual[1].UpperFilters=@('foreign-filter')
        { New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$actual} } | Should -Throw '*SharedDependency*'
    }
    It 'requires captured class evidence for every optional virtual child' {
        $fixture.New.ClassFilters=@($fixture.Classes[0])
        { New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes} } | Should -Throw '*SharedDependency*'
    }
    It 'resolves a recreated child only through the same parent and unique recorded hardware identity' {
        $recreated=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$recreated.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\recreated';$recreated.ContainerId='22222222-2222-2222-2222-222222222222'
        (Resolve-GHUBVirtualChild $fixture.Child $fixture.New.Devices[0] @($fixture.New.Devices[0],$recreated)).InstanceId | Should -Be $recreated.InstanceId
        $other=$recreated|ConvertTo-Json -Depth 12|ConvertFrom-Json;$other.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\duplicate'
        { Resolve-GHUBVirtualChild $fixture.Child $fixture.New.Devices[0] @($fixture.New.Devices[0],$recreated,$other) } | Should -Throw '*DeviceAmbiguous*'
    }
    It 'does not let a source-only virtual child remain present after a supposedly completed downgrade' {
        $checks=@(Compare-GHUBVirtualTopology $fixture.Old @($fixture.New) $fixture.New.Devices)
        @($checks | Where-Object {-not $_.Passed}).Count | Should -Be 1
        $checks[0].Failures | Should -Contain 'SourceChildStillPresent'
    }
    It 'checks lingering children under the resolved parent when its instance path changed' {
        $fixture.Old.Devices[0].ContainerId='33333333-3333-3333-3333-333333333333'
        $actualParent=$fixture.Old.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$actualParent.InstanceId='ROOT\SYSTEM\0009'
        $actualChild=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$actualChild.ParentInstanceId=$actualParent.InstanceId
        $checks=@(Compare-GHUBVirtualTopology $fixture.Old @($fixture.New) @($actualParent,$actualChild))
        @($checks | Where-Object {-not $_.Passed}).Count | Should -Be 1
        $checks[0].Failures | Should -Contain SourceChildStillPresent
    }
}

Describe 'Persisted parent-first driver execution' {
    BeforeEach {
        $fixture=New-TopologyFixture
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $fixture.Old.OwnerSid=$ctx.OwnerSid;$fixture.New.OwnerSid=$ctx.OwnerSid
        $script:topologyPresent=@($fixture.Old.Devices)
        $script:topologyEvents=[Collections.Generic.List[string]]::new()
        Mock Assert-Administrator -ModuleName Drivers {}
        Mock Initialize-NativeLibrary -ModuleName Drivers {}
        Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'old'}oem2.inf{'new'}oem3.inf{'child'}oem4.inf{'old-child'}default{'uncaptured'}})} }
        Mock Get-ClassFilterInventory -ModuleName Drivers { $fixture.Classes }
        Mock Get-NativeDevices -ModuleName Drivers { $script:topologyPresent }
        Mock Get-BootId -ModuleName Drivers { 'boot-one' }
        Mock Assert-DriverPackage -ModuleName Drivers {}
        Mock Stage-GHUBDriverPackage -ModuleName Drivers { param($Context,$Package) $script:topologyEvents.Add('stage:'+$Package.PackageId); $Package.InfRelative }
        Mock Invoke-GHUBDriverBinding -ModuleName Drivers { param($InstanceId,$PublishedInf,$Section) $script:topologyEvents.Add('bind:'+$InstanceId);[pscustomobject]@{Success=$true;NeedReboot=$true} }
    }
    It 'stages the child package before the parent rebind and persists its pending work before mutation' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        (Invoke-DriverPlan $ctx $plan).Status | Should -Be PendingReboot
        ($script:topologyEvents -join ',') | Should -Be 'stage:new-bus,stage:new-child,bind:ROOT\SYSTEM\0001'
        $journal=@(Read-ValidJournal $ctx fixture)
        $saved=@($journal | Where-Object StepId -EQ driver-plan)
        $saved.Count | Should -Be 1
        @($saved[0].After.DeferredChildren).Count | Should -Be 1
        @($journal | Where-Object {$_.Kind -eq 'Intent' -and $_.Sequence -lt $saved[0].Sequence}).Count | Should -Be 0
    }
    It 'preserves missing child work for controlled launch without reporting final success' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Add-JournalEntry $ctx fixture Checkpoint driver-plan $null $plan
        $script:topologyPresent=@($fixture.New.Devices[0])
        Mock Test-GHUBDeviceBinding -ModuleName Drivers { [pscustomobject]@{Passed=$true} }
        $result=Resume-GHUBVirtualChildren $ctx $fixture.New
        $result.Status | Should -Be AwaitingDevices
        @($result.Evidence).Count | Should -Be 1
        { Resume-GHUBVirtualChildren $ctx $fixture.New -AfterLaunch } | Should -Throw '*DeviceMissing*'
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'permits only recorded pending children in prelaunch checks and still fails final health without them' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $script:topologyPresent=@($fixture.New.Devices[0])
        Mock Test-GHUBDeviceBinding -ModuleName Drivers { param($Expected,$Actual,$Packages) [pscustomobject]@{Passed=$true;Device=$Actual.InstanceId;Failures=@()} }
        Mock Get-KernelInventory -ModuleName Drivers { @() }
        Mock Get-ClassFilterInventory -ModuleName Drivers { $fixture.Classes }
        (Test-DriverState $ctx $fixture.New -AllowPendingChildren).TechnicalPassed | Should -BeTrue
        (Test-DriverState $ctx $fixture.New).TechnicalPassed | Should -BeFalse
    }
    It 'does not reuse a plan whose target driver evidence changed after it was saved' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $fixture.New.DriverPackages[0].InfHash='unexpected'
        { Get-DriverTransactionPlan $ctx $fixture.New } | Should -Throw '*RecoveryRequired*'
    }
    It 'keeps forward and recovery plans distinct and selects the latest direction' {
        $forward=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $forward
        $reverse=New-DriverPlan $fixture.New $fixture.Old @{Devices=$fixture.New.Devices;AllDevices=$fixture.New.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $reverse
        (Get-DriverTransactionPlan $ctx $fixture.New) | Should -BeNullOrEmpty
        (Get-DriverTransactionPlan $ctx $fixture.Old).PlanId | Should -Be $reverse.PlanId
        Save-GHUBDriverPlan $ctx $reverse
        @(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ driver-plan).Count | Should -Be 2
    }
    It 'binds an unbound recreated child once and requires a real boot before committing its new driver' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $unbound=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$unbound.InfPath='';$unbound.Service='';$unbound.ClassGuid='';$unbound.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\new-instance'
        $script:topologyPresent=@($fixture.New.Devices[0],$unbound)
        Mock Test-GHUBDeviceBinding -ModuleName Drivers {param($Expected,$Actual,$Packages) [pscustomobject]@{Passed=($Actual.InfPath -eq $Expected.InfPath)} }
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        (Resume-GHUBVirtualChildren $ctx $fixture.New).Status | Should -Be PendingReboot
        $script:topologyEvents | Should -Contain ('bind:'+$unbound.InstanceId)
        # Windows exposes the captured binding after reboot; the continuation must not reinstall it.
        $script:topologyPresent=@($fixture.New.Devices)
        $script:topologyEvents.Clear()
        Mock Get-BootId -ModuleName Drivers { 'boot-two' }
        (Resume-GHUBVirtualChildren $ctx $fixture.New -AfterLaunch).Status | Should -Be Ok
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'retains the reboot gate after a completed child bind even before the coordinator saved PendingReboot' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $unbound=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$unbound.InfPath='';$unbound.Service='';$unbound.ClassGuid=''
        $script:topologyPresent=@($fixture.New.Devices[0],$unbound)
        Mock Test-GHUBDeviceBinding -ModuleName Drivers {param($Expected,$Actual,$Packages) [pscustomobject]@{Passed=($Actual.InfPath -eq $Expected.InfPath)} }
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        (Resume-GHUBVirtualChildren $ctx $fixture.New).Status | Should -Be PendingReboot
        # The binding is now visible but this is still the boot in which it changed.
        $script:topologyPresent=@($fixture.New.Devices)
        $script:topologyEvents.Clear()
        (Resume-GHUBVirtualChildren $ctx $fixture.New).Status | Should -Be PendingReboot
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'journals a filter change introduced by the native child installer and retains its reboot gate' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $unbound=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$unbound.InfPath='';$unbound.Service='';$unbound.ClassGuid=''
        $script:topologyPresent=@($fixture.New.Devices[0],$unbound)
        Mock Test-GHUBDeviceBinding -ModuleName Drivers {param($Expected,$Actual,$Packages) [pscustomobject]@{Passed=($Actual.InfPath -eq $Expected.InfPath)} }
        Mock Invoke-GHUBDriverBinding -ModuleName Drivers {
            $changed=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$changed.UpperFilters=@('logi_joy_extra')
            $script:topologyPresent=@($fixture.New.Devices[0],$changed)
            [pscustomobject]@{Success=$true;NeedReboot=$false}
        }
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers { $script:topologyPresent=@($fixture.New.Devices) }
        (Resume-GHUBVirtualChildren $ctx $fixture.New).Status | Should -Be PendingReboot
        $mutations=@(Read-ValidJournal $ctx fixture | Where-Object {$_.Kind -eq 'Intent' -and $_.StepId -like 'filters-child-*'})
        $mutations.Count | Should -Be 1
        $mutations[0].Before.UpperFilters | Should -Contain 'logi_joy_extra'
    }
    It 'rejects source binding drift after planning before any driver staging' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        $actual=$fixture.Old.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$actual.InfPath='oem999.inf'
        $script:topologyPresent=@($actual)
        { Invoke-DriverPlan $ctx $plan } | Should -Throw '*ExternalChange*'
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'rejects global filter drift after planning before driver staging' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        $changed=$fixture.Classes|ConvertTo-Json -Depth 12|ConvertFrom-Json;$changed[0].UpperFilters=@('foreign-filter')
        Mock Get-ClassFilterInventory -ModuleName Drivers { $changed }
        { Invoke-DriverPlan $ctx $plan } | Should -Throw '*ExternalChange*'
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'checks the source again after staging and before the native parent rebind' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Mock Stage-GHUBDriverPackage -ModuleName Drivers {
            param($Context,$Package)
            $changed=$fixture.Old.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$changed.InfPath='oem999.inf'
            $script:topologyPresent=@($changed);$Package.InfRelative
        }
        { Invoke-DriverPlan $ctx $plan } | Should -Throw '*ExternalChange*'
        @($script:topologyEvents | Where-Object {$_ -like 'bind:*'}).Count | Should -Be 0
    }
    It 'permits only the captured source or target filters after a recorded parent rebind' -TestCases @(
        @{ActualFilter='logi_joy_source';Allowed=$true},
        @{ActualFilter='logi_joy_unexpected';Allowed=$false}
    ) {
        param($ActualFilter,$Allowed)
        $fixture.Old.Devices[0].UpperFilters=@('logi_joy_source');$fixture.New.Devices[0].UpperFilters=@('logi_joy_target')
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Mock Invoke-GHUBDriverBinding -ModuleName Drivers {
            $changed=$fixture.New.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$changed.UpperFilters=@($ActualFilter)
            $script:topologyPresent=@($changed);[pscustomobject]@{Success=$true;NeedReboot=$true}
        }
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers { $script:topologyEvents.Add('filters') }
        if($Allowed){(Invoke-DriverPlan $ctx $plan).Status | Should -Be PendingReboot;$script:topologyEvents | Should -Contain filters}
        else {{ Invoke-DriverPlan $ctx $plan } | Should -Throw '*ExternalChange*';$script:topologyEvents | Should -Not -Contain filters}
    }
    It 'rejects an unexpected bound child instead of replacing its package' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $other=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$other.InfPath='oem999.inf';$other.DriverVersion='999.0'
        $script:topologyPresent=@($fixture.New.Devices[0],$other)
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        { Resume-GHUBVirtualChildren $ctx $fixture.New } | Should -Throw '*ExternalChange*'
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'rejects managed filter drift on an unbound child instead of treating it as a clean enumeration' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $unbound=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$unbound.InfPath='';$unbound.Service='';$unbound.ClassGuid='';$unbound.UpperFilters=@('logi_joy_unexpected')
        $script:topologyPresent=@($fixture.New.Devices[0],$unbound)
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        { Resume-GHUBVirtualChildren $ctx $fixture.New } | Should -Throw '*ExternalChange*'
        $script:topologyEvents.Count | Should -Be 0
    }
    It 'allows a captured source child binding to change to its captured target package' {
        $oldChild=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$oldChild.PackageId='old-child';$oldChild.InfPath='oem4.inf';$oldChild.DriverVersion='2021'
        $fixture.Old.Devices+=@($oldChild);$fixture.Old.ClassFilters=$fixture.Classes
        $fixture.Old.DriverPackages+=@([pscustomobject]@{PackageId='old-child';ExportPath='fixture';InfRelative='old-child.inf';InfHash='old-child'})
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $script:topologyPresent=@($fixture.New.Devices[0],$oldChild)
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        (Resume-GHUBVirtualChildren $ctx $fixture.New).Status | Should -Be PendingReboot
        $script:topologyEvents | Should -Contain ('bind:'+$oldChild.InstanceId)
    }
    It 'keeps a recreated source child owned through its verified parent during the parent rebind' {
        $fixture.Old.Devices+=@($fixture.Child);$fixture.Old.ClassFilters=$fixture.Classes
        $fixture.Old.DriverPackages+=@($fixture.New.DriverPackages[1])
        $recreated=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$recreated.InstanceId='LGHUBDEVICE\VID_046D&PID_C232\recreated';$recreated.ContainerId='22222222-2222-2222-2222-222222222222'
        $script:topologyPresent=@($fixture.Old.Devices[0],$recreated)
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$script:topologyPresent;AllDevices=$script:topologyPresent;ClassFilters=$fixture.Classes}
        (Invoke-DriverPlan $ctx $plan).Status | Should -Be PendingReboot
    }
    It 'refuses to erase a foreign child filter while applying the captured target binding' {
        $plan=New-DriverPlan $fixture.Old $fixture.New @{Devices=$fixture.Old.Devices;AllDevices=$fixture.Old.Devices;ClassFilters=$fixture.Classes}
        Save-GHUBDriverPlan $ctx $plan
        $otherFilter=$fixture.Child|ConvertTo-Json -Depth 12|ConvertFrom-Json;$otherFilter.UpperFilters=@('foreign-filter')
        $script:topologyPresent=@($fixture.New.Devices[0],$otherFilter)
        Mock Test-GHUBDeviceBinding -ModuleName Drivers {param($Expected,$Actual,$Packages) [pscustomobject]@{Passed=($Expected.Service -eq 'logi_joy_bus_enum')} }
        Mock Set-GHUBDriverDeviceFilters -ModuleName Drivers {}
        { Resume-GHUBVirtualChildren $ctx $fixture.New } | Should -Throw '*ExternalChange*'
        $script:topologyEvents.Count | Should -Be 0
    }
}
