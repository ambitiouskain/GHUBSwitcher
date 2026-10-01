BeforeAll {
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Bootstrap.psm1" -Force -DisableNameChecking
}
Describe 'Modern recovery preflight ordering' {
    BeforeEach {
        $script:recoveryContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $recoveryContext;$state.TransactionId=$null;$state.Phase='RecoveryRequired';Write-SwitchState $recoveryContext $state
        $script:recoveryInventory=[pscustomobject]@{ProductVersion='2021.3.9205';CapturedAt='fixture';Directories=(Get-ActiveDirectories $recoveryContext);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@();Processes=@();AllDevices=@()}
        $script:recoveryModern=New-EnvironmentManifest $recoveryContext modern $recoveryInventory
        $backup=New-EnvironmentBackup $recoveryContext $recoveryModern
        $recoveryModern|Add-Member -NotePropertyName BackupPath -NotePropertyValue $backup.Path
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Read-EnvironmentManifest -ModuleName Bootstrap {$script:recoveryModern}
        Mock Get-GHUBInventory -ModuleName Bootstrap {$script:recoveryInventory}
        Mock Stop-GHUBEnvironment -ModuleName Bootstrap {New-OperationResult}
        Mock Export-ManagedDrivers -ModuleName Bootstrap {@()}
        Mock Restore-BackupDirectories -ModuleName Bootstrap {New-OperationResult}
        Mock Apply-EnvironmentServices -ModuleName Bootstrap {New-OperationResult}
        Mock Get-OwnedRegistryValues -ModuleName Bootstrap {@{Values=@()}}
        Mock Apply-EnvironmentRegistry -ModuleName Bootstrap {New-OperationResult}
        Mock New-DriverPlan -ModuleName Bootstrap {throw 'DriverMismatch: preflight rejected the actual topology.'}
    }
    It 'does not displace the installed program when driver planning fails' {
        $result=Restore-ModernBackup $recoveryContext
        $result.Status | Should -Be RecoveryRequired
        $result.Message | Should -BeLike '*preflight rejected*'
        Should -Invoke Restore-BackupDirectories -ModuleName Bootstrap -Times 0 -Exactly
        Should -Invoke Apply-EnvironmentRegistry -ModuleName Bootstrap -Times 0 -Exactly
    }
    It 'retains installed directories when the application-local kernel cannot unload' {
        Mock New-DriverPlan -ModuleName Bootstrap {[pscustomobject]@{PlanId='recovery-plan';OwnerSid=$script:recoveryContext.OwnerSid;SourceSlot='legacy';TargetSlot='modern'}}
        Mock Stop-EnvironmentAppLocalKernel -ModuleName Bootstrap {
            param($Context)
            @(Read-ValidJournal $Context (Read-SwitchState $Context).TransactionId|Where-Object StepId -eq 'driver-plan').Count | Should -Be 1
            throw 'AppLocalKernelRestartRequired: kernel did not unload.'
        }
        $result=Restore-ModernBackup $recoveryContext
        $result.Status | Should -Be RecoveryRequired
        $result.Message | Should -BeLike '*AppLocalKernelRestartRequired*'
        Should -Invoke Restore-BackupDirectories -ModuleName Bootstrap -Times 0 -Exactly
        Should -Invoke Apply-EnvironmentRegistry -ModuleName Bootstrap -Times 0 -Exactly
        (Read-SwitchState $recoveryContext).Health | Should -Be Unverified
    }
}
Describe 'Registration of a manually reviewed installer report' {
    It 'rejects a Passed flag without the immutable review evidence chain' {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $backup=New-EnvironmentBackup $ctx @{Slot='legacy';Directories=(Get-ActiveDirectories $ctx)}
        $path=Join-Path $ctx.Root 'Transactions/fixture-installer-reviewed-report.json'
        Write-AtomicJson $path @{Passed=$true;ValidationMode='ManualReview';OwnerSid=$ctx.OwnerSid;ProductVersion='2021.3.9205'}
        $manifest=[pscustomobject]@{
            OwnerSid=$ctx.OwnerSid;Slot='legacy';ProductVersion='2021.3.9205';DriverPackages=@();BackupPath=$backup.Path
            Qualification='Unverified';UpdatePolicy=@{Verified=$true;ProductVersion='2021.3.9205';Method='ObservedUI';Evidence=@('observed')}
            InstallerEvidence=@{Passed=$true;ProductVersion='2021.3.9205';Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
        }
        {Register-Environment $ctx $manifest} | Should -Throw '*UnclassifiedInstallerChange*'
        Test-Path (Join-Path $ctx.Root 'Manifests/legacy.json') | Should -BeFalse
    }
}
