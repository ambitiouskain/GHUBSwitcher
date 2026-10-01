BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force
    $path="$PSScriptRoot/../src/Modules/Inventory.psm1"
    if (Test-Path $path) { Import-Module $path -Force }
}
Describe 'Device identity resolution' {
    It 'does not choose between identical receivers without identity evidence' {
        $id=@{InstanceId='old';HardwareIds=@('USB\VID_046D&PID_C54D');ContainerId='';ClassGuid='usb'}
        $devices=@(@{InstanceId='a';HardwareIds=$id.HardwareIds;ContainerId='';ClassGuid='usb'},@{InstanceId='b';HardwareIds=$id.HardwareIds;ContainerId='';ClassGuid='usb'})
        { Resolve-ManagedDevice $id $devices } | Should -Throw '*DeviceAmbiguous*'
    }
    It 'finds a moved device by container and matching hardware rather than an old port' {
        $id=@{InstanceId='old';HardwareIds=@('hw');ContainerId='11111111-1111-1111-1111-111111111111';ClassGuid='hid'}
        $devices=@(@{InstanceId='new';HardwareIds=@('hw');ContainerId=$id.ContainerId;ClassGuid='hid'},@{InstanceId='other';HardwareIds=@('hw');ContainerId='22222222-2222-2222-2222-222222222222';ClassGuid='hid'})
        (Resolve-ManagedDevice $id $devices).InstanceId | Should -Be new
    }
    It 'does not accept a reused instance identifier with different hardware' {
        $id=@{InstanceId='port';HardwareIds=@('old');ContainerId='';ClassGuid='hid'}
        { Resolve-ManagedDevice $id @(@{InstanceId='port';HardwareIds=@('new');ContainerId='';ClassGuid='hid'}) } | Should -Throw '*DeviceMissing*'
    }
    It 'refuses a device not presently attached' {
        $id=@{InstanceId='port';HardwareIds=@('hw');ContainerId='';ClassGuid='hid'}
        { Resolve-ManagedDevice $id @() } | Should -Throw '*DeviceMissing*'
    }
    It 'rejects zero or malformed containers when a unique device has moved' {
        foreach($container in @('00000000-0000-0000-0000-000000000000','not-a-guid','')) {
            $id=@{InstanceId='old';HardwareIds=@('hw');ContainerId=$container;ClassGuid='hid'}
            { Resolve-ManagedDevice $id @(@{InstanceId='unrelated';HardwareIds=@('hw');ContainerId=$container;ClassGuid='hid'}) } | Should -Throw '*DeviceAmbiguous*'
        }
    }
}
Describe 'Application inventory in installation acceptance mode' {
    It 'reads the installed program when system driver inventory is unavailable' {
        InModuleScope Inventory -Parameters @{FixtureRoot=$TestDrive} {
            param($FixtureRoot)
            $ctx=@{Mode='Live';Root=$FixtureRoot;OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ProfileRoot=$FixtureRoot}
            Write-AtomicJson (Join-Path $FixtureRoot 'registration.json') @{OwnerSid=$ctx.OwnerSid;ValidationMode='InstallationAndConfiguration'}
            $dirs=@{Program=$FixtureRoot;LocalData=$FixtureRoot;RoamingData=$FixtureRoot;MachineData=$FixtureRoot}
            [IO.File]::WriteAllText((Join-Path $FixtureRoot 'version.json'),'{"version":"2026.fixture"}')
            Mock Get-ActiveDirectories {$dirs}
            Mock Get-NativeDevices {throw 'System driver API unavailable'}
            Mock Get-ClassFilterInventory {throw 'Class filters unavailable'}
            Mock Get-KernelInventory {throw 'System kernel inventory unavailable'}
            Mock Get-AppLocalKernelNativeRecord {$null}
            Mock Get-CimInstance {@()}
            Mock Get-ScheduledTask {@()}
            (Get-GHUBInventory $ctx).ProductVersion|Should -Be '2026.fixture'
        }
    }
}
Describe 'Native read-only inventory' {
    It 'enumerates hardware and exposes the G HUB virtual bus filter' {
        $items=@(Get-NativeDevices)
        $items.Count | Should -BeGreaterThan 0
        $bus=@($items | Where-Object { $_.HardwareIds -contains 'root\LGHUBVirtualBus' })
        $bus.Count | Should -Be 1
        $bus[0].UpperFilters | Should -Contain 'logi_joy_xlcore'
        $bus[0].InfPath | Should -Match '^oem\d+\.inf$'
    }
}
Describe 'Scheduled task action inventory' {
    It 'reads executable actions without failing on COM handler actions' {
        $task=@{Actions=@([pscustomobject]@{ClassId='{handler}';Data='handler-data'},[pscustomobject]@{Execute='C:\Program Files\LGHUB\lghub.exe';Arguments='--background'})}
        $paths=@(Get-TaskExecutables $task)
        $paths.Count | Should -Be 1
        $paths[0] | Should -Be 'C:\Program Files\LGHUB\lghub.exe'
        @(Get-TaskExecutables @{Actions=@(@{ClassId='handler'})}).Count | Should -Be 0
    }
}
Describe 'Kernel inventory scope' {
    It 'does not include unrelated Logitech components in an explicit managed set' {
        InModuleScope Inventory {
            Mock Get-CimInstance {@(
                [pscustomobject]@{Name='logi_joy_xlcore';State='Running';StartMode='Manual';PathName='C:\fixture\owned.sys'},
                [pscustomobject]@{Name='logi_lamparray';State='Running';StartMode='Manual';PathName='C:\fixture\unrelated.sys'}
            )}
            Mock Get-ItemProperty {@{Start=3}}
            Mock Test-Path {$false}
            $items=@(Get-KernelInventory -Names @('logi_joy_xlcore'))
            $items.Count | Should -Be 1
            $items[0].Name | Should -Be 'logi_joy_xlcore'
            @(Get-KernelInventory -Names @()).Count | Should -Be 0
            @(Get-KernelInventory).Count | Should -Be 2
        }
    }
}
Describe 'Startup inventory preserves scoped registry records' {
    BeforeEach {
        InModuleScope Inventory {
            $script:startupContext=@{Root='C:\fixture';OwnerSid='S-1-5-21-1-2-3-1001';ProfileRoot='C:\fixture\owner';Mode='Live'}
            $script:startupKeys=@{}
            function script:New-StartupFixtureKey {param([hashtable]$Values)
                $key=[pscustomobject]@{Values=$Values;Disposed=$false}
                $key|Add-Member ScriptMethod GetValueNames { @($this.Values.Keys) }
                $key|Add-Member ScriptMethod GetValueKind {param($Name) [Microsoft.Win32.RegistryValueKind]::ExpandString}
                $key|Add-Member ScriptMethod GetValue {
                    param($Name,$Default,$Options)
                    if($Options -eq [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames){return $this.Values[$Name]}
                    [Environment]::ExpandEnvironmentVariables($this.Values[$Name])
                }
                $key|Add-Member ScriptMethod Dispose { $this.Disposed=$true }
                $key
            }
            Mock Get-NativeDevices { @() }
            Mock Get-CimInstance { @() }
            Mock Get-AppLocalKernelNativeRecord { $null }
            Mock Get-ClassFilterInventory { @() }
            Mock Get-KernelInventory { @() }
            Mock Get-ScheduledTask { @() }
            Mock Test-Path {param([string[]]$LiteralPath) $script:startupKeys.ContainsKey($LiteralPath[0])}
            Mock Get-Item {param([string[]]$LiteralPath) $script:startupKeys[$LiteralPath[0]]}
        }
    }
    It 'preserves an expandable G HUB command without replacing its environment variables' {
        InModuleScope Inventory {
            $root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $script:startupKeys[$root]=New-StartupFixtureKey @{GHUB='"%ProgramFiles%\LGHUB\lghub.exe" --background';Other='C:\Other\app.exe'}
            $result=Get-GHUBInventory $script:startupContext
            $result.Startup.Count | Should -Be 1
            $result.Startup[0].Value | Should -BeExactly '"%ProgramFiles%\LGHUB\lghub.exe" --background'
            $result.Startup[0].Kind | Should -Be ExpandString
        }
    }
    It 'captures G HUB startup from <Root>' -TestCases @(
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'},
        @{Root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'},
        @{Root='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'}
    ) {
        param($Root)
        InModuleScope Inventory -Parameters @{Root=$Root} {
            param($Root)
            $script:startupKeys[$Root]=New-StartupFixtureKey @{GHUB='"C:\Program Files\LGHUB\lghub.exe" --background';Other='C:\Other\app.exe'}
            $result=Get-GHUBInventory $script:startupContext
            $result.Startup.Count | Should -Be 1
            $result.Startup[0].Path | Should -Be $Root
            $result.Startup[0].Name | Should -Be GHUB
        }
    }
}
