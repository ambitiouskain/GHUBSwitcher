BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Coordinator.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'G HUB health with isolated inventory and directories' {
    BeforeEach {
        $script:ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:dirs=Get-ActiveDirectories $ctx
        $script:manifest=[pscustomobject]@{
            ProductVersion='modern'
            Files=@([pscustomobject]@{Relative='slot.txt';Sha256=(Get-FileHash -LiteralPath (Join-Path $dirs.Program 'slot.txt')).Hash.ToLowerInvariant()})
            Services=@([pscustomobject]@{Name='LGHUBUpdaterService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe"'})
        }
        $script:inventory=[pscustomobject]@{
            ProductVersion='modern';Directories=$dirs;Devices=@();AllDevices=@();KernelServices=@();ClassFilters=@();Startup=@();Tasks=@();CapturedAt='fixture'
            Services=@([pscustomobject]@{Name='LGHUBUpdaterService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe"';Account='LocalSystem';StartMode='Auto';State='Running';Start=2;Type=16;DelayedAutoStart=0;Dependencies=@();FailureActions=$null;TriggerInfoPresent=$false;Native=$null})
            Processes=@([pscustomobject]@{Id=123;Name='lghub_agent.exe';Path=(Join-Path $dirs.Program 'lghub_agent.exe');OwnerSid=$ctx.OwnerSid;SessionId=1})
        }
        $script:driverReport=[pscustomobject]@{TechnicalPassed=$true;Checks=@()}
        $script:updatePolicy=[pscustomobject]@{Status='Ok';Code='Ok'}
        Mock Test-DriverState -ModuleName Coordinator { $script:driverReport }
        Mock Get-GHUBInventory -ModuleName Coordinator { $script:inventory }
        Mock Test-UpdatePolicy -ModuleName Coordinator { $script:updatePolicy }
    }
    It 'reports no failure reasons when every technical check passes' {
        $health=Get-GHUBHealth $ctx $manifest
        $health.TechnicalPassed | Should -BeTrue
        $health.FunctionalStatus | Should -Be Unverified
        @($health.Checks | ForEach-Object Failures).Count | Should -Be 0
    }
    It 'rejects a required service that is <State> after launch even while the agent exists' -TestCases @(
        @{State='Stopped'},@{State='Start Pending'},@{State='Paused'}
    ) {
        param($State)
        $inventory.Services[0].State=$State
        $health=Get-GHUBHealth $ctx $manifest
        $health.TechnicalPassed | Should -BeFalse
        $check=$health.Checks | Where-Object Device -EQ 'LGHUBUpdaterService'
        $check.Passed | Should -BeFalse
        $check.Failures | Should -Contain ServiceNotRunning
    }
    It 'rejects a running service when <Source> still marks it disabled' -TestCases @(
        @{Source='CIM';StartMode='Disabled';Start=2},
        @{Source='registry';StartMode='Auto';Start=4}
    ) {
        param($Source,$StartMode,$Start)
        $inventory.Services[0].StartMode=$StartMode
        $inventory.Services[0].Start=$Start
        $health=Get-GHUBHealth $ctx $manifest
        $health.TechnicalPassed | Should -BeFalse
        $check=$health.Checks | Where-Object Device -EQ 'LGHUBUpdaterService'
        $check.Passed | Should -BeFalse
        $check.Failures | Should -Contain ServiceDisabled
    }
    It 'allows stopped and disabled services before launch restoration' {
        $inventory.Services[0].State='Stopped'
        $inventory.Services[0].StartMode='Disabled'
        $inventory.Services[0].Start=4
        $inventory.Processes=@()
        $health=Get-GHUBHealth $ctx $manifest -BeforeLaunch
        $health.TechnicalPassed | Should -BeTrue
        @($health.Checks | ForEach-Object Failures).Count | Should -Be 0
    }
    It 'requires service identity to match even before launch' {
        $inventory.Services[0].ImagePath='"C:\Other\lghub_updater.exe"'
        $health=Get-GHUBHealth $ctx $manifest -BeforeLaunch
        $health.TechnicalPassed | Should -BeFalse
        ($health.Checks | Where-Object Device -EQ 'LGHUBUpdaterService').Failures | Should -Contain ServiceMismatch
    }
    It 'reports only the failed check for <Fault>' -TestCases @(
        @{Fault='missing directory';Device='LocalData';Failure='DirectoryMissing'},
        @{Fault='changed program';Device='slot.txt';Failure='ProgramIdentityMismatch'},
        @{Fault='different version';Device='ProductVersion';Failure='VersionMismatch'},
        @{Fault='missing service';Device='LGHUBUpdaterService';Failure='ServiceMismatch'},
        @{Fault='duplicate service';Device='LGHUBUpdaterService';Failure='ServiceMismatch'},
        @{Fault='unverified update policy';Device='UpdatePolicy';Failure='UpdatePolicyUnverified'},
        @{Fault='missing agent';Device='RunningProcesses';Failure='ProcessIdentityMismatch'}
    ) {
        param($Fault,$Device,$Failure)
        switch ($Fault) {
            'missing directory' {
                Remove-Item -LiteralPath (Join-Path $dirs.LocalData 'slot.txt')
                Remove-Item -LiteralPath $dirs.LocalData
            }
            'changed program' { Set-Content -LiteralPath (Join-Path $dirs.Program 'slot.txt') -Value 'changed' }
            'different version' { $inventory.ProductVersion='legacy' }
            'missing service' { $inventory.Services=@() }
            'duplicate service' { $inventory.Services=@($inventory.Services[0],$inventory.Services[0]) }
            'unverified update policy' { $updatePolicy.Status='Blocked'; $updatePolicy.Code='UpdatePolicyUnverified' }
            'missing agent' { $inventory.Processes=@() }
        }
        $health=Get-GHUBHealth $ctx $manifest
        $health.TechnicalPassed | Should -BeFalse
        $failed=@($health.Checks | Where-Object {-not $_.Passed})
        $failed.Count | Should -Be 1
        $failed[0].Device | Should -Be $Device
        $failed[0].Failures | Should -Contain $Failure
        @($health.Checks | Where-Object Passed | ForEach-Object Failures).Count | Should -Be 0
    }
}
