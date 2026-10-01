Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Inventory.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Storage.psm1') -DisableNameChecking

function Merge-ManagedFilters { param([string[]]$Current,[string[]]$SourceManaged,[string[]]$TargetManaged)
    foreach ($name in @($SourceManaged)+@($TargetManaged)) { if ($name -notmatch '^logi_joy_|^logi_lamparray$|^lghub') { Throw-SwitchError SharedDependency "Unclassified filter: $name" } }
    $result=[Collections.Generic.List[string]]::new(); $inserted=$false
    foreach ($name in $Current) {
        if ($name -in $SourceManaged) {
            if (-not $inserted) { foreach ($target in $TargetManaged) { $result.Add($target) }; $inserted=$true }
        } elseif ($name -notin $TargetManaged) { $result.Add($name) }
    }
    if (-not $inserted) { foreach ($target in $TargetManaged) { $result.Add($target) } }
    return $result.ToArray()
}
function Test-GHUBVirtualChild { param($Device,$Parent)
    return ((Get-ObjectValue $Device InstanceId '') -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $Device Service '') -eq 'logi_joy_vir_hid' -and
        (Get-ObjectValue $Device ParentInstanceId '') -ieq $Parent.InstanceId -and @($Parent.HardwareIds) -contains 'root\LGHUBVirtualBus' -and
        @($Device.HardwareIds | Where-Object {$_ -like 'LGHUBDevice\*'}).Count -gt 0)
}
function Get-GHUBInfModels { param([string]$Path)
    Initialize-NativeLibrary
    @([GHubSwitcher.DeviceApi]::ReadInfSection($Path,'Standard.NTamd64'))
}
function Get-GHUBSiblingSourceIdentity { param($Want,[object[]]$SourceChildren,[object[]]$Packages)
    # Windows may select the newer installed HID package for a child which only
    # the old bus creates. Prove the exact model using the captured source INF.
    $matches=@(foreach($sibling in $SourceChildren){
        if($sibling.ParentInstanceId -ine $Want.ParentInstanceId -or $sibling.ClassGuid -ine $Want.ClassGuid -or $sibling.Service -cne $Want.Service){continue}
        $package=@($Packages|Where-Object PackageId -CEQ $sibling.PackageId)
        if($package.Count -ne 1){continue}
        $inf=Assert-NoReparsePoint (Join-Path $package[0].ExportPath $package[0].InfRelative)
        if((Get-FileHash -LiteralPath $inf).Hash.ToLowerInvariant() -cne $package[0].InfHash){Throw-SwitchError BackupInvalid 'Source sibling INF changed.'}
        $models=@(Get-GHUBInfModels $inf|Where-Object {@($_.Values).Count -eq 2 -and $_.Values[0] -ceq $sibling.InfSection -and $_.Values[1] -iin $Want.HardwareIds})
        if($models.Count -ne 1){continue}
        $identity=$sibling|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $identity.InstanceId=$Want.InstanceId;$identity.HardwareIds=@($Want.HardwareIds)
        $identity|Add-Member -NotePropertyName EvidenceOrigin -NotePropertyValue 'VerifiedSourceInfModel' -Force
        $identity
    })
    $unique=@($matches|Group-Object PackageId|ForEach-Object {$_.Group[0]})
    if($unique.Count -gt 1){Throw-SwitchError DeviceAmbiguous 'More than one source package supports the deferred child.'}
    if($unique.Count -eq 1){return $unique[0]}
}
function Get-GHUBCommonBusParents { param($Source,$Target,$Present)
    foreach ($want in @($Target.Devices | Where-Object { $_.HardwareIds -contains 'root\LGHUBVirtualBus' -and $_.Service -eq 'logi_joy_bus_enum' })) {
        $before=@($Source.Devices | Where-Object { $_.HardwareIds -contains 'root\LGHUBVirtualBus' -and $_.InstanceId -ieq $want.InstanceId -and $_.Service -eq 'logi_joy_bus_enum' })
        if ($before.Count -ne 1) { continue }
        $actual=Resolve-ManagedDevice $before[0] @($Present)
        if ($actual.Service -ne 'logi_joy_bus_enum') { Throw-SwitchError SharedDependency 'The captured G HUB parent is no longer bound to its bus service.' }
        [pscustomobject]@{Source=$before[0];Target=$want;Actual=$actual}
    }
}
function Resolve-GHUBVirtualChild { param($Identity,$Parent,[object[]]$Present,[switch]$AllowMissing,[switch]$AllowUnbound)
    if (-not (Test-GHUBVirtualChild $Identity $Parent)) { Throw-SwitchError SharedDependency 'Not a captured child of the managed G HUB virtual bus.' }
    $actualParent=Resolve-ManagedDevice $Parent $Present
    $matches=@($Present | Where-Object {
        $candidate=$_
        $candidate.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $candidate ParentInstanceId '') -ieq $actualParent.InstanceId -and
        @($candidate.HardwareIds | Where-Object {$_ -in $Identity.HardwareIds}).Count -gt 0 -and
        ($candidate.ClassGuid -ieq $Identity.ClassGuid -or ($AllowUnbound -and -not $candidate.Service -and -not $candidate.InfPath))
    })
    if ($matches.Count -gt 1) { Throw-SwitchError DeviceAmbiguous 'More than one virtual child matches the recorded hardware and parent.' }
    if (-not $matches.Count) { if ($AllowMissing) { return $null }; Throw-SwitchError DeviceMissing 'The captured virtual child has not been enumerated by the target bus.' }
    return $matches[0]
}
function Assert-GHUBDriverExclusive { param($Actual,[string[]]$Owned,[object[]]$AllDevices)
    $foreign=@($AllDevices | Where-Object { $_.InstanceId -notin $Owned -and (($_.InfPath -and $_.InfPath -ieq $Actual.InfPath) -or ($_.Service -and $_.Service -eq $Actual.Service)) })
    if ($foreign.Count) { Throw-SwitchError SharedDependency 'Driver package or service is also used by an unmanaged device.' }
}
function Get-GHUBDriverManifestFingerprint { param($Manifest)
    Get-TextHash ([pscustomobject][ordered]@{Slot=$Manifest.Slot;OwnerSid=(Get-ObjectValue $Manifest OwnerSid '');ProductVersion=(Get-ObjectValue $Manifest ProductVersion '');Devices=$Manifest.Devices;DriverPackages=$Manifest.DriverPackages;KernelServices=$Manifest.KernelServices;ClassFilters=(Get-ObjectValue $Manifest ClassFilters $null)} | ConvertTo-Json -Depth 60 -Compress)
}
function Assert-GHUBDriverClassState { param($Expected,[object[]]$Actual)
    try {
        if (@(Compare-ClassFilters $Expected $Expected $Actual | Where-Object {-not $_.Passed}).Count) { throw 'Captured class filters differ from the current machine.' }
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function Assert-GHUBDriverSource { param($Source,[object[]]$Present,[object[]]$ClassFilters)
    try {
        if ($null -eq $Source -or -not $Source.PSObject.Properties['Devices'] -or -not $Source.PSObject.Properties['DriverPackages']) { throw 'Captured source driver evidence is missing.' }
        Assert-GHUBDriverClassState $Source $ClassFilters
        foreach ($expected in @($Source.Devices)) {
            $parent=@($Source.Devices | Where-Object {Test-GHUBVirtualChild $expected $_})
            $actual=if($parent.Count -eq 1){Resolve-GHUBVirtualChild $expected $parent[0] $Present}else{Resolve-ManagedDevice $expected $Present}
            if (-not (Test-GHUBDeviceBinding $expected $actual @($Source.DriverPackages)).Passed) { throw "Source driver binding changed: $($expected.InstanceId)" }
        }
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function Assert-GHUBDriverPlanSource { param($Plan)
    try {
        $source=Get-ObjectValue $Plan SourceEvidence $null
        if ($null -eq $source) { throw 'The driver plan has no captured source evidence.' }
        if (-not @($source.Devices).Count -and -not @($source.ClassFilters).Count) { return }
        $present=@(Get-NativeDevices)
        Assert-GHUBRollbackUnboundChildren $Plan $present
        Assert-GHUBDriverSource $source $present @(Get-ClassFilterInventory)
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function Assert-GHUBRollbackUnboundChildren { param($Plan,[object[]]$Present,[string]$ParentInstanceId='')
    try {
        foreach ($pending in @(Get-ObjectValue $Plan RollbackUnboundChildren @())) {
            if ($ParentInstanceId -and $pending.ParentIdentity.InstanceId -ine $ParentInstanceId) { continue }
            Assert-GHUBDriverClassState $pending.ClassEvidence @(Get-ClassFilterInventory)
            $parent=Resolve-ManagedDevice $pending.ParentIdentity $Present
            if (-not (Test-GHUBDeviceBinding $pending.ParentIdentity $parent @($Plan.SourceEvidence.DriverPackages)).Passed) { throw 'The rollback parent no longer has its captured binding.' }
            $child=Resolve-GHUBVirtualChild $pending.DeviceIdentity $pending.ParentIdentity $Present -AllowUnbound
            if ($child.InstanceId -ine $pending.InstanceId -or $child.Service -or $child.InfPath -or @($child.UpperFilters).Count -or @($child.LowerFilters).Count -or ($child.ClassGuid -and $child.ClassGuid -ine $pending.DeviceIdentity.ClassGuid)) { throw 'The rollback child no longer has the verified clean unbound state.' }
            $children=@($Present | Where-Object {$_.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $_ ParentInstanceId '') -ieq $parent.InstanceId} | ForEach-Object InstanceId | Sort-Object)
            if (($children -join "`0") -ine (@($pending.ExpectedChildInstanceIds | Sort-Object) -join "`0")) { throw 'The rollback parent child set changed after planning.' }
        }
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function New-GHUBRollbackDriverPlan { param($Context,$OriginalSource,$OriginalTarget,$Inventory)
    try {
        if ($null -eq $OriginalTarget -or $OriginalSource.OwnerSid -ne $Context.OwnerSid -or $OriginalTarget.OwnerSid -ne $Context.OwnerSid) { throw 'Rollback requires both captured environment identities for this owner.' }
        $state=Read-SwitchState $Context;$journal=@(Read-ValidJournal $Context $state.TransactionId)
        $records=@($journal | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'driver-plan' -and $_.After.SourceSlot -eq $OriginalSource.Slot -and $_.After.TargetSlot -eq $OriginalTarget.Slot})
        if ($records.Count -ne 1) { throw 'Rollback requires one original forward driver plan.' }
        $forward=$records[0].After
        $capturedSource=[pscustomobject]@{Devices=$OriginalSource.Devices;DriverPackages=$OriginalSource.DriverPackages;ClassFilters=$OriginalSource.ClassFilters}
        if ($forward.OwnerSid -ne $Context.OwnerSid -or $forward.TargetFingerprint -cne (Get-GHUBDriverManifestFingerprint $OriginalTarget) -or ($forward.SourceEvidence | ConvertTo-Json -Depth 60 -Compress) -cne ($capturedSource | ConvertTo-Json -Depth 60 -Compress)) { throw 'The rollback captures differ from the original forward driver plan.' }
        $present=@($Inventory.AllDevices);$classes=@(Get-ObjectValue $Inventory ClassFilters @())
        $parents=@(Get-GHUBCommonBusParents $OriginalSource $OriginalTarget $present)
        $captures=@($OriginalSource.Devices)+@($OriginalTarget.Devices)
        $captures+=@($forward.DeferredChildren | ForEach-Object SourceIdentity | Where-Object {$_ -and (Get-ObjectValue $_ EvidenceOrigin '') -ceq 'VerifiedSourceInfModel'})
        $children=@($captures | Where-Object {$child=$_;@($parents | Where-Object {(Test-GHUBVirtualChild $child $_.Source) -or (Test-GHUBVirtualChild $child $_.Target)}).Count -eq 1})
        $childClasses=@($children | ForEach-Object ClassGuid | Sort-Object -Unique)
        if (@(Compare-ClassFilters $OriginalSource $OriginalTarget $classes -AllowedOneSidedClasses $childClasses | Where-Object {-not $_.Passed}).Count) { throw 'Captured global class filters changed before rollback.' }
        $packages=@(@($OriginalSource.DriverPackages)+@($OriginalTarget.DriverPackages) | Group-Object PackageId | ForEach-Object {$_.Group[0]})
        $devices=@();$resolved=@();$unbound=@()
        foreach ($group in @($captures | Where-Object {$_.InstanceId -notlike 'LGHUBDEVICE\*'} | Group-Object InstanceId)) {
            $actual=Resolve-ManagedDevice $group.Group[0] $present
            $known=@($group.Group | Where-Object {(Test-GHUBDeviceBinding $_ $actual $packages).Passed})
            if (-not $known.Count) { throw ('Rollback encountered an uncaptured driver binding: '+$actual.InstanceId) }
            $devices+=$known[0];$resolved+=$actual.InstanceId
        }
        foreach ($group in @($children | Group-Object { $_.ParentInstanceId+'|'+(($_.HardwareIds | Sort-Object) -join '|') })) {
            $identity=$group.Group[0];$parent=@($parents | Where-Object {$_.Source.InstanceId -ieq $identity.ParentInstanceId})
            $actual=Resolve-GHUBVirtualChild $identity $parent[0].Source $present -AllowMissing -AllowUnbound
            if (-not $actual) { continue }
            $resolved+=$actual.InstanceId
            $known=@($group.Group | Where-Object {(Test-GHUBDeviceBinding $_ $actual $packages).Passed})
            if ($known.Count) { $devices+=$known[0];continue }
            $pending=@($forward.DeferredChildren | Where-Object {$_.ParentIdentity.InstanceId -ieq $identity.ParentInstanceId -and @($_.DeviceIdentity.HardwareIds | Where-Object {$_ -in $identity.HardwareIds}).Count -gt 0})
            $parentAction=@($forward.DeviceActions | Where-Object {$_.DeviceIdentity.InstanceId -ieq $identity.ParentInstanceId})
            $attempts=@($journal | Where-Object {$_.Kind -eq 'Intent' -and $_.Sequence -gt $records[0].Sequence -and $_.StepId -like 'driver-*' -and (Get-ObjectValue (Get-ObjectValue $_ After $null) InstanceId '') -ieq $parent[0].Actual.InstanceId})
            $existedBefore=@($OriginalSource.Devices | Where-Object {$_.ParentInstanceId -ieq $identity.ParentInstanceId -and @($_.HardwareIds|Where-Object {$_ -in $identity.HardwareIds}).Count -gt 0}).Count -gt 0
            if ($actual.Service -or $actual.InfPath -or @($actual.UpperFilters).Count -or @($actual.LowerFilters).Count -or ($actual.ClassGuid -and $actual.ClassGuid -ine $identity.ClassGuid) -or $pending.Count -ne 1 -or $existedBefore -or $parentAction.Count -ne 1 -or -not $attempts.Count) { throw 'An unbound child is not proven to be the new deferred child of this forward transaction.' }
            if (-not (Test-GHUBDeviceBinding $parent[0].Target $parent[0].Actual @($OriginalTarget.DriverPackages)).Passed) { throw 'Unbound-child rollback requires the captured target parent binding.' }
            if ($parentAction[0].SourcePackageId -ceq $parentAction[0].TargetPackageId -or @($attempts | Where-Object {$_.After.SourcePackageId -ceq $parentAction[0].SourcePackageId -and $_.After.TargetPackageId -ceq $parentAction[0].TargetPackageId -and $_.After.DeviceIdentity.InstanceId -ieq $parentAction[0].DeviceIdentity.InstanceId}).Count -ne 1) { throw 'The forward parent binding attempt is missing or ambiguous.' }
            $unbound+=[pscustomobject]@{DeviceIdentity=$pending[0].DeviceIdentity;ParentIdentity=$parent[0].Target;InstanceId=$actual.InstanceId;ForwardPlanId=$forward.PlanId;ClassEvidence=[pscustomobject]@{ClassFilters=@($OriginalTarget.ClassFilters | Where-Object ClassGuid -EQ $identity.ClassGuid)};ExpectedChildInstanceIds=@($present | Where-Object {$_.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $_ ParentInstanceId '') -ieq $parent[0].Actual.InstanceId} | ForEach-Object InstanceId)}
        }
        $unrecognized=@($Inventory.Devices | Where-Object {$_.InstanceId -notin $resolved})
        $unrecognized+=@($present | Where-Object {$_.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $_ ParentInstanceId '') -in @($parents | ForEach-Object {$_.Actual.InstanceId}) -and $_.InstanceId -notin $resolved})
        if ($unrecognized.Count) { throw 'Rollback encountered an uncaptured or misplaced managed device.' }
        foreach ($kernel in @($Inventory.KernelServices)) {
            if (Get-ObjectValue $kernel AppLocal $false) { continue }
            $known=@(@($OriginalSource.KernelServices)+@($OriginalTarget.KernelServices) | Where-Object {$_.Name -eq $kernel.Name -and $_.Path -ieq $kernel.Path -and $_.Sha256 -ceq $kernel.Sha256})
            if (-not $known.Count) { throw 'Rollback encountered an uncaptured kernel driver binary.' }
        }
        $mixed=[pscustomobject]@{Slot=$OriginalTarget.Slot;OwnerSid=$Context.OwnerSid;ProductVersion=$OriginalTarget.ProductVersion;Devices=$devices;DriverPackages=$packages;KernelServices=@($Inventory.KernelServices);ClassFilters=@($classes | Where-Object {$_.ClassGuid -in @($devices | ForEach-Object ClassGuid)})}
        # The clean unbound child is removal evidence only, never an owned bound source or an INF to export.
        $excluded=@($unbound | ForEach-Object InstanceId)
        $planningInventory=[pscustomobject]@{Devices=@($Inventory.Devices | Where-Object {$_.InstanceId -notin $excluded});AllDevices=@($present | Where-Object {$_.InstanceId -notin $excluded});ClassFilters=$classes}
        $plan=New-DriverPlan $mixed $OriginalSource $planningInventory
        $plan | Add-Member -NotePropertyName RollbackUnboundChildren -NotePropertyValue $unbound
        $plan.RemovedChildren=@($plan.RemovedChildren)+@($unbound | ForEach-Object DeviceIdentity)
        return $plan
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function New-DriverPlan { param($Source,$Target,$Inventory)
    Assert-GHUBDriverSource $Source @($Inventory.Devices) @(Get-ObjectValue $Inventory ClassFilters @())
    $actions=@(); $filters=@(); $reasons=@(); $deferred=@(); $removed=@(); $topologyChanged=$false
    $parents=@(Get-GHUBCommonBusParents $Source $Target @($Inventory.Devices))
    $sourceChildren=@();$targetChildren=@()
    foreach ($parent in $parents) {
        $sourceChildren+=@($Source.Devices | Where-Object {Test-GHUBVirtualChild $_ $parent.Source})
        $targetChildren+=@($Target.Devices | Where-Object {Test-GHUBVirtualChild $_ $parent.Target})
    }
    foreach ($pair in @(@{Manifest=$Source;Children=$sourceChildren},@{Manifest=$Target;Children=$targetChildren})) {
        foreach ($child in $pair.Children) {
            if (@(Get-ObjectValue $pair.Manifest ClassFilters @() | Where-Object ClassGuid -EQ $child.ClassGuid).Count -ne 1) { Throw-SwitchError SharedDependency 'A virtual child has no unique captured class filter evidence.' }
        }
    }
    foreach ($device in @($Source.Devices)+@($Target.Devices)) {
        if ($device.InstanceId -like 'LGHUBDEVICE\*' -and @(@($sourceChildren)+@($targetChildren) | Where-Object { $_.InstanceId -ieq $device.InstanceId -and $_.ParentInstanceId -ieq $device.ParentInstanceId }).Count -eq 0) { Throw-SwitchError SharedDependency 'Virtual device ownership is not proven by a common captured parent.' }
    }
    foreach ($parent in $parents) {
        foreach ($actualChild in @($Inventory.AllDevices | Where-Object { $_.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $_ ParentInstanceId '') -ieq $parent.Actual.InstanceId })) {
            if (@(@($sourceChildren)+@($targetChildren) | Where-Object { $known=$_; @($actualChild.HardwareIds | Where-Object {$_ -in $known.HardwareIds}).Count -gt 0 }).Count -eq 0) { Throw-SwitchError SharedDependency 'An uncaptured virtual child uses the managed parent.' }
        }
    }
    $childClasses=@(@($sourceChildren)+@($targetChildren) | ForEach-Object ClassGuid | Sort-Object -Unique)
    $classChecks=@(Compare-ClassFilters $Source $Target @(Get-ObjectValue $Inventory ClassFilters @()) -AllowedOneSidedClasses $childClasses)
    if(@($classChecks|Where-Object {-not $_.Passed}).Count){Throw-SwitchError SharedDependency 'Class filter evidence is missing or changed; shared classes are never rewritten automatically.'}
    $owned=@()
    foreach ($previous in $Source.Devices) {
        $parent=@($parents | Where-Object {Test-GHUBVirtualChild $previous $_.Source})
        if ($parent.Count -eq 1) { $actual=Resolve-GHUBVirtualChild $previous $parent[0].Source @($Inventory.Devices) -AllowMissing }
        else { $actual=Resolve-ManagedDevice $previous @($Inventory.Devices) }
        if ($actual) { $owned+=$actual.InstanceId }
    }
    foreach ($want in $Target.Devices) {
        $parent=@($parents | Where-Object {Test-GHUBVirtualChild $want $_.Target})
        if ($parent.Count -eq 1) {
            $previous=@($sourceChildren | Where-Object { $_.ParentInstanceId -ieq $want.ParentInstanceId -and @($_.HardwareIds | Where-Object {$_ -in $want.HardwareIds}).Count -gt 0 })
            if ($previous.Count -gt 1) { Throw-SwitchError DeviceAmbiguous 'Ambiguous captured virtual child.' }
            if (-not $previous.Count -and $parent[0].Source.PackageId -ceq $parent[0].Target.PackageId) { Throw-SwitchError SharedDependency 'A virtual topology change requires the captured parent package to change.' }
            if (-not $previous.Count) { $previous=@(Get-GHUBSiblingSourceIdentity $want $sourceChildren @($Source.DriverPackages)) }
            $package=@($Target.DriverPackages | Where-Object PackageId -CEQ $want.PackageId)
            if ($package.Count -ne 1) { Throw-SwitchError InvalidManifest 'Missing or ambiguous virtual child package.' }
            $actual=Resolve-GHUBVirtualChild $want $parent[0].Source @($Inventory.Devices) -AllowMissing -AllowUnbound
            if ($actual) { $owned+=$actual.InstanceId; Assert-GHUBDriverExclusive $actual $owned @($Inventory.AllDevices) }
            $fromPackage=if($previous.Count){$previous[0].PackageId}else{''}
            $deferred+=[pscustomobject]@{DeviceIdentity=$want;ParentIdentity=$parent[0].Target;SourceIdentity=$(if($previous.Count){$previous[0]}else{$null});SourcePackageId=$fromPackage;TargetPackageId=$want.PackageId;Package=$package[0];TargetSection=$want.InfSection;ExpectedService=$want.Service}
            if (-not $previous.Count -or $fromPackage -cne $want.PackageId -or (@($previous[0].UpperFilters) -join "`0") -cne (@($want.UpperFilters) -join "`0") -or (@($previous[0].LowerFilters) -join "`0") -cne (@($want.LowerFilters) -join "`0")) { $topologyChanged=$true; $reasons+="Virtual child change: $($want.InstanceId)" }
            continue
        }
        $actual=Resolve-ManagedDevice $want @($Inventory.Devices)
        $previous=Resolve-ManagedDevice $actual @($Source.Devices)
        $sourcePackage=Get-ObjectValue $previous PackageId ''
        $targetPackage=Get-ObjectValue $want PackageId ''
        if (-not $sourcePackage -or -not $targetPackage) { Throw-SwitchError InvalidManifest 'Missing driver package identity.' }
        $filterChange=(@($previous.UpperFilters) -join "`0") -cne (@($want.UpperFilters) -join "`0") -or (@($previous.LowerFilters) -join "`0") -cne (@($want.LowerFilters) -join "`0")
        if ($sourcePackage -cne $targetPackage -or $filterChange) {
            Assert-GHUBDriverExclusive $actual $owned @($Inventory.AllDevices)
        }
        if ($sourcePackage -cne $targetPackage) {
            $package=@($Target.DriverPackages | Where-Object PackageId -CEQ $targetPackage)
            if ($package.Count -ne 1) { Throw-SwitchError InvalidManifest 'Missing or ambiguous target package.' }
            $actions+=[pscustomobject]@{DeviceIdentity=$want;SourceIdentity=$previous;InstanceId=$actual.InstanceId;SourcePackageId=$sourcePackage;TargetPackageId=$targetPackage;Package=$package[0];TargetSection=$want.InfSection;ExpectedService=$want.Service}
            $reasons+="Package change: $($actual.InstanceId)"
        }
        if ($filterChange) {
            $sourceUpper=@($previous.UpperFilters | Where-Object { $_ -match '^logi_joy_|^logi_lamparray$|^lghub' })
            $sourceLower=@($previous.LowerFilters | Where-Object { $_ -match '^logi_joy_|^logi_lamparray$|^lghub' })
            $targetUpper=@($want.UpperFilters | Where-Object { $_ -match '^logi_joy_|^logi_lamparray$|^lghub' })
            $targetLower=@($want.LowerFilters | Where-Object { $_ -match '^logi_joy_|^logi_lamparray$|^lghub' })
            $upper=@(Merge-ManagedFilters @($actual.UpperFilters) $sourceUpper $targetUpper)
            $lower=@(Merge-ManagedFilters @($actual.LowerFilters) $sourceLower $targetLower)
            $filters+=[pscustomobject]@{DeviceIdentity=$want;SourceIdentity=$previous;BeforeUpper=@($actual.UpperFilters);BeforeLower=@($actual.LowerFilters);Upper=$upper;Lower=$lower}
            $reasons+="Filter change: $($actual.InstanceId)"
        }
    }
    $extra=@($Source.Devices | Where-Object { $s=$_; @($Target.Devices | Where-Object { $_.HardwareIds | Where-Object { $_ -in $s.HardwareIds } }).Count -eq 0 })
    foreach ($device in $extra) {
        $parent=@($parents | Where-Object {Test-GHUBVirtualChild $device $_.Source})
        if ($parent.Count -ne 1 -or $parent[0].Source.PackageId -ceq $parent[0].Target.PackageId) { Throw-SwitchError SharedDependency 'Source-only device stacks require an explicit vendor maintenance step.' }
        $actual=Resolve-GHUBVirtualChild $device $parent[0].Source @($Inventory.Devices) -AllowMissing
        if ($actual) { Assert-GHUBDriverExclusive $actual $owned @($Inventory.AllDevices) }
        $removed+=$device;$topologyChanged=$true;$reasons+="Virtual child removal: $($device.InstanceId)"
    }
    $aux=@()
    foreach($name in @(@($Source.KernelServices)+@($Target.KernelServices)|ForEach-Object Name|Sort-Object -Unique)){
        $from=@($Source.KernelServices|Where-Object Name -EQ $name);$to=@($Target.KernelServices|Where-Object Name -EQ $name)
        if (@(@($from)+@($to) | Where-Object {Get-ObjectValue $_ AppLocal $false}).Count) { continue }
        if($from.Count -eq 1 -and $to.Count -eq 1 -and $from[0].Sha256 -ceq $to[0].Sha256 -and $from[0].StartType -eq $to[0].StartType){continue}
        if($name -notmatch '^logi_joy_|^logi_lamparray$|^lghub'){Throw-SwitchError SharedDependency 'Unowned kernel component cannot be changed.'}
        $foreign=@($Inventory.AllDevices|Where-Object {$_.InstanceId -notin $owned -and ($_.Service -eq $name -or $name -in $_.UpperFilters -or $name -in $_.LowerFilters)})
        $sharedClass=@(Get-ObjectValue $Inventory ClassFilters @()|Where-Object {$name -in $_.UpperFilters -or $name -in $_.LowerFilters})
        if($foreign.Count -or $sharedClass.Count){Throw-SwitchError SharedDependency 'Auxiliary driver is used outside a managed device stack.'}
        $expected=if($to.Count){$to[0]}else{$from[0]}
        $start=if($to.Count){$expected.StartType}else{4}
        $aux+=[pscustomobject]@{Name=$name;StartType=$start;Expected=$expected;Required=($to.Count -gt 0)}
        $reasons+="Kernel component change: $name"
    }
    $restart=$topologyChanged -or ($actions.Count+$filters.Count+$aux.Count -gt 0)
    $sourceEvidence=[pscustomobject]@{Devices=$Source.Devices;DriverPackages=$Source.DriverPackages;ClassFilters=$Source.ClassFilters} | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    [pscustomobject]@{PlanId=[guid]::NewGuid().ToString('N');SourceSlot=$Source.Slot;SourceEvidence=$sourceEvidence;TargetSlot=$Target.Slot;TargetVersion=(Get-ObjectValue $Target ProductVersion '');TargetFingerprint=(Get-GHUBDriverManifestFingerprint $Target);OwnerSid=(Get-ObjectValue $Target OwnerSid '');DeviceActions=@($actions | Sort-Object @{Expression={if($_.DeviceIdentity.InstanceId -like 'ROOT\*'){0}else{1}}});FilterActions=$filters;AuxiliaryActions=$aux;DeferredChildren=$deferred;RemovedChildren=$removed;BusParents=$parents;PackagesToStage=@(if($restart){$Target.DriverPackages});RequiresRestart=$restart;Reasons=$reasons}
}
function Compare-ClassFilters {param($Source,$Target,$Actual,[string[]]$AllowedOneSidedClasses=@())
    foreach($manifest in @($Source,$Target)){
        if(-not $manifest.PSObject.Properties['ClassFilters']){[pscustomobject]@{Passed=$false;Device='ClassFilters';Failures=@('MissingClassEvidence')};return}
    }
    foreach($id in @(@($Source.ClassFilters)+@($Target.ClassFilters)|ForEach-Object ClassGuid|Sort-Object -Unique)){
        $before=@($Source.ClassFilters|Where-Object ClassGuid -EQ $id);$want=@($Target.ClassFilters|Where-Object ClassGuid -EQ $id);$now=@($Actual|Where-Object ClassGuid -EQ $id)
        $passed=$before.Count -eq 1 -and $want.Count -eq 1 -and $now.Count -eq 1
        if($passed){foreach($key in @('UpperFilters','LowerFilters')){if(($before[0].$key -join "`0") -cne ($want[0].$key -join "`0") -or ($now[0].$key -join "`0") -cne ($want[0].$key -join "`0")){$passed=$false}}}
        elseif ($id -in $AllowedOneSidedClasses -and $before.Count+$want.Count -eq 1 -and $now.Count -eq 1) {
            $record=(@($before)+@($want))[0];$passed=$true
            foreach($key in @('UpperFilters','LowerFilters')){if(($record.$key -join "`0") -cne ($now[0].$key -join "`0")){$passed=$false}}
        }
        [pscustomobject]@{Passed=$passed;Device=$id;Failures=@($(if(-not $passed){'ClassFilterMismatch'}))}
    }
}
function Compare-KernelComponents {param($Source,$Target,$Runtime,$ClassFilters)
    Compare-ClassFilters $Target $Target $ClassFilters
    $names=@(@($Source.KernelServices)+@($Target.KernelServices)+@($Runtime)|ForEach-Object Name|Sort-Object -Unique)
    foreach($name in $names){
        $want=@($Target.KernelServices|Where-Object Name -EQ $name);$now=@($Runtime|Where-Object Name -EQ $name)
        $passed=$true
        if($want.Count -eq 1){
            $passed=$now.Count -eq 1
            if($passed){foreach($key in @('Path','Sha256','State','StartType')){if((Get-ObjectValue $now[0] $key $null) -cne (Get-ObjectValue $want[0] $key $null)){$passed=$false}};if(-not $want[0].Sha256){$passed=$false}}
        }elseif($now.Count){$passed=$now.Count -eq 1 -and $now[0].State -eq 'Stopped' -and $now[0].StartType -eq 4}
        [pscustomobject]@{Passed=$passed;Device=$name;Failures=@($(if(-not $passed){'AuxiliaryDriverMismatch'}))}
    }
}
function Compare-DriverDevice { param($Expected,$Actual)
    $fail=@()
    foreach ($property in @('PackageId','Service','DriverVersion')) { if ((Get-ObjectValue $Expected $property '') -cne (Get-ObjectValue $Actual $property '')) { $fail+=$property } }
    foreach ($property in @('UpperFilters','LowerFilters')) { if ((@(Get-ObjectValue $Expected $property @()) -join "`0") -cne (@(Get-ObjectValue $Actual $property @()) -join "`0")) { $fail+=$property } }
    if ((Get-ObjectValue $Actual ProblemCode 1) -ne 0) { $fail+='ProblemCode' }
    [pscustomobject]@{Passed=($fail.Count -eq 0);Failures=$fail;Device=$Actual.InstanceId}
}
function Export-ManagedDrivers { param($Context,$Manifest)
    Assert-Administrator
    $packages=@()
    foreach ($inf in @($Manifest.Devices | ForEach-Object InfPath | Sort-Object -Unique)) {
        if ($inf -notmatch '^oem\d+\.inf$') { Throw-SwitchError SharedDependency "Cannot export an inbox or unidentified driver: $inf" }
        $dest=Join-Path $Context.Root ('DriverPackages/'+[guid]::NewGuid().ToString('N'))
        $null=Assert-NoReparsePoint $dest; [IO.Directory]::CreateDirectory($dest) | Out-Null
        $output=& "$env:WINDIR\System32\pnputil.exe" /export-driver $inf $dest 2>&1
        if ($LASTEXITCODE -ne 0) { Throw-SwitchError BackupInvalid "Driver export failed: $inf" }
        $files=@(Get-TreeFiles $dest | Where-Object { -not $_.IsDirectory })
        $infs=@($files | Where-Object { $_.Relative -like '*.inf' }); $cats=@($files | Where-Object { $_.Relative -like '*.cat' })
        if ($infs.Count -ne 1 -or $cats.Count -eq 0) { Throw-SwitchError BackupInvalid 'Expected one INF and a catalog in exported package.' }
        $hash=Get-TextHash (($files | Sort-Object Relative | ForEach-Object { $_.Relative+'|'+$_.Sha256 }) -join "`n")
        $infHash=(Get-FileHash -LiteralPath (Join-Path $dest $infs[0].Relative)).Hash.ToLowerInvariant()
        $package=[pscustomobject]@{PackageId=$hash;PublishedInfName=$inf;OriginalInfName=[IO.Path]::GetFileName($infs[0].Relative);InfRelative=$infs[0].Relative;InfHash=$infHash;ExportPath=$dest;Files=$files}
        $packages+=$package
        foreach ($device in @($Manifest.Devices | Where-Object InfPath -EQ $inf)) { $device | Add-Member -NotePropertyName PackageId -NotePropertyValue $hash -Force }
    }
    return $packages
}
function Assert-DriverPackage { param($Context,$Package)
    $path=Assert-NoReparsePoint $Package.ExportPath
    $prefix=(Join-Path $Context.Root 'DriverPackages').TrimEnd('\')+'\'
    if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Throw-SwitchError UnsafePath 'Driver package is outside protected storage.' }
    $actual=@(Get-TreeFiles $path | Where-Object { -not $_.IsDirectory })
    $hash=Get-TextHash (($actual | Sort-Object Relative | ForEach-Object { $_.Relative+'|'+$_.Sha256 }) -join "`n")
    if ($hash -cne $Package.PackageId) { Throw-SwitchError BackupInvalid 'Driver package contents changed.' }
}
function Save-GHUBDriverPlan { param($Context,$Plan)
    $state=Read-SwitchState $Context
    $records=@(Read-ValidJournal $Context $state.TransactionId | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'driver-plan'})
    $same=@($records | Where-Object {$_.After.PlanId -eq $Plan.PlanId})
    if ($same.Count -gt 1) { Throw-SwitchError RecoveryRequired 'Duplicate driver plan identity.' }
    if ($same.Count) {
        if (($same[0].After | ConvertTo-Json -Depth 60 -Compress) -cne ($Plan | ConvertTo-Json -Depth 60 -Compress)) { Throw-SwitchError RecoveryRequired 'The persisted driver plan was changed.' }
        return
    }
    if ($Plan.OwnerSid -ne $Context.OwnerSid) { Throw-SwitchError OwnerMismatch 'Driver plan belongs to another user.' }
    Add-JournalEntry $Context $state.TransactionId Checkpoint driver-plan @{Phase=$state.Phase;SourceSlot=$Plan.SourceSlot;TargetSlot=$Plan.TargetSlot} $Plan
}
function Get-DriverTransactionPlan { param($Context,$Manifest)
    $state=Read-SwitchState $Context
    if (-not $state.TransactionId) { return $null }
    $records=@(Read-ValidJournal $Context $state.TransactionId | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'driver-plan'})
    if (-not $records.Count) { return $null }
    $plan=$records[-1].After
    if ($plan.OwnerSid -ne $Context.OwnerSid) { Throw-SwitchError OwnerMismatch 'Driver plan belongs to another user.' }
    # A rollback must never reuse an earlier plan for the opposite direction.
    if ($plan.TargetSlot -ne $Manifest.Slot) { return $null }
    if ($plan.TargetFingerprint -cne (Get-GHUBDriverManifestFingerprint $Manifest)) { Throw-SwitchError RecoveryRequired 'Target driver manifest differs from the persisted plan.' }
    if (@($records | Where-Object {$_.After.PlanId -eq $plan.PlanId}).Count -ne 1) { Throw-SwitchError RecoveryRequired 'Duplicate driver plan identity.' }
    return $plan
}
function Stage-GHUBDriverPackage { param($Context,$Package)
    Assert-DriverPackage $Context $Package
    $published=[GHubSwitcher.DeviceApi]::StagePackage((Join-Path $Package.ExportPath $Package.InfRelative))
    if ((Get-FileHash -LiteralPath $published).Hash.ToLowerInvariant() -cne $Package.InfHash) { Throw-SwitchError DriverMismatch 'Staged INF identity mismatch.' }
    return $published
}
function Invoke-GHUBDriverBinding { param([string]$InstanceId,[string]$PublishedInf,[string]$Section)
    [GHubSwitcher.DeviceApi]::InstallExact($InstanceId,$PublishedInf,$Section)
}
function Set-GHUBDriverDeviceFilters { param([string]$InstanceId,[string[]]$Upper,[string[]]$Lower)
    [GHubSwitcher.DeviceApi]::SetDeviceFilters($InstanceId,$Upper,$Lower)
}
function Test-GHUBDeviceBinding { param($Expected,$Actual,[object[]]$Packages)
    if (-not $Actual.InfPath -or -not $Expected.PackageId) { return [pscustomobject]@{Passed=$false;Device=$Actual.InstanceId;Failures=@('MissingPackageIdentity')} }
    $hash=(Get-FileHash -LiteralPath (Join-Path $env:WINDIR ('INF/'+$Actual.InfPath))).Hash.ToLowerInvariant()
    $package=@($Packages | Where-Object InfHash -CEQ $hash)
    $copy=$Actual | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copy | Add-Member -NotePropertyName PackageId -NotePropertyValue $(if($package.Count -eq 1){$package[0].PackageId}else{'Unknown'}) -Force
    Compare-DriverDevice $Expected $copy
}
function Set-GHUBAuxiliaryAction { param($Context,$Action)
    $state=Read-SwitchState $Context
    $current=@(Get-KernelInventory @($Action.Name)|Where-Object Name -EQ $Action.Name)
    if(-not $current.Count -and -not $Action.Required){return}
    if($current.Count -ne 1 -or $current[0].Path -ine $Action.Expected.Path -or $current[0].Sha256 -cne $Action.Expected.Sha256){Throw-SwitchError DriverMismatch 'Auxiliary binary is missing or differs from the captured target; vendor INF must restore it.'}
    if ($current[0].StartType -eq $Action.StartType) { return }
    Add-JournalEntry $Context $state.TransactionId Intent ('auxiliary-'+$Action.Name) $current[0] $Action
    [GHubSwitcher.ServiceApi]::SetKernelStartMode($Action.Name,[uint32]$Action.StartType)
    Add-JournalEntry $Context $state.TransactionId Done ('auxiliary-'+$Action.Name) $current[0] $Action
}
function Invoke-DriverPlan { param($Context,$Plan)
    Assert-Administrator; Initialize-NativeLibrary
    $state=Read-SwitchState $Context
    Assert-GHUBDriverPlanSource $Plan
    foreach ($package in @(Get-ObjectValue $Plan PackagesToStage @())) { Assert-DriverPackage $Context $package }
    Save-GHUBDriverPlan $Context $Plan
    $staged=@{}
    foreach ($package in @(Get-ObjectValue $Plan PackagesToStage @())) {
        Add-JournalEntry $Context $state.TransactionId Intent ('driver-stage-'+$package.PackageId) $null $package
        $staged[$package.PackageId]=Stage-GHUBDriverPackage $Context $package
        Add-JournalEntry $Context $state.TransactionId Done ('driver-stage-'+$package.PackageId) $null $staged[$package.PackageId]
    }
    $completedBindings=@{}
    foreach ($action in $Plan.DeviceActions) {
        try {
            $present=@(Get-NativeDevices); $device=Resolve-ManagedDevice $action.DeviceIdentity $present
            Assert-GHUBRollbackUnboundChildren $Plan $present -ParentInstanceId $action.SourceIdentity.InstanceId
            Assert-GHUBDriverClassState $Plan.SourceEvidence @(Get-ClassFilterInventory)
            if (-not (Test-GHUBDeviceBinding $action.SourceIdentity $device @($Plan.SourceEvidence.DriverPackages)).Passed) { throw 'Source driver changed before native binding.' }
            $owned=@($Plan.SourceEvidence.Devices | ForEach-Object {
                $expected=$_;$parent=@($Plan.SourceEvidence.Devices | Where-Object {Test-GHUBVirtualChild $expected $_})
                $current=if($parent.Count -eq 1){Resolve-GHUBVirtualChild $expected $parent[0] $present -AllowMissing}else{Resolve-ManagedDevice $expected $present}
                if($current){$current.InstanceId}
            })
            Assert-GHUBDriverExclusive $device $owned $present
        } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
        Add-JournalEntry $Context $state.TransactionId Intent ('driver-'+$action.TargetPackageId) $device $action
        $published=$staged[$action.TargetPackageId]
        if (-not $published) { $published=Stage-GHUBDriverPackage $Context $action.Package }
        $result=Invoke-GHUBDriverBinding $device.InstanceId $published $action.TargetSection
        Add-JournalEntry $Context $state.TransactionId Done ('driver-'+$action.TargetPackageId) $device $result
        $completedBindings[$device.InstanceId]=$action
    }
    foreach ($action in $Plan.FilterActions) {
        try {
            $device=Resolve-ManagedDevice $action.DeviceIdentity @(Get-NativeDevices)
            Assert-GHUBDriverClassState $Plan.SourceEvidence @(Get-ClassFilterInventory)
            $allowed=(Test-GHUBDeviceBinding $action.SourceIdentity $device @($Plan.SourceEvidence.DriverPackages)).Passed
            if (-not $allowed -and $completedBindings.ContainsKey($device.InstanceId)) {
                $bound=$completedBindings[$device.InstanceId]
                $intermediate=$action.DeviceIdentity | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $intermediate.UpperFilters=@($action.SourceIdentity.UpperFilters);$intermediate.LowerFilters=@($action.SourceIdentity.LowerFilters)
                $allowed=(Test-GHUBDeviceBinding $action.DeviceIdentity $device @($bound.Package)).Passed -or (Test-GHUBDeviceBinding $intermediate $device @($bound.Package)).Passed
            }
            if (-not $allowed) { throw 'Device binding or filters changed before the captured filter update.' }
        } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
        Add-JournalEntry $Context $state.TransactionId Intent ('filters-'+(Get-TextHash $device.InstanceId)) $device $action
        Set-GHUBDriverDeviceFilters $device.InstanceId ([string[]]$action.Upper) ([string[]]$action.Lower)
        Add-JournalEntry $Context $state.TransactionId Done ('filters-'+(Get-TextHash $device.InstanceId)) $device $action
    }
    $childServices=@(Get-ObjectValue $Plan DeferredChildren @() | ForEach-Object ExpectedService)
    foreach($action in $Plan.AuxiliaryActions){
        if ($action.Required -and $action.Name -in $childServices) { continue }
        Set-GHUBAuxiliaryAction $Context $action
    }
    if ($Plan.RequiresRestart) { return (New-OperationResult PendingReboot RebootRequired 'Driver stack changed. Restart Windows before launching G HUB.' $Plan.Reasons) }
    New-OperationResult
}
function Get-GHUBVirtualChildBindingState { param($Plan,$Manifest,$Action,[object[]]$Present)
    try {
        if (-not $PSBoundParameters.ContainsKey('Present')) { $Present=@(Get-NativeDevices) }
        Assert-GHUBDriverClassState $Manifest @(Get-ClassFilterInventory)
        $parent=Resolve-ManagedDevice $Action.ParentIdentity $Present
        if (-not (Test-GHUBDeviceBinding $Action.ParentIdentity $parent @($Manifest.DriverPackages)).Passed) { throw 'Virtual child continuation requires the verified target parent driver.' }
        $device=Resolve-GHUBVirtualChild $Action.DeviceIdentity $Action.ParentIdentity $Present -AllowMissing -AllowUnbound
        if (-not $device) { return $null }
        $owned=@($Plan.BusParents | ForEach-Object { (Resolve-ManagedDevice $_.Target $Present).InstanceId })
        foreach ($known in $Plan.DeferredChildren) { $found=Resolve-GHUBVirtualChild $known.DeviceIdentity $known.ParentIdentity $Present -AllowMissing -AllowUnbound;if($found){$owned+=$found.InstanceId} }
        Assert-GHUBDriverExclusive $device $owned $Present
        foreach ($field in @('UpperFilters','LowerFilters')) {
            $foreignActual=@($device.$field | Where-Object {$_ -notmatch '^logi_joy_|^logi_lamparray$|^lghub'})
            $foreignTarget=@($Action.DeviceIdentity.$field | Where-Object {$_ -notmatch '^logi_joy_|^logi_lamparray$|^lghub'})
            if (($foreignActual -join "`0") -cne ($foreignTarget -join "`0")) { throw 'Virtual child filter ownership changed; foreign filters are not rewritten.' }
        }
        $correct=$false
        if ($device.InfPath) { $correct=(Test-GHUBDeviceBinding $Action.DeviceIdentity $device @($Manifest.DriverPackages)).Passed }
        if (-not $correct) {
            $allowedSource=$null -ne $Action.SourceIdentity -and (Test-GHUBDeviceBinding $Action.SourceIdentity $device @($Plan.SourceEvidence.DriverPackages)).Passed
            $unbound=-not $device.Service -and -not $device.InfPath -and -not @($device.UpperFilters).Count -and -not @($device.LowerFilters).Count
            if (-not $allowedSource -and -not $unbound) { throw 'The virtual child has neither its captured source or target binding nor a clean unbound state.' }
        }
        [pscustomobject]@{Device=$device;Correct=$correct}
    } catch { Throw-SwitchError ExternalChange $_.Exception.Message }
}
function Get-GHUBLoadedDriverPaths {
    Initialize-NativeLibrary
    @([GHubSwitcher.LoadedDriverApi]::Enumerate())
}
function Test-GHUBChildRebootSatisfied { param($Context,$Manifest)
    # This only discharges completed child-only advisory gates. Initial driver
    # plan changes, unknown native outcomes and effective filter edits still reboot.
    try {
        $state=Read-SwitchState $Context
        $plan=Get-DriverTransactionPlan $Context $Manifest
        if (-not $plan -or -not $state.TransactionId) { return $false }
        $bootId=Get-BootId;$bootTime=ConvertTo-UtcTime $bootId
        $journal=@(Read-ValidJournal $Context $state.TransactionId)
        $gates=@($journal | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'child-driver-reboot' -and $_.Before.BootId -eq $bootId})
        if (-not $gates.Count) { return $false }
        $currentIntents=@($journal | Where-Object {$_.Kind -eq 'Intent' -and (ConvertTo-UtcTime $_.TimestampUtc) -ge $bootTime})
        if (@($currentIntents | Where-Object {$_.StepId -match '^(driver-|filters-|auxiliary-)' -and $_.StepId -notlike 'driver-child-*'}).Count) { return $false }
        if (@($journal | Where-Object StepId -EQ 'switch-failure').Count) { return $false }
        $completedIntents=@();$services=@()
        foreach ($gate in $gates) {
            if ($gate.Before.PlanId -cne $plan.PlanId) { return $false }
            $intent=@($journal | Where-Object Sequence -EQ ($gate.Sequence-1))
            $done=@($journal | Where-Object Sequence -EQ ($gate.Sequence+1))
            if ($intent.Count -ne 1 -or $done.Count -ne 1) { return $false }
            $intent=$intent[0];$done=$done[0]
            if ($intent.Kind -ne 'Intent' -or $done.Kind -ne 'Done' -or $intent.StepId -notlike 'driver-child-*' -or $done.StepId -cne $intent.StepId) { return $false }
            $actions=@($plan.DeferredChildren | Where-Object {('driver-child-'+(Get-TextHash $_.DeviceIdentity.InstanceId)) -ceq $intent.StepId})
            if ($actions.Count -ne 1) { return $false };$action=$actions[0]
            if ($intent.Before.InstanceId -ine $gate.Before.InstanceId -or $done.Before.InstanceId -ine $gate.Before.InstanceId) { return $false }
            if ($intent.After.TargetPackageId -cne $action.TargetPackageId -or $intent.After.TargetSection -ine $action.TargetSection -or $intent.After.DeviceIdentity.InstanceId -ine $action.DeviceIdentity.InstanceId) { return $false }
            $result=$done.After
            if ((Get-ObjectValue $result Success $null) -isnot [bool] -or -not $result.Success -or (Get-ObjectValue $result NeedReboot $null) -isnot [bool] -or $result.NeedReboot) { return $false }
            if ([IO.Path]::GetFileName($result.InfPath) -ine $action.DeviceIdentity.InfPath -or $result.Section -ine $action.TargetSection) { return $false }
            foreach ($field in @('UpperFilters','LowerFilters')) {
                if ((@($intent.Before.$field) -join "`0") -cne (@($action.DeviceIdentity.$field) -join "`0")) { return $false }
            }
            $completedIntents+=@($intent.Sequence);$services+=@($action.ExpectedService)
        }
        if (@($currentIntents | Where-Object {$_.StepId -like 'driver-child-*' -and $_.Sequence -notin $completedIntents}).Count) { return $false }
        $sourceKernels=Get-ObjectValue $plan.SourceEvidence KernelServices $null
        if ($null -eq $sourceKernels) {
            # Older durable plans kept the kernel evidence in the source checkpoint.
            $sourceCheckpoints=@($journal | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'source'})
            if ($sourceCheckpoints.Count -ne 1 -or $sourceCheckpoints[0].Before.Slot -cne $plan.SourceSlot -or $sourceCheckpoints[0].Before.OwnerSid -cne $Context.OwnerSid) { return $false }
            $sourceKernels=Get-ObjectValue $sourceCheckpoints[0].Before KernelServices $null
            if ($null -eq $sourceKernels) { return $false }
        }
        $loaded=@(Get-GHUBLoadedDriverPaths | ForEach-Object {ConvertTo-KernelImagePath $_})
        foreach ($service in @($services | Sort-Object -Unique)) {
            $target=@($Manifest.KernelServices | Where-Object Name -EQ $service)
            $source=@($sourceKernels | Where-Object Name -EQ $service)
            if ($target.Count -ne 1 -or $target[0].Path -notin $loaded -or $source.Count -gt 1) { return $false }
            if ($source.Count -eq 1) {
                if ($source[0].Path -ine $target[0].Path -and $source[0].Path -in $loaded) { return $false }
                if ($source[0].Path -ieq $target[0].Path -and $source[0].Sha256 -cne $target[0].Sha256) { return $false }
            }
        }
        return [bool](Test-DriverState $Context $Manifest).TechnicalPassed
    } catch { return $false }
}
function Resume-GHUBVirtualChildren { param($Context,$Manifest,[switch]$AfterLaunch)
    $plan=Get-DriverTransactionPlan $Context $Manifest
    if (-not $plan) { return (New-OperationResult) }
    $state=Read-SwitchState $Context;$missing=@();$changed=$false
    $bootId=Get-BootId
    $rebootGates=@(Read-ValidJournal $Context $state.TransactionId | Where-Object {
        $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'child-driver-reboot' -and
        $_.Before.PlanId -eq $plan.PlanId -and $_.Before.BootId -eq $bootId
    })
    if($rebootGates.Count -and -not (Test-GHUBChildRebootSatisfied $Context $Manifest)){return (New-OperationResult PendingReboot RebootRequired 'A virtual device binding was attempted during this boot. Restart Windows before final verification.')}
    foreach ($action in @($plan.DeferredChildren)) {
        Assert-DriverPackage $Context $action.Package
        $binding=Get-GHUBVirtualChildBindingState $plan $Manifest $action
        if (-not $binding) { $missing+=$action.DeviceIdentity.InstanceId;continue }
        $device=$binding.Device
        if (-not $binding.Correct) {
            Add-JournalEntry $Context $state.TransactionId Intent ('driver-child-'+(Get-TextHash $action.DeviceIdentity.InstanceId)) $device $action
            $published=Stage-GHUBDriverPackage $Context $action.Package
            $binding=Get-GHUBVirtualChildBindingState $plan $Manifest $action
            if (-not $binding) { Throw-SwitchError ExternalChange 'The virtual child disappeared before native binding.' }
            $device=$binding.Device
            # Persist the reboot boundary before the native call so an interruption cannot erase it.
            Add-JournalEntry $Context $state.TransactionId Checkpoint 'child-driver-reboot' @{PlanId=$plan.PlanId;BootId=$bootId;InstanceId=$device.InstanceId} $null
            $result=Invoke-GHUBDriverBinding $device.InstanceId $published $action.TargetSection
            $installed=Resolve-GHUBVirtualChild $action.DeviceIdentity $action.ParentIdentity @(Get-NativeDevices) -AllowUnbound
            $filterChanged=$false
            foreach ($field in @('UpperFilters','LowerFilters')) {
                $foreign=@($installed.$field | Where-Object {$_ -notmatch '^logi_joy_|^logi_lamparray$|^lghub'})
                $expectedForeign=@($action.DeviceIdentity.$field | Where-Object {$_ -notmatch '^logi_joy_|^logi_lamparray$|^lghub'})
                if (($foreign -join "`0") -cne ($expectedForeign -join "`0")) { Throw-SwitchError ExternalChange 'Virtual child filter ownership changed during native installation.' }
                if ((@($installed.$field) -join "`0") -cne (@($action.DeviceIdentity.$field) -join "`0")) { $filterChanged=$true }
            }
            if ($filterChanged) {
                $filterStep='filters-child-'+(Get-TextHash $action.DeviceIdentity.InstanceId)
                Add-JournalEntry $Context $state.TransactionId Intent $filterStep $installed $action.DeviceIdentity
                Set-GHUBDriverDeviceFilters $device.InstanceId ([string[]]$action.DeviceIdentity.UpperFilters) ([string[]]$action.DeviceIdentity.LowerFilters)
                Add-JournalEntry $Context $state.TransactionId Done $filterStep $installed $action.DeviceIdentity
            }
            Add-JournalEntry $Context $state.TransactionId Done ('driver-child-'+(Get-TextHash $action.DeviceIdentity.InstanceId)) $device $result
            $changed=$true
        }
        foreach ($aux in @($plan.AuxiliaryActions | Where-Object { $_.Required -and $_.Name -eq $action.ExpectedService })) { Set-GHUBAuxiliaryAction $Context $aux }
    }
    if ($changed -and -not (Test-GHUBChildRebootSatisfied $Context $Manifest)) { return (New-OperationResult PendingReboot RebootRequired 'The recreated virtual device was bound to its captured driver. Restart Windows before final verification.') }
    if ($missing.Count) {
        if ($AfterLaunch) { Throw-SwitchError DeviceMissing 'The captured virtual device was not created after controlled G HUB startup.' }
        return (New-OperationResult AwaitingDevices AwaitingDevices 'Waiting for the captured virtual device to be created by G HUB.' $missing)
    }
    New-OperationResult
}
function Compare-GHUBVirtualTopology { param($Target,[object[]]$KnownManifests,[object[]]$Present)
    foreach ($parent in @($Target.Devices | Where-Object {$_.HardwareIds -contains 'root\LGHUBVirtualBus'})) {
        $expected=@($Target.Devices | Where-Object {Test-GHUBVirtualChild $_ $parent})
        $known=@($KnownManifests | ForEach-Object Devices | Where-Object {Test-GHUBVirtualChild $_ $parent})
        try{$actualParent=Resolve-ManagedDevice $parent $Present}catch{
            [pscustomobject]@{Passed=$false;Device=$parent.InstanceId;Failures=@($_.Exception.Message)}
            continue
        }
        foreach ($actual in @($Present | Where-Object { $_.InstanceId -like 'LGHUBDEVICE\*' -and (Get-ObjectValue $_ ParentInstanceId '') -ieq $actualParent.InstanceId })) {
            $matches=@($expected | Where-Object {$want=$_;@($actual.HardwareIds | Where-Object {$_ -in $want.HardwareIds}).Count -gt 0})
            if ($matches.Count -eq 1) { continue }
            $recorded=@($known | Where-Object {$want=$_;@($actual.HardwareIds | Where-Object {$_ -in $want.HardwareIds}).Count -gt 0})
            [pscustomobject]@{Passed=$false;Device=$actual.InstanceId;Failures=@($(if($recorded.Count){'SourceChildStillPresent'}else{'UncapturedVirtualChild'}))}
        }
    }
}
function Test-DriverState { param($Context,$Manifest,[switch]$AllowPendingChildren)
    $present=@(Get-NativeDevices); $checks=@();$pendingServices=@()
    $plan=if($AllowPendingChildren){Get-DriverTransactionPlan $Context $Manifest}else{$null}
    foreach ($want in $Manifest.Devices) {
        try {
            $parent=@($Manifest.Devices | Where-Object {Test-GHUBVirtualChild $want $_})
            if ($parent.Count -eq 1) {
                $actual=Resolve-GHUBVirtualChild $want $parent[0] $present -AllowMissing
                if (-not $actual -and $plan -and @($plan.DeferredChildren | Where-Object {$_.DeviceIdentity.InstanceId -ieq $want.InstanceId}).Count -eq 1) {
                    $actualParent=Resolve-ManagedDevice $parent[0] $present
                    if (-not (Test-GHUBDeviceBinding $parent[0] $actualParent @($Manifest.DriverPackages)).Passed) { Throw-SwitchError DriverMismatch 'Pending child parent driver is not the captured target.' }
                    $pendingServices+=$want.Service
                    $checks+=[pscustomobject]@{Passed=$true;Device=$want.InstanceId;Failures=@();DeferredUntilLaunch=$true}
                    continue
                }
                if (-not $actual) { Throw-SwitchError DeviceMissing 'The target virtual device is absent.' }
            } else { $actual=Resolve-ManagedDevice $want $present }
            $checks+=Test-GHUBDeviceBinding $want $actual @($Manifest.DriverPackages)
        } catch { $checks+=[pscustomobject]@{Passed=$false;Device=$want.InstanceId;Failures=@($_.Exception.Message)} }
    }
    $known=@($Manifest.KernelServices);$knownManifests=@()
    foreach($slot in @('modern','legacy')){
        $path=Join-Path $Context.Root "Manifests/$slot.json"
        if(Test-Path -LiteralPath $path){
            $other=Read-AtomicJson $path
            if($other.OwnerSid -ne $Context.OwnerSid){Throw-SwitchError OwnerMismatch 'Foreign kernel evidence.'}
            $known+=@($other.KernelServices)
            $knownManifests+=$other
        }
    }
    $checks+=@(Compare-GHUBVirtualTopology $Manifest $knownManifests $present)
    $known=@($known | Where-Object {$_.Name -notin $pendingServices})
    $runtime=@(Get-KernelInventory @($known|ForEach-Object Name|Sort-Object -Unique))
    $kernelTarget=[pscustomobject]@{KernelServices=@($Manifest.KernelServices | Where-Object {$_.Name -notin $pendingServices});ClassFilters=$Manifest.ClassFilters}
    $checks+=@(Compare-KernelComponents ([pscustomobject]@{KernelServices=$known}) $kernelTarget $runtime @(Get-ClassFilterInventory))
    [pscustomobject]@{TechnicalPassed=(@($checks | Where-Object { -not $_.Passed }).Count -eq 0);FunctionalStatus='Unverified';Checks=$checks;CapturedAt=[DateTime]::UtcNow.ToString('o')}
}
Export-ModuleMember -Function *-*
