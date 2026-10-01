BeforeAll {
    foreach ($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator')) {
        Import-Module (Join-Path $PSScriptRoot "../src/Modules/$name.psm1") -Force -DisableNameChecking
    }
    Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force -DisableNameChecking

    # Use a .NET return boundary like RegistryKey: PowerShell ScriptMethod return
    # values can acquire ETS array wrappers when serialized by Windows PowerShell 5.
    if (-not ('ConfigurationIsolationRegistry' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using Microsoft.Win32;
public sealed class ConfigurationIsolationRecord {
    public string Kind { get; set; }
    public object Value { get; set; }
    public ConfigurationIsolationRecord(string kind, object value) { Kind=kind; Value=value; }
}
public sealed class ConfigurationIsolationWrite {
    public string Path { get; set; }
    public string Name { get; set; }
    public bool Exists { get; set; }
}
public sealed class ConfigurationIsolationRegistry {
    public Hashtable Entries = new Hashtable(StringComparer.OrdinalIgnoreCase);
    public List<ConfigurationIsolationWrite> Writes = new List<ConfigurationIsolationWrite>();
    public string FailAfterWrite;
}
public sealed class ConfigurationIsolationKey : IDisposable {
    public string Name { get { return Path.Substring("Registry::".Length); } }
    public string Path { get; private set; }
    private ConfigurationIsolationRegistry registry;
    private Hashtable Values { get { return (Hashtable)registry.Entries[Path]; } }
    public ConfigurationIsolationKey(string path, ConfigurationIsolationRegistry store) {
        Path=path; registry=store;
        if (!registry.Entries.ContainsKey(path)) registry.Entries[path]=new Hashtable(StringComparer.OrdinalIgnoreCase);
    }
    public string[] GetValueNames() {
        string[] names=new string[Values.Count]; Values.Keys.CopyTo(names,0); return names;
    }
    public RegistryValueKind GetValueKind(string name) {
        return (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), ((ConfigurationIsolationRecord)Values[name]).Kind);
    }
    public object GetValue(string name, object fallback, RegistryValueOptions options) {
        return Values.ContainsKey(name) ? ((ConfigurationIsolationRecord)Values[name]).Value : fallback;
    }
    public ConfigurationIsolationKey OpenSubKey(string name, bool writable) { return this; }
    public void SetValue(string name, object value, RegistryValueKind kind) {
        Values[name]=new ConfigurationIsolationRecord(kind.ToString(),value);
        registry.Writes.Add(new ConfigurationIsolationWrite { Path=Path, Name=name, Exists=true });
        if (registry.FailAfterWrite==name) {
            registry.FailAfterWrite=null;
            throw new InvalidOperationException("fixture registry write interrupted before completion log");
        }
    }
    public void DeleteValue(string name, bool throwOnMissing) {
        Values.Remove(name);
        registry.Writes.Add(new ConfigurationIsolationWrite { Path=Path, Name=name, Exists=false });
    }
    public void Dispose() {}
}
'@
    }
    # Only the Windows registry provider is replaced. Capture, type conversion,
    # comparison, application and journal rollback still run the production code.
    function New-IsolationRegistryKey {
        param([string]$Path,$Registry)
        [ConfigurationIsolationKey]::new($Path,$Registry)
    }
    function Set-IsolationRecord {
        param([string]$Path,[string]$Name,[string]$Kind,$Value)
        if (-not $script:isolationRegistry.Entries.ContainsKey($Path)) { $script:isolationRegistry.Entries[$Path]=@{} }
        $script:isolationRegistry.Entries[$Path][$Name]=[ConfigurationIsolationRecord]::new($Kind,$Value)
    }
    function Set-IsolationFiles {
        param([string]$Root,[string]$Slot,[string]$Revision)
        foreach ($role in @('LocalData','RoamingData','MachineData')) {
            $path=Join-Path $Root $role
            foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object Name -NE 'slot.txt')) {
                Remove-Item -LiteralPath $file.FullName
            }
            [IO.Directory]::CreateDirectory((Join-Path $path 'profiles')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $path "profiles/$Slot-$Revision.json"),"$Slot/$Revision/$role")
        }
        foreach ($name in @('settings.db','settings.db-wal','settings.db-shm')) {
            [IO.File]::WriteAllText((Join-Path $Root "LocalData/$name"),"$Slot/$Revision/$name")
        }
    }
    function Set-IsolationRuntime {
        param([string]$Slot,[string]$Revision)
        Set-IsolationFiles (Join-Path $script:isolationContext.Root 'active') $Slot $Revision
        foreach ($path in @($script:isolationRegistry.Entries.Keys | Where-Object { $_ -eq $script:isolationData -or $_.StartsWith($script:isolationData+'\') })) {
            $script:isolationRegistry.Entries.Remove($path)
        }
        Set-IsolationRecord $script:isolationData 'selected' String "$Slot/$Revision"
        Set-IsolationRecord $script:isolationData "$Slot-$Revision" Binary ([byte[]]@(0,128,255))
        Set-IsolationRecord ($script:isolationData+'\profiles') 'enabled' MultiString @($Slot,$Revision)
    }
    function Assert-IsolationFiles {
        param([string]$Root,[string]$Slot,[string]$Revision)
        foreach ($role in @('Program','LocalData','RoamingData','MachineData')) {
            $path=Join-Path $Root $role
            [IO.File]::ReadAllText((Join-Path $path 'slot.txt')) | Should -BeExactly $Slot
            $actual=@(Get-ChildItem -LiteralPath $path -File -Recurse | ForEach-Object { $_.FullName.Substring($path.Length+1).Replace('\','/') } | Sort-Object)
            $expected=@('slot.txt')
            if ($role -ne 'Program') { $expected+="profiles/$Slot-$Revision.json" }
            if ($role -eq 'LocalData') { $expected+=@('settings.db','settings.db-wal','settings.db-shm') }
            ($actual -join ',') | Should -BeExactly (($expected | Sort-Object) -join ',')
            if ($role -ne 'Program') { [IO.File]::ReadAllText((Join-Path $path "profiles/$Slot-$Revision.json")) | Should -BeExactly "$Slot/$Revision/$role" }
        }
        foreach ($name in @('settings.db','settings.db-wal','settings.db-shm')) {
            [IO.File]::ReadAllText((Join-Path $Root "LocalData/$name")) | Should -BeExactly "$Slot/$Revision/$name"
        }
    }
    function Assert-IsolationRegistry {
        param([string]$Slot,[string]$Revision,[object[]]$Records)
        $settings=@($Records | Where-Object { $_.Path -eq $script:isolationData -or $_.Path.StartsWith($script:isolationData+'\') })
        ($settings.Name | Sort-Object) -join ',' | Should -BeExactly ((@('selected',"$Slot-$Revision",'enabled') | Sort-Object) -join ',')
        ($settings | Where-Object Name -EQ selected).Value | Should -BeExactly "$Slot/$Revision"
        ($settings | Where-Object Name -EQ selected).Kind | Should -Be String
        $binary=$settings | Where-Object Name -EQ "$Slot-$Revision"
        $binary.Kind | Should -Be Binary
        [Convert]::ToBase64String([byte[]]$binary.Value) | Should -Be 'AID/'
        $multi=$settings | Where-Object Name -EQ enabled
        $multi.Kind | Should -Be MultiString
        ($multi.Value -join ',') | Should -BeExactly "$Slot,$Revision"
        ($Records | Where-Object Name -EQ DisplayVersion).Value | Should -BeExactly $Slot
        ($Records | Where-Object Name -EQ InstallPath).Value | Should -BeExactly 'C:\Fixture\LGHUB'
        @($Records).Count | Should -Be 5
    }
    function Assert-IsolationActive {
        param([string]$Slot,[string]$Revision)
        (Read-SwitchState $script:isolationContext).Active | Should -BeExactly $Slot
        (Read-SwitchState $script:isolationContext).Phase | Should -Be Idle
        Assert-IsolationFiles (Join-Path $script:isolationContext.Root 'active') $Slot $Revision
        Assert-IsolationRegistry $Slot $Revision @((Get-GHUBRegistryValues $script:isolationContext).Values)
        $script:isolationRegistry.Entries[$script:isolationOtherUser]['private'].Value | Should -BeExactly 'another-user-unchanged'
        $script:isolationRegistry.Entries[$script:isolationOtherMachine]['MachineGuid'].Value | Should -BeExactly 'machine-identity-unchanged'
        @($script:isolationRegistry.Writes | Where-Object { $_.Path -eq $script:isolationOtherUser -or $_.Path -eq $script:isolationOtherMachine }).Count | Should -Be 0
    }
    function Invoke-IsolationSwitch {
        param([string]$Slot)
        $result=Invoke-GHUBSwitch $script:isolationContext $Slot
        $result.Status | Should -Be Ok -Because ($result | ConvertTo-Json -Depth 15 -Compress)
    }
}

Describe 'Configuration isolation through complete simulated switches' {
    BeforeEach {
        $script:isolationContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $ctx=$script:isolationContext
        # Use a deliberately different owner from the logged-in test runner.
        $ctx.OwnerSid='S-1-5-21-111-222-333-1001'
        Write-SwitchState $ctx (New-SwitchState $ctx modern 'fixture-boot')
        $script:isolationData="Registry::HKEY_USERS\$($ctx.OwnerSid)\SOFTWARE\Logitech\LGHUB\Data"
        $script:isolationProduct='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\LGHUB'
        $script:isolationOtherUser='Registry::HKEY_USERS\S-1-5-21-111-222-333-1002\SOFTWARE\Logitech\LGHUB\Data'
        $script:isolationOtherMachine='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography'
        $script:isolationRegistry=[ConfigurationIsolationRegistry]::new()
        Set-IsolationRecord $script:isolationProduct InstallPath String 'C:\Fixture\LGHUB'
        Set-IsolationRecord $script:isolationProduct DisplayVersion String modern
        Set-IsolationRecord $script:isolationOtherUser private String 'another-user-unchanged'
        Set-IsolationRecord $script:isolationOtherMachine MachineGuid String 'machine-identity-unchanged'
        Set-IsolationRuntime modern initial
        Set-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy initial

        foreach ($module in @('Inventory','Lifecycle')) {
            Mock Test-Path -ModuleName $module -ParameterFilter { $LiteralPath -like 'Registry::*' } {
                param([string]$LiteralPath)
                return @($script:isolationRegistry.Entries.Keys | Where-Object { $_ -eq $LiteralPath -or $_.StartsWith($LiteralPath+'\',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            }
            Mock Get-Item -ModuleName $module -ParameterFilter { $LiteralPath -like 'Registry::*' } {
                param([string]$LiteralPath) New-IsolationRegistryKey $LiteralPath $script:isolationRegistry
            }
        }
        Mock Get-ChildItem -ModuleName Inventory -ParameterFilter { $LiteralPath -like 'Registry::*' } {
            param([string]$LiteralPath,[switch]$Recurse)
            foreach ($path in @($script:isolationRegistry.Entries.Keys | Where-Object { $_.StartsWith($LiteralPath+'\',[StringComparison]::OrdinalIgnoreCase) })) {
                if ($Recurse -or -not $path.Substring($LiteralPath.Length+1).Contains('\')) { New-IsolationRegistryKey $path $script:isolationRegistry }
            }
        }
        Mock New-Item -ModuleName Lifecycle -ParameterFilter { $Path -like 'Registry::*' } {
            param([string]$Path) New-IsolationRegistryKey $Path $script:isolationRegistry
        }
        foreach ($slot in @('modern','legacy')) {
            $inventory=[pscustomobject]@{ProductVersion=$slot;CapturedAt='fixture';Directories=(Get-ActiveDirectories $ctx);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@()}
            $manifest=New-EnvironmentManifest $ctx $slot $inventory
            $manifest.Qualification='Prepared'
            $manifest.UpdatePolicy=[pscustomobject]@{Verified=$true;ProductVersion=$slot;Method='ObservedUI';Evidence=@('fixture')}
            $manifest.RegistryValues=@(
                [pscustomobject]@{Path=$script:isolationProduct;Name='InstallPath';Exists=$true;Kind='String';Value='C:\Fixture\LGHUB'},
                [pscustomobject]@{Path=$script:isolationProduct;Name='DisplayVersion';Exists=$true;Kind='String';Value=$slot},
                [pscustomobject]@{Path=$script:isolationData;Name='selected';Exists=$true;Kind='String';Value="$slot/initial"},
                [pscustomobject]@{Path=$script:isolationData;Name="$slot-initial";Exists=$true;Kind='Binary';Value=@(0,128,255)},
                [pscustomobject]@{Path=($script:isolationData+'\profiles');Name='enabled';Exists=$true;Kind='MultiString';Value=@($slot,'initial')}
            )
            Write-AtomicJson (Join-Path $ctx.Root "Manifests/$slot.json") $manifest
        }
        foreach ($module in @('Coordinator','Lifecycle')) { Mock Assert-Administrator -ModuleName $module {} }
        Mock Get-BootId -ModuleName Coordinator { 'fixture-boot' }
        Mock Get-GHUBInventory -ModuleName Coordinator {
            param($Context)
            $version=[IO.File]::ReadAllText((Join-Path $Context.Root 'active/Program/slot.txt'))
            $processes=@()
            if (Test-Path -LiteralPath (Join-Path $Context.Root 'launched')) { $processes=@([pscustomobject]@{Name='lghub_agent.exe';OwnerSid=$Context.OwnerSid;Path=(Join-Path $Context.Root 'active/Program/lghub_agent.exe')}) }
            [pscustomobject]@{ProductVersion=$version;Processes=$processes;Devices=@();AllDevices=@();Services=@();KernelServices=@();Startup=@();Tasks=@();CapturedAt='fixture';Directories=(Get-ActiveDirectories $Context);ClassFilters=@()}
        }
        Mock Get-GHUBInventory -ModuleName Lifecycle {
            param($Context)
            $processes=@()
            if (Test-Path -LiteralPath (Join-Path $Context.Root 'launched')) { $processes=@([pscustomobject]@{Name='lghub_agent.exe'}) }
            [pscustomobject]@{Processes=$processes}
        }
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {
            param($Context)
            $path=Join-Path $Context.Root 'launched'
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            New-OperationResult
        }
        Mock Get-DirectoryIdentity -ModuleName Storage {
            param($Path)
            # Stable fixture identity follows the actual directory when it is renamed.
            [pscustomobject]@{VolumeSerial=1;FileId=([IO.File]::ReadAllText((Join-Path $Path 'slot.txt'))+'/'+(Split-Path $Path -Leaf))}
        }
        Mock Apply-EnvironmentServices -ModuleName Coordinator { New-OperationResult }
        Mock Assert-GHUBDriverPlanSource -ModuleName Coordinator {}
        Mock Invoke-DriverPlan -ModuleName Coordinator { New-OperationResult }
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator { New-OperationResult }
        Mock Test-DriverState -ModuleName Coordinator { [pscustomobject]@{Checks=@()} }
        Mock Start-GHUBUserSession -ModuleName Coordinator {
            param($Context,$Manifest)
            [IO.File]::WriteAllText((Join-Path $Context.Root 'launched'),$Manifest.Slot)
            New-OperationResult
        }
    }

    # Break caught: reusing the initial manifest/backup, merging directories, or
    # failing to delete source-only registry values silently loses slot isolation.
    It 'retains exact current files and owner registry values through repeated modern legacy round trips' {
        Set-IsolationRuntime modern one
        Assert-IsolationRegistry modern one @((Get-GHUBRegistryValues $ctx).Values)
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy initial
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/modern') modern one
        $modern=Read-EnvironmentManifest $ctx modern
        Assert-IsolationRegistry modern one $modern.RegistryValues

        Set-IsolationRuntime legacy one
        Invoke-IsolationSwitch modern
        Assert-IsolationActive modern one
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy one
        Assert-IsolationRegistry legacy one (Read-EnvironmentManifest $ctx legacy).RegistryValues

        Set-IsolationRuntime modern two
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy one
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/modern') modern two
        $latest=Read-EnvironmentManifest $ctx modern

        Set-IsolationRuntime legacy two
        Invoke-IsolationSwitch modern
        Assert-IsolationActive modern two
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy two
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/modern') modern two
    }

    It 'starts the active slot repeatedly without restoring its initial configuration' {
        Set-IsolationRuntime modern one
        Invoke-IsolationSwitch modern
        Assert-IsolationActive modern one
        $first=Read-EnvironmentManifest $ctx modern
        Assert-IsolationRegistry modern one $first.RegistryValues
        Set-IsolationRuntime modern two
        Invoke-IsolationSwitch modern
        Assert-IsolationActive modern two
        $second=Read-EnvironmentManifest $ctx modern
        Assert-IsolationRegistry modern two $second.RegistryValues
        Test-Path -LiteralPath (Join-Path $ctx.Root 'Environments/modern/LocalData') | Should -BeFalse
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy initial
    }

    It 'captures files and owner registry changes flushed during application shutdown' {
        Set-IsolationRuntime modern running
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {
            Set-IsolationRuntime modern shutdown
            New-OperationResult
        }
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy initial
        $saved=Read-EnvironmentManifest $ctx modern
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/modern') modern shutdown
        Assert-IsolationRegistry modern shutdown $saved.RegistryValues
    }

    It 'recovers both latest configurations when a registry write finishes before its journal completion' {
        Set-IsolationRuntime modern one
        Invoke-IsolationSwitch legacy
        Set-IsolationRuntime legacy one
        Invoke-IsolationSwitch modern
        Set-IsolationRuntime modern two
        $script:isolationRegistry.FailAfterWrite='legacy-one'
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Code | Should -Be SwitchFailedRecovered -Because ($result | ConvertTo-Json -Depth 15 -Compress)
        $result.Evidence.Cause | Should -Match 'fixture registry write interrupted'
        Assert-IsolationActive modern two
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy one
        Assert-IsolationRegistry modern two (Read-EnvironmentManifest $ctx modern).RegistryValues
        Assert-IsolationRegistry legacy one (Read-EnvironmentManifest $ctx legacy).RegistryValues
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy one
        Invoke-IsolationSwitch modern
        Assert-IsolationActive modern two
    }

    It 'recovers both latest file sets when a directory move finishes before its journal completion' {
        Set-IsolationRuntime modern one
        Invoke-IsolationSwitch legacy
        Set-IsolationRuntime legacy one
        Invoke-IsolationSwitch modern
        Set-IsolationRuntime modern two
        Mock Move-ManagedDirectory -ModuleName Storage {
            param($From,$To)
            [IO.Directory]::Move($From,$To)
            if ($From -eq (Join-Path $script:isolationContext.Root 'active/LocalData')) { throw 'fixture directory move interrupted before completion log' }
        }
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Code | Should -Be SwitchFailedRecovered -Because ($result | ConvertTo-Json -Depth 15 -Compress)
        $result.Evidence.Cause | Should -Match 'fixture directory move interrupted'
        Assert-IsolationActive modern two
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy one
        Assert-IsolationRegistry modern two (Read-EnvironmentManifest $ctx modern).RegistryValues
        Assert-IsolationRegistry legacy one (Read-EnvironmentManifest $ctx legacy).RegistryValues
        Mock Move-ManagedDirectory -ModuleName Storage { param($From,$To) [IO.Directory]::Move($From,$To) }
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy one
    }

    It 'does not adopt machine installation identity drift as current user configuration' {
        Set-IsolationRuntime modern latest
        Set-IsolationRecord $script:isolationProduct InstallPath String 'C:\Outside\ChangedInstallation'
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Status | Should -Be RecoveryRequired
        $result.Message | Should -Match 'ExternalChange'
        (Read-EnvironmentManifest $ctx modern).RegistryValues | Where-Object Name -EQ InstallPath | ForEach-Object Value | Should -BeExactly 'C:\Fixture\LGHUB'
        Assert-IsolationFiles (Join-Path $ctx.Root 'active') modern latest
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy initial
        $script:isolationRegistry.Entries[$script:isolationProduct]['InstallPath'].Value | Should -BeExactly 'C:\Outside\ChangedInstallation'
        $script:isolationRegistry.Writes.Count | Should -Be 0
    }

    It 'refuses a target configuration from a different user without touching that user' {
        Set-IsolationRuntime modern latest
        $target=Read-EnvironmentManifest $ctx legacy
        $target.RegistryValues+=@([pscustomobject]@{Path=$script:isolationOtherUser;Name='private';Exists=$true;Kind='String';Value='forbidden-overwrite'})
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/legacy.json') $target
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Code | Should -Be SwitchFailedRecovered -Because ($result | ConvertTo-Json -Depth 15 -Compress)
        $result.Evidence.Cause | Should -Match 'UnsafePath'
        Assert-IsolationActive modern latest
        Assert-IsolationFiles (Join-Path $ctx.Root 'Environments/legacy') legacy initial
    }

    It 'keeps distinct Data paths and value names containing a pipe separate across slots' {
        $firstPath=$script:isolationData+'\profile'
        $secondPath=$script:isolationData+'\profile|branch'
        Set-IsolationRecord $firstPath 'branch|setting' String 'first-setting'
        Set-IsolationRecord $secondPath 'setting' String 'second-setting'
        Invoke-IsolationSwitch legacy
        Assert-IsolationActive legacy initial
        (Read-RegistryValue $firstPath 'branch|setting').Exists | Should -BeFalse
        (Read-RegistryValue $secondPath 'setting').Exists | Should -BeFalse
        Invoke-IsolationSwitch modern
        (Read-RegistryValue $firstPath 'branch|setting').Value | Should -BeExactly 'first-setting'
        (Read-RegistryValue $secondPath 'setting').Value | Should -BeExactly 'second-setting'
    }
    It 'keeps ordinally distinct path and value pairs separate when culture comparison ignores their delimiter' {
        $firstPath=$script:isolationData+'\profile'
        $secondPath=$script:isolationData+'\profile\branch'
        Set-IsolationRecord $firstPath '\branch\setting' String 'first-profile'
        Set-IsolationRecord $secondPath '\setting' String 'second-profile'
        Invoke-IsolationSwitch legacy
        (Read-RegistryValue $firstPath '\branch\setting').Exists | Should -BeFalse
        (Read-RegistryValue $secondPath '\setting').Exists | Should -BeFalse
        Invoke-IsolationSwitch modern
        (Read-RegistryValue $firstPath '\branch\setting').Value | Should -BeExactly 'first-profile'
        (Read-RegistryValue $secondPath '\setting').Value | Should -BeExactly 'second-profile'
    }
}
