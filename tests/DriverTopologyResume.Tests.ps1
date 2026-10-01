BeforeAll {
    foreach($module in @('Core','Inventory','Storage','Lifecycle','Drivers','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$module.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'Deferred virtual driver completion gates' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $ctx;$state.Phase='PendingReboot';$state.Target='modern';$state.RebootRequestedAtBootId='boot-a';Write-SwitchState $ctx $state
        $manifest=[pscustomobject]@{Slot='modern';Services=@();KernelServices=@()}
        Mock Get-BootId -ModuleName Coordinator { 'boot-b' }
        Mock Get-GHUBHealth -ModuleName Coordinator { [pscustomobject]@{TechnicalPassed=$true;Checks=@()} }
        Mock Stop-GHUBEnvironment -ModuleName Coordinator { New-OperationResult }
        Mock Apply-EnvironmentServices -ModuleName Coordinator { New-OperationResult }
        Mock Start-GHUBUserSession -ModuleName Coordinator { param($Context,$Manifest) [IO.File]::WriteAllText((Join-Path $Context.Root 'controlled-launch'),'started');New-OperationResult }
    }
    It 'returns to a reboot gate when binding the child before launch requires another boot' {
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator { New-OperationResult PendingReboot RebootRequired 'child bound' }
        $result=Complete-GHUBTransaction $ctx $manifest
        $result.Status | Should -Be PendingReboot
        (Read-SwitchState $ctx).Phase | Should -Be PendingReboot
        (Read-SwitchState $ctx).RebootRequestedAtBootId | Should -Be boot-b
        Test-Path -LiteralPath (Join-Path $ctx.Root 'controlled-launch') | Should -BeFalse
        (Read-AtomicJson (Join-Path $ctx.Root 'Status/launch.json')).Enabled | Should -BeFalse
    }
    It 'finishes an advisory same-boot child gate only after independent driver verification' {
        $state=Read-SwitchState $ctx;$state.RebootRequestedAtBootId='boot-b';Write-SwitchState $ctx $state
        Mock Test-GHUBChildRebootSatisfied -ModuleName Coordinator {$true}
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {New-OperationResult}
        (Complete-GHUBTransaction $ctx $manifest).Status | Should -Be Ok
        (Read-SwitchState $ctx).Phase | Should -Be Idle
        Test-Path -LiteralPath (Join-Path $ctx.Root 'controlled-launch') | Should -BeTrue
    }
    It 'keeps an initial same-boot reboot pending without starting the target' {
        $state=Read-SwitchState $ctx;$state.RebootRequestedAtBootId='boot-b';Write-SwitchState $ctx $state
        Mock Test-GHUBChildRebootSatisfied -ModuleName Coordinator {$false}
        (Complete-GHUBTransaction $ctx $manifest).Status | Should -Be PendingReboot
        Test-Path -LiteralPath (Join-Path $ctx.Root 'controlled-launch') | Should -BeFalse
    }
    It 'rechecks an advisory child gate inside the normal resume transaction' {
        $state=Read-SwitchState $ctx;$state.RebootRequestedAtBootId='boot-b';Write-SwitchState $ctx $state
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Read-EnvironmentManifest -ModuleName Coordinator {$manifest}
        Mock Test-GHUBChildRebootSatisfied -ModuleName Coordinator {$true}
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {New-OperationResult}
        (Resume-GHUBTransaction $ctx).Status | Should -Be Ok
        (Read-SwitchState $ctx).Phase | Should -Be Idle
    }
    It 'uses normal recovery if same-boot completion fails after the gate is discharged' {
        $state=Read-SwitchState $ctx;$state.RebootRequestedAtBootId='boot-b';Write-SwitchState $ctx $state
        Mock Assert-Administrator -ModuleName Coordinator {}
        Mock Read-EnvironmentManifest -ModuleName Coordinator {$manifest}
        Mock Test-GHUBChildRebootSatisfied -ModuleName Coordinator {$true}
        Mock Complete-GHUBTransaction -ModuleName Coordinator {throw 'HealthCheckFailed: target failed'}
        Mock Invoke-GHUBRollback -ModuleName Coordinator {param($Context,$Cause) New-OperationResult RecoveryRequired RecoveryRequired $Cause}
        (Resume-GHUBTransaction $ctx).Status | Should -Be RecoveryRequired
    }
    It 'does not commit when a child is created and bound only after controlled application startup' {
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {
            param($Context,$Manifest)
            if(Test-Path -LiteralPath (Join-Path $Context.Root 'controlled-launch')){New-OperationResult PendingReboot RebootRequired 'child bound'}else{New-OperationResult AwaitingDevices AwaitingDevices 'waiting'}
        }
        $result=Complete-GHUBTransaction $ctx $manifest
        $result.Status | Should -Be PendingReboot
        (Read-SwitchState $ctx).Phase | Should -Be PendingReboot
        (Read-SwitchState $ctx).TransactionId | Should -Be fixture
        @(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ verified).Count | Should -Be 0
    }
    Context 'Final child check after the polling deadline' {
        BeforeEach {
            $script:verificationClockReads=0
            $script:finalChildChecked=$false
            Mock Get-Date -ModuleName Coordinator {
                $script:verificationClockReads++
                ([DateTime]'2030-01-01T00:00:00Z').ToUniversalTime().AddSeconds(31*($script:verificationClockReads-1))
            }
        }
        It 'preserves the reboot gate when only the final child check binds the device' {
            Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {
                param($Context,$Manifest,[switch]$AfterLaunch)
                if($AfterLaunch){New-OperationResult PendingReboot RebootRequired 'late child bound'}else{New-OperationResult AwaitingDevices AwaitingDevices 'waiting'}
            }
            Mock Get-GHUBHealth -ModuleName Coordinator {
                param($Context,$Manifest,[switch]$BeforeLaunch)
                [pscustomobject]@{TechnicalPassed=[bool]$BeforeLaunch;Checks=@()}
            }
            Mock Stop-GHUBEnvironment -ModuleName Coordinator {
                param($Context,$Manifest)
                [IO.File]::WriteAllText((Join-Path $Context.Root 'controlled-stop'),'stopped');New-OperationResult
            }
            $result=Complete-GHUBTransaction $ctx $manifest
            $result.Status | Should -Be PendingReboot
            $saved=Read-SwitchState $ctx
            $saved.Phase | Should -Be PendingReboot
            $saved.RebootRequestedAtBootId | Should -Be boot-b
            $saved.TransactionId | Should -Be fixture
            (Read-AtomicJson (Join-Path $ctx.Root 'Status/launch.json')).Enabled | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $ctx.Root 'controlled-stop') | Should -BeTrue
            @(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ verified).Count | Should -Be 0
        }
        It 'does not commit a final child result that remains <FinalStatus>' -TestCases @(
            @{FinalStatus='AwaitingDevices'},
            @{FinalStatus='Blocked'}
        ) {
            param($FinalStatus)
            Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {
                param($Context,$Manifest,[switch]$AfterLaunch)
                if($AfterLaunch){New-OperationResult $FinalStatus $FinalStatus 'child not ready'}else{New-OperationResult AwaitingDevices AwaitingDevices 'waiting'}
            }
            { Complete-GHUBTransaction $ctx $manifest } | Should -Throw '*HealthCheckFailed*'
            (Read-SwitchState $ctx).Phase | Should -Be Verifying
            (Read-SwitchState $ctx).TransactionId | Should -Be fixture
            @(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ verified).Count | Should -Be 0
        }
        It 'uses fresh health after the final child check succeeds (healthy: <HealthyAfterFinal>)' -TestCases @(
            @{HealthyAfterFinal=$true},
            @{HealthyAfterFinal=$false}
        ) {
            param($HealthyAfterFinal)
            Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {
                param($Context,$Manifest,[switch]$AfterLaunch)
                if($AfterLaunch){$script:finalChildChecked=$true;New-OperationResult}else{New-OperationResult AwaitingDevices AwaitingDevices 'waiting'}
            }
            Mock Get-GHUBHealth -ModuleName Coordinator {
                param($Context,$Manifest,[switch]$BeforeLaunch)
                $passed=if($BeforeLaunch){$true}elseif($script:finalChildChecked){$HealthyAfterFinal}else{-not $HealthyAfterFinal}
                [pscustomobject]@{TechnicalPassed=$passed;Checks=@();CapturedAt=$(if($script:finalChildChecked){'after-final-child'}else{'before-final-child'})}
            }
            if($HealthyAfterFinal){
                $result=Complete-GHUBTransaction $ctx $manifest
                $result.Status | Should -Be Ok
                $result.Evidence[0].CapturedAt | Should -Be after-final-child
                (Read-SwitchState $ctx).Phase | Should -Be Idle
                $verified=@(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ verified)
                $verified.Count | Should -Be 1
                $verified[0].After.CapturedAt | Should -Be after-final-child
            }else{
                { Complete-GHUBTransaction $ctx $manifest } | Should -Throw '*HealthCheckFailed*'
                (Read-SwitchState $ctx).Phase | Should -Be Verifying
                (Read-SwitchState $ctx).TransactionId | Should -Be fixture
                @(Read-ValidJournal $ctx fixture | Where-Object StepId -EQ verified).Count | Should -Be 0
            }
        }
    }
    It 'allows the two explicit late driver reboot transitions without permitting an early commit' {
        foreach($phase in @('AwaitingLogon','Verifying')){
            $state=Read-SwitchState $ctx;$state.Phase=$phase
            (Set-SwitchPhase $state PendingReboot).Phase | Should -Be PendingReboot
        }
    }
}
