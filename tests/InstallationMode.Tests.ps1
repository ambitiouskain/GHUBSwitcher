BeforeAll {
    foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    function Get-InstallationFixtureInventory {param($Context)
        $dirs=Get-ActiveDirectories $Context
        $running=Test-Path -LiteralPath (Join-Path $Context.Root 'started')
        [pscustomobject]@{ProductVersion=[IO.File]::ReadAllText((Join-Path $dirs.Program 'version.txt'));CapturedAt='fixture';Processes=@(if($running){[pscustomobject]@{Name='lghub_agent.exe';Path=(Join-Path $dirs.Program 'lghub_agent.exe');OwnerSid=$Context.OwnerSid}});Devices=@();AllDevices=@();Services=@();ClassFilters=@();KernelServices=@();Startup=@();Tasks=@();Directories=$dirs}
    }
}
Describe 'Installation and configuration acceptance without driver checks' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $ctx;$state.TransactionId=$null;Write-SwitchState $ctx $state
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') @{OwnerSid=$ctx.OwnerSid;ValidationMode='InstallationAndConfiguration'}
        foreach($slot in @('modern','legacy')){
            $dirs=if($slot -eq 'modern'){Get-ActiveDirectories $ctx}else{@{Program=(Join-Path $ctx.Root 'Environments/legacy/Program');LocalData=(Join-Path $ctx.Root 'Environments/legacy/LocalData');RoamingData=(Join-Path $ctx.Root 'Environments/legacy/RoamingData');MachineData=(Join-Path $ctx.Root 'Environments/legacy/MachineData')}}
            [IO.File]::WriteAllText((Join-Path $dirs.Program 'version.txt'),$slot)
            [IO.File]::WriteAllText((Join-Path $dirs.Program 'lghub_agent.exe'),$slot)
            [IO.File]::WriteAllText((Join-Path $dirs.LocalData 'settings.json'),($slot+'-initial'))
            $manifest=New-EnvironmentManifest $ctx $slot @{ProductVersion=$slot;CapturedAt='fixture';Directories=$dirs;Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@()}
            $manifest.Files=@([pscustomobject]@{Relative='lghub_agent.exe';Sha256=(Get-FileHash -LiteralPath (Join-Path $dirs.Program 'lghub_agent.exe')).Hash.ToLowerInvariant()})
            $manifest.Qualification='Prepared';$manifest.UpdatePolicy=@{Verified=$true;ProductVersion=$slot;Method='ObservedUI';Evidence=@('fixture')}
            $manifest|Add-Member Acls @(foreach($role in $dirs.Keys){[pscustomobject]@{Role=$role;Files=@(Get-TreeFiles $dirs[$role]);RootSddl=(Get-Acl -LiteralPath $dirs[$role]).Sddl}})
            Write-AtomicJson (Join-Path $ctx.Root "Manifests/$slot.json") $manifest
        }
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Get-BootId -ModuleName Coordinator {'boot-a'}
        Mock Get-GHUBInventory -ModuleName Coordinator {param($Context) Get-InstallationFixtureInventory $Context}
        Mock Get-GHUBInventory -ModuleName Lifecycle {param($Context) Get-InstallationFixtureInventory $Context}
        Mock Get-GHUBRegistryValues -ModuleName Coordinator {@{Roots=@();Values=@()}}
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle {@{Roots=@();Values=@()}}
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {param($Context) $p=Join-Path $Context.Root 'started';if(Test-Path $p){Remove-Item -LiteralPath $p};New-OperationResult}
        Mock Apply-EnvironmentRegistry -ModuleName Coordinator {New-OperationResult}
        Mock Apply-EnvironmentServices -ModuleName Coordinator {New-OperationResult}
        Mock Start-GHUBUserSession -ModuleName Coordinator {param($Context) [IO.File]::WriteAllText((Join-Path $Context.Root 'started'),'yes');New-OperationResult}
        Mock New-DriverPlan -ModuleName Coordinator {throw 'Unexpected system driver planning'}
        Mock Get-GHUBHealth -ModuleName Coordinator {throw 'Unexpected driver health verification'}
        Mock Test-GHUBChildRebootSatisfied -ModuleName Coordinator {$false}
    }
    It 'continues the existing same-boot pending transaction using real installed files and configuration' {
        $s=Read-SwitchState $ctx;$s.TransactionId='pending';$s.Target='legacy';$s.Phase='Swapping';Write-SwitchState $ctx $s
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $s.Phase='PendingReboot';$s.RebootRequestedAtBootId='boot-a';Write-SwitchState $ctx $s
        (Resume-GHUBTransaction $ctx).Status|Should -Be Ok
        $done=Read-SwitchState $ctx
        $done.Active|Should -Be legacy
        $done.Health|Should -Be InstallationAndConfigurationPassed
        $done.BootId|Should -Be boot-a
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'))|Should -Be legacy-initial
    }
    It 'preserves the newest configuration in both slots over repeated real directory exchanges' {
        foreach($n in 1..2){
            [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'),('modern-latest-'+$n))
            [IO.File]::WriteAllBytes((Join-Path $ctx.Root 'active/RoamingData/macro.bin'),[byte[]]@(0,255,$n))
            $result=Invoke-GHUBSwitch $ctx legacy
            $result.Status|Should -Be Ok -Because ($result.Message)
            [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'),('legacy-latest-'+$n))
            (Invoke-GHUBSwitch $ctx modern).Status|Should -Be Ok
            [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'))|Should -Be ('modern-latest-'+$n)
            [IO.File]::ReadAllText((Join-Path $ctx.Root 'Environments/legacy/LocalData/settings.json'))|Should -Be ('legacy-latest-'+$n)
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $ctx.Root 'active/RoamingData/macro.bin')))|Should -Be $(if($n -eq 1){'AP8B'}else{'AP8C'})
        }
    }
    It 'refuses to report installation success when program files were corrupted' {
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/Program/lghub_agent.exe'),'corrupt')
        $m=Read-EnvironmentManifest $ctx modern
        $s=Read-SwitchState $ctx;$s.TransactionId='badprogram';$s.Target='modern';$s.Phase='Binding';Write-SwitchState $ctx $s
        {Complete-GHUBTransaction $ctx $m}|Should -Throw '*InstallationCheckFailed*'
        Test-Path (Join-Path $ctx.Root 'started')|Should -BeFalse
    }
    It 'refuses to report restored configuration when a captured settings file is missing' {
        $m=Read-EnvironmentManifest $ctx modern
        Remove-Item -LiteralPath (Join-Path $ctx.Root 'active/LocalData/settings.json')
        $s=Read-SwitchState $ctx;$s.TransactionId='badconfig';$s.Target='modern';$s.Phase='Binding';Write-SwitchState $ctx $s
        {Complete-GHUBTransaction $ctx $m}|Should -Throw '*InstallationCheckFailed*'
        Test-Path (Join-Path $ctx.Root 'started')|Should -BeFalse
    }
    It 'does not run a driver monitor that would stop an accepted installation' {
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Test-DriverState -ModuleName Coordinator {throw 'Unexpected driver monitor'}
        Mock Start-Sleep -ModuleName Coordinator {throw 'Unexpected monitor loop'}
        {Watch-GHUBEnvironment $ctx}|Should -Not -Throw
    }
    It 'keeps the transaction resumable when the original user session is unavailable' {
        Mock Start-GHUBUserSession -ModuleName Coordinator {New-OperationResult AwaitingLogon AwaitingLogon 'session unavailable'}
        (Invoke-GHUBSwitch $ctx legacy).Status|Should -Be AwaitingLogon
        (Read-SwitchState $ctx).Phase|Should -Be AwaitingLogon
        (Read-SwitchState $ctx).Active|Should -Be modern
    }
    It 'does not replace the source configuration after a failed target launch' {
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'),'modern-written-just-now')
        Mock Start-GHUBUserSession -ModuleName Coordinator {
            param($Context,$Manifest)
            if($Manifest.Slot -eq 'legacy'){throw 'target launch failed'}
            [IO.File]::WriteAllText((Join-Path $Context.Root 'started'),'yes');New-OperationResult
        }
        $result=Invoke-GHUBSwitch $ctx legacy
        $result.Code|Should -Be SwitchFailedRecovered
        (Read-SwitchState $ctx).Active|Should -Be modern
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'))|Should -Be modern-written-just-now
    }
    It 'rejects leftover registry settings that do not belong to the restored configuration' {
        Mock Get-GHUBRegistryValues -ModuleName Coordinator {@{Roots=@();Values=@(@{Path='Registry::HKEY_CURRENT_USER\SOFTWARE\Logitech\LGHUB';Name='leftover';Exists=$true;Kind='String';Value='wrong-profile'})}}
        (Get-GHUBInstallationReport $ctx (Read-EnvironmentManifest $ctx modern)).Passed|Should -BeFalse
    }
    It 'does not mistake the SQLite shared-memory index for a missing user configuration' {
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/settings.db-shm'),'regenerated-index')
        (Get-GHUBInstallationReport $ctx (Read-EnvironmentManifest $ctx modern)).Passed|Should -BeTrue
    }
    It 'keeps current parked configuration instead of rejecting it against old file metadata' {
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'Environments/legacy/LocalData/settings.json'),'legacy-current-settings')
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'Environments/legacy/RoamingData/latest.lua'),'current macro')
        (Invoke-GHUBSwitch $ctx legacy).Status|Should -Be Ok
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'))|Should -Be legacy-current-settings
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/RoamingData/latest.lua'))|Should -Be 'current macro'
    }
    It 'does not mistake inherited file permission changes for changed configuration content' {
        $path=Join-Path $ctx.Root 'active/LocalData/settings.json'
        $acl=Get-Acl -LiteralPath $path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($ctx.OwnerSid),'Read','Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
        (Get-GHUBInstallationReport $ctx (Read-EnvironmentManifest $ctx modern)).Passed|Should -BeTrue
    }
}
