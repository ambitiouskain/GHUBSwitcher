BeforeAll {
    foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator','Bootstrap')) {
        Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking
    }
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'Detachment retains the current modern environment' {
    BeforeEach {
        $script:detachContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $ctx=$script:detachContext
        Write-SwitchState $ctx (New-SwitchState $ctx modern fixture)
        $script:detachCurrent=[pscustomobject]@{
            Slot='modern';ProductVersion='2026.current';Services=@()
            Startup=@([pscustomobject]@{Path='Registry::fixture';Name='CurrentGHUB';Kind='String';Value='current.exe'})
            Tasks=@([pscustomobject]@{Name='UpdatedOfficial';Path='\';Xml='<Task>new-version</Task>'},[pscustomobject]@{Name='AddedOfficial';Path='\';Xml='<Task>added</Task>'})
        }
        $original=[pscustomobject]@{Services=@();Startup=@([pscustomobject]@{Path='Registry::fixture';Name='ObsoleteGHUB';Kind='String';Value='old.exe'});Tasks=@([pscustomobject]@{Name='UpdatedOfficial';Path='\';Xml='<Task>obsolete-version</Task>'})}
        Write-AtomicJson (Join-Path $ctx.Root 'State/original-control.json') $original
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') @{OwnerSid=$ctx.OwnerSid;Detached=$false}
        $script:detachTasks=@{'GHUBSwitcher-Monitor'='controlled';'GHUBSwitcher-RecoverAtBoot'='controlled';'GHUBSwitcher-UserSession'='controlled'}
        $script:detachStartup=@{};$script:detachFailOnce=$false
        $script:detachHashes=@(foreach($role in (Get-ActiveDirectories $ctx).Keys){Get-FileHash -LiteralPath (Join-Path (Get-ActiveDirectories $ctx)[$role] 'slot.txt') | ForEach-Object Hash})
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Read-EnvironmentManifest -ModuleName Bootstrap {$script:detachCurrent}
        Mock Get-GHUBHealth -ModuleName Bootstrap {@{TechnicalPassed=$true}}
        Mock Stop-GHUBEnvironment -ModuleName Bootstrap {New-OperationResult}
        Mock Read-RegistryValue -ModuleName Bootstrap {param($Path,$Name) if($script:detachStartup.ContainsKey($Name)){$script:detachStartup[$Name]}else{@{Exists=$false;Kind='';Value=$null}}}
        Mock Write-RegistryValue -ModuleName Bootstrap {param($Path,$Name,$Record) $script:detachStartup[$Name]=$Record}
        Mock Register-ScheduledTask -ModuleName Bootstrap {param([string]$TaskName,[string]$Xml) $script:detachTasks[$TaskName]=$Xml}
        Mock Stop-ScheduledTask -ModuleName Bootstrap {}
        Mock Get-ScheduledTask -ModuleName Bootstrap {param([string]$TaskName) if($script:detachTasks.ContainsKey($TaskName)){[pscustomobject]@{TaskName=$TaskName}}}
        Mock Unregister-ScheduledTask -ModuleName Bootstrap {
            param([string]$TaskName)
            if($script:detachFailOnce -and $TaskName -eq 'GHUBSwitcher-RecoverAtBoot'){$script:detachFailOnce=$false;throw 'fixture task removal interrupted'}
            if(-not $script:detachTasks.ContainsKey($TaskName)){throw 'fixture task missing'}
            $script:detachTasks.Remove($TaskName)
        }
    }
    It 'restores current vendor startup entries and task XML rather than obsolete original definitions' {
        (Remove-SwitcherControl $ctx).Status | Should -Be Ok
        $detachStartup['CurrentGHUB'].Value | Should -Be 'current.exe'
        $detachStartup.ContainsKey('ObsoleteGHUB') | Should -BeFalse
        $detachTasks['UpdatedOfficial'] | Should -Be '<Task>new-version</Task>'
        $detachTasks['AddedOfficial'] | Should -Be '<Task>added</Task>'
        @($detachTasks.Keys | Where-Object {$_ -like 'GHUBSwitcher-*'}).Count | Should -Be 0
        (Read-AtomicJson (Join-Path $ctx.Root 'registration.json')).Detached | Should -BeTrue
        (Read-SwitchState $ctx).Phase | Should -Be Detached
        $after=@(foreach($role in (Get-ActiveDirectories $ctx).Keys){Get-FileHash -LiteralPath (Join-Path (Get-ActiveDirectories $ctx)[$role] 'slot.txt') | ForEach-Object Hash})
        ($after -join ',') | Should -BeExactly ($detachHashes -join ',')
        (Read-AtomicJson (Join-Path $ctx.Root 'Status/launch.json')).Enabled | Should -BeFalse
        (Read-AtomicJson (Join-Path $ctx.Root 'Status/status.json')).Phase | Should -Be Detached
    }
    It 'records interrupted removal and safely resumes after a task was already removed' {
        $script:detachFailOnce=$true
        (Remove-SwitcherControl $ctx).Status | Should -Be RecoveryRequired
        (Read-SwitchState $ctx).Phase | Should -Be Detaching
        (Read-SwitchState $ctx).LastError | Should -Match 'interrupted'
        (Read-AtomicJson (Join-Path $ctx.Root 'registration.json')).Detached | Should -BeFalse
        (Remove-SwitcherControl $ctx).Status | Should -Be Ok
        (Read-SwitchState $ctx).Phase | Should -Be Detached
        $detachTasks['AddedOfficial'] | Should -Be '<Task>added</Task>'
    }
    It 'finishes recovery without stopping its own RecoverAtBoot task' {
        Mock Stop-ScheduledTask -ModuleName Bootstrap {param([string]$TaskName) if($TaskName -eq 'GHUBSwitcher-RecoverAtBoot'){throw 'fixture worker terminated itself'}}
        (Remove-SwitcherControl $ctx).Status | Should -Be Ok
        (Read-SwitchState $ctx).Phase | Should -Be Detached
        $detachTasks.ContainsKey('GHUBSwitcher-RecoverAtBoot') | Should -BeFalse
    }
    It 'rejects detachment when modern health has not passed without disabling launch' {
        Mock Get-GHUBHealth -ModuleName Bootstrap {@{TechnicalPassed=$false}}
        {Remove-SwitcherControl $ctx} | Should -Throw '*HealthCheckFailed*'
        (Read-SwitchState $ctx).Phase | Should -Be Idle
        Test-Path -LiteralPath (Join-Path $ctx.Root 'Status/launch.json') | Should -BeFalse
    }
    It 'restores original service startup policy while retaining the current executable and dependencies' {
        Initialize-NativeLibrary
        $detachCurrent.Services=@([pscustomobject]@{Name='LGHUBUpdaterService';Native=@{Name='LGHUBUpdaterService';ImagePath='current-updater.exe';StartType=3;DelayedAutoStart=$false;Dependencies=@('CurrentDependency');FailureActions=@()}})
        Write-AtomicJson (Join-Path $ctx.Root 'State/original-control.json') @{Services=@(@{Name='LGHUBUpdaterService';Native=@{StartType=2;DelayedAutoStart=$true;FailureActions=@(@{Type=1;Delay=60000})}});Startup=@();Tasks=@()}
        $script:detachService=$null
        Mock Restore-DetachedServiceConfiguration -ModuleName Bootstrap {param($Record) $script:detachService=$Record}
        Mock Start-Service -ModuleName Bootstrap {}
        (Remove-SwitcherControl $ctx).Status | Should -Be Ok
        $detachService.StartType | Should -Be 2
        $detachService.DelayedAutoStart | Should -BeTrue
        $detachService.ImagePath | Should -Be 'current-updater.exe'
        $detachService.Dependencies | Should -Contain 'CurrentDependency'
        $detachService.FailureActions[0].Delay | Should -Be 60000
    }
}
Describe 'Startup restoration metadata survives maintenance' {
    It 'retains managed startup, prefers vendor replacements, and preserves unchanged task enablement' {
        $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command></Exec></Actions></Task>'
        $prior=@{Startup=@(@{Path='run';Name='retained';Value='retained.exe'},@{Path='run';Name='replaced';Value='old.exe'});Tasks=@(@{Name='Official';Path='\';Xml=$xml})}
        $new=@{Startup=@(@{Path='run';Name='replaced';Value='new.exe'},@{Path='run';Name='added';Value='added.exe'});Tasks=@(@{Name='Official';Path='\';Xml=$xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')},@{Name='Added';Path='\';Xml=$xml})}
        $restore=Get-ModernStartupRestore $prior $new
        @($restore.Startup).Count | Should -Be 3
        ($restore.Startup|Where-Object Name -EQ replaced).Value | Should -Be 'new.exe'
        ($restore.Startup|Where-Object Name -EQ retained).Value | Should -Be 'retained.exe'
        ($restore.Tasks|Where-Object Name -EQ Official).Xml | Should -BeExactly $xml
        ($restore.Tasks|Where-Object Name -EQ Added).Xml | Should -BeExactly $xml
        $second=Get-ModernStartupRestore @{Startup=@();Tasks=@();StartupRestore=$restore} $new
        ($second.Startup|Where-Object Name -EQ retained).Value | Should -Be 'retained.exe'
        $changed=Get-ModernStartupRestore $prior @{Startup=@();Tasks=@(@{Name='Official';Path='\';Xml=$xml.Replace('lghub.exe','lghub_system_tray.exe')})}
        $changed.Tasks[0].Xml | Should -Match 'lghub_system_tray.exe'
        $disabledChanged=Get-ModernStartupRestore $prior @{Startup=@();Tasks=@(@{Name='Official';Path='\';Xml=$xml.Replace('lghub.exe','lghub_system_tray.exe').Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')})}
        $disabledChanged.Tasks[0].Xml | Should -Match 'lghub_system_tray.exe'
        $disabledChanged.Tasks[0].Xml | Should -Match '<Enabled>true</Enabled>'
    }
}
