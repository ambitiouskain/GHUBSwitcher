BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
    $path="$PSScriptRoot/../src/Modules/Drivers.psm1"
    if (Test-Path $path) { Import-Module $path -Force -DisableNameChecking }
    function Device($package,$upper=@()) { [pscustomobject]@{InstanceId='bus';HardwareIds=@('root\LGHUBVirtualBus');ContainerId='';ClassGuid='system';PackageId=$package;Service='bus';UpperFilters=$upper;LowerFilters=@();InfSection='Install';InfPath=$(switch($package){new{'oem1.inf'}old{'oem2.inf'}default{'oem3.inf'}});DriverVersion='1';ProblemCode=0} }
    function Env($slot,$device) { [pscustomobject]@{Slot=$slot;Devices=@($device);DriverPackages=@([pscustomobject]@{PackageId=$device.PackageId;ExportPath='fixture';InfRelative='driver.inf';InfHash=$device.PackageId});KernelServices=@();ClassFilters=@()} }
}
Describe 'Driver switching decisions' {
    BeforeEach { Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'new'}oem2.inf{'old'}oem3.inf{'same'}default{'uncaptured'}})} } }
    It 'does not reinstall an identical driver stack' {
        $source=Env modern (Device same)
        $target=Env legacy (Device same)
        $plan=New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=$source.Devices}
        $plan.RequiresRestart | Should -BeFalse
        @($plan.DeviceActions).Count | Should -Be 0
    }
    It 'requires reboot for a lower version package' {
        $source=Env modern (Device new)
        $target=Env legacy (Device old)
        $plan=New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=$source.Devices}
        $plan.RequiresRestart | Should -BeTrue
        $plan.DeviceActions[0].TargetPackageId | Should -Be old
    }
    It 'requires reboot even when only a filter changes' {
        $source=Env modern (Device same @('logi_joy_xlcore'))
        $target=Env legacy (Device same)
        $plan=New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=$source.Devices}
        $plan.RequiresRestart | Should -BeTrue
        @($plan.FilterActions).Count | Should -Be 1
    }
    It 'preserves foreign filter order while replacing managed filters' {
        $result=@(Merge-ManagedFilters @('foreign-a','logi_joy_xlcore','foreign-b') @('logi_joy_xlcore') @('logi_joy_old'))
        ($result -join ',') | Should -Be 'foreign-a,logi_joy_old,foreign-b'
    }
    It 'blocks a package referenced by an unowned device' {
        $source=Env modern (Device new)
        $target=Env legacy (Device old)
        $other=Device new; $other.InstanceId='outside'
        { New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=@($source.Devices[0],$other)} } | Should -Throw '*SharedDependency*'
    }
    It 'uses current identities for shared dependency checks after moving a device' {
        $source=Env modern (Device new); $target=Env legacy (Device old)
        $source.Devices[0].ContainerId='11111111-1111-1111-1111-111111111111'
        $target.Devices[0].ContainerId=$source.Devices[0].ContainerId
        $actual=Device new; $actual.InstanceId='new-port'; $actual.ContainerId=$source.Devices[0].ContainerId
        $plan=New-DriverPlan $source $target @{Devices=@($actual);AllDevices=@($actual)}
        $plan.DeviceActions[0].InstanceId | Should -Be new-port
        $other=Device new; $other.InstanceId='foreign'; $other.ContainerId='22222222-2222-2222-2222-222222222222'
        { New-DriverPlan $source $target @{Devices=@($actual);AllDevices=@($actual,$other)} } | Should -Throw '*SharedDependency*'
    }
    It 'refuses unclassified filter changes' {
        { Merge-ManagedFilters @('foreign-a') @('foreign-a') @() } | Should -Throw '*SharedDependency*'
    }
    It 'reports runtime package mismatch instead of using staged package presence' {
        $want=Device old; $actual=Device new
        (Compare-DriverDevice $want $actual).Passed | Should -BeFalse
    }
}
Describe 'Captured source binding validation' {
    BeforeEach { Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'new'}oem2.inf{'old'}oem3.inf{'same'}default{'uncaptured'}})} } }
    It 'rejects live source <Field> drift before creating a plan' -TestCases @(
        @{Field='InfPath';Value='oem999.inf'},
        @{Field='DriverVersion';Value='999.0'},
        @{Field='Service';Value='foreign_service'},
        @{Field='UpperFilters';Value=@('logi_joy_changed')},
        @{Field='LowerFilters';Value=@('foreign_filter')}
    ) {
        param($Field,$Value)
        $source=Env modern (Device new);$target=Env legacy (Device old)
        $actual=$source.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json
        $actual.$Field=$Value
        { New-DriverPlan $source $target @{Devices=@($actual);AllDevices=@($actual);ClassFilters=@()} } | Should -Throw '*ExternalChange*'
    }
    It 'accepts a renamed published INF only when its content still identifies the captured source package' {
        $source=Env modern (Device new);$target=Env legacy (Device old)
        $actual=$source.Devices[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json;$actual.InfPath='oem777.inf'
        Mock Get-FileHash -ModuleName Drivers { [pscustomobject]@{Hash='new'} }
        (New-DriverPlan $source $target @{Devices=@($actual);AllDevices=@($actual);ClassFilters=@()}).DeviceActions[0].SourcePackageId | Should -Be new
    }
}
Describe 'Kernel and class filter isolation' {
    BeforeEach { Mock Get-FileHash -ModuleName Drivers {param($LiteralPath) [pscustomobject]@{Hash=$(switch([IO.Path]::GetFileName($LiteralPath)){oem1.inf{'new'}oem2.inf{'old'}oem3.inf{'same'}default{'uncaptured'}})} } }
    It 'schedules disabling a source-only auxiliary driver before reboot' {
        $source=Env modern (Device same); $target=Env legacy (Device same)
        $source.KernelServices=@(@{Name='logi_joy_xlcore';Path='C:\Windows\system32\drivers\xl.sys';Sha256='a';State='Running';StartType=3})
        $plan=New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=$source.Devices;ClassFilters=@()}
        $plan.RequiresRestart | Should -BeTrue
        $plan.AuxiliaryActions[0].Name | Should -Be logi_joy_xlcore
        $plan.AuxiliaryActions[0].StartType | Should -Be 4
    }
    It 'fails technical health when a source-only component remains loaded' {
        $source=Env modern (Device same); $target=Env legacy (Device same)
        $source.KernelServices=@(@{Name='logi_joy_xlcore';Path='driver.sys';Sha256='a';State='Running';StartType=3})
        $runtime=@(@{Name='logi_joy_xlcore';Path='driver.sys';Sha256='a';State='Running';StartType=4})
        @(Compare-KernelComponents $source $target $runtime @() | Where-Object {-not $_.Passed}).Count | Should -BeGreaterThan 0
        $runtime[0].State='Stopped'
        @(Compare-KernelComponents $source $target $runtime @() | Where-Object {-not $_.Passed}).Count | Should -Be 0
    }
    It 'blocks changed class filters rather than rewriting a shared class' {
        $source=Env modern (Device same); $target=Env legacy (Device same)
        $source.ClassFilters=@(@{ClassGuid='system';UpperFilters=@('logi_joy_xlcore');LowerFilters=@()})
        $target.ClassFilters=@(@{ClassGuid='system';UpperFilters=@();LowerFilters=@()})
        { New-DriverPlan $source $target @{Devices=$source.Devices;AllDevices=$source.Devices;ClassFilters=$source.ClassFilters} } | Should -Throw '*SharedDependency*'
        @(Compare-KernelComponents $source $target @() $source.ClassFilters | Where-Object {-not $_.Passed}).Count | Should -BeGreaterThan 0
    }
    It 'does not treat missing class evidence or an unknown loaded driver as passed' {
        $source=Env modern (Device same); $target=Env legacy (Device same)
        $target.PSObject.Properties.Remove('ClassFilters')
        @(Compare-KernelComponents $source $target @() @() | Where-Object {-not $_.Passed}).Count | Should -BeGreaterThan 0
        $target|Add-Member ClassFilters @()
        @(Compare-KernelComponents $source $target @(@{Name='logi_joy_unknown';State='Running';StartType=3}) @() | Where-Object {-not $_.Passed}).Count | Should -BeGreaterThan 0
    }
}
