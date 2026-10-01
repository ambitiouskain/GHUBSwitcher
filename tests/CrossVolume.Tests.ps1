BeforeAll {
    $moduleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/Modules'))
    Get-Module -All|Where-Object {$_.ModuleBase -eq $moduleRoot}|Remove-Module -Force
    foreach($name in @('Core','Inventory','Storage','Bootstrap')){Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'Portable environments on another real volume' {
    BeforeEach {
        $crossRoot=Join-Path 'D:\' ('GHUBSwitcher-Test-'+[guid]::NewGuid().ToString('N'))
        $ctx=New-TestContext $crossRoot
        $activeDirs=[ordered]@{}
        foreach($role in @('Program','LocalData','RoamingData','MachineData')){
            $activeDirs[$role]=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'/'+$role)
            [IO.Directory]::CreateDirectory($activeDirs[$role])|Out-Null
            Copy-Item -LiteralPath (Join-Path $crossRoot "active/$role/slot.txt") -Destination (Join-Path $activeDirs[$role] 'slot.txt')
            [IO.Directory]::CreateDirectory((Join-Path $activeDirs[$role] 'empty'))|Out-Null
        }
        Mock Get-ActiveDirectories -ModuleName Storage {$activeDirs}
        Mock Get-ActiveDirectories -ModuleName Bootstrap {$activeDirs}
    }
    AfterEach {
        if($crossRoot -notmatch '^D:\\GHUBSwitcher-Test-[a-f0-9]{32}$'){throw 'Invalid isolated test cleanup path.'}
        if(Test-Path -LiteralPath $crossRoot){Remove-Item -LiteralPath $crossRoot -Recurse -Force}
    }
    It 'switches C to D and back repeatedly, preserving the latest settings and empty directories' {
        $null=Invoke-DirectoryExchange $ctx modern legacy
        [IO.File]::WriteAllText((Join-Path $activeDirs.LocalData 'slot.txt'),'latest legacy configuration')
        $state=Read-SwitchState $ctx;$state.TransactionId='return';Write-SwitchState $ctx $state
        $null=Invoke-DirectoryExchange $ctx legacy modern
        [IO.File]::ReadAllText((Join-Path $activeDirs.LocalData 'slot.txt'))|Should -BeExactly modern
        Test-Path -LiteralPath (Join-Path $activeDirs.LocalData 'empty')|Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'Environments/legacy/LocalData/slot.txt'))|Should -BeExactly 'latest legacy configuration'
        $state.TransactionId='again';Write-SwitchState $ctx $state
        $null=Invoke-DirectoryExchange $ctx modern legacy
        [IO.File]::ReadAllText((Join-Path $activeDirs.LocalData 'slot.txt'))|Should -BeExactly 'latest legacy configuration'
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Directory -Filter '*.ghub-transfer-*').Count|Should -Be 0
    }
    It 'keeps the complete source when copying fails before any source rename' {
        Mock Copy-TransferTree -ModuleName Storage {throw 'fixture disk failure'}
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*disk failure*'
        $null=Undo-DirectoryExchange $ctx fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
    }
    It 'recovers an empty stage after interruption before its identity was recorded' {
        $script:identitySaveFailed=$false
        Mock Save-TransferReceipt -ModuleName Storage {
            param($Record)
            if($Record.StageIdentity -and -not $script:identitySaveFailed){$script:identitySaveFailed=$true;throw 'fixture stage identity interruption'}
            Write-AtomicJson (Join-Path $Record.Root ('State/Transfers/'+$Record.Id+'.json')) $Record
        }
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*identity interruption*'
        $null=Undo-DirectoryExchange $ctx fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
        @(Get-ChildItem -LiteralPath $ctx.Root -Recurse -Directory -Filter '*.ghub-transfer-*').Count|Should -Be 0
    }
    It 'restores the source when power fails just after its same-volume preservation rename' {
        $source=$activeDirs.Program
        Mock Move-TransferDirectory -ModuleName Storage {
            param($From,$To)
            [IO.Directory]::Move($From,$To)
            if($From -eq $source){throw 'fixture power loss after source rename'}
        }
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*power loss*'
        $null=Undo-DirectoryExchange $ctx fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
    }
    It 'recovers a promoted copy when deletion of the retained source stops halfway' {
        $script:deleteFailed=$false
        Mock Remove-TransferTree -ModuleName Storage {
            param($Path,$Identity)
            if(-not $script:deleteFailed){
                $script:deleteFailed=$true
                Remove-Item -LiteralPath (Join-Path $Path 'slot.txt') -Force
                throw 'fixture partial source deletion'
            }
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*partial source deletion*'
        Test-Path -LiteralPath $activeDirs.Program|Should -BeFalse
        $null=Undo-DirectoryExchange $ctx fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
    }
    It 'rejects corrupted staging content while keeping the source unchanged' {
        Mock Copy-TransferTree -ModuleName Storage {
            param($From,$To,$Trees)
            Copy-Item -LiteralPath (Join-Path $From 'slot.txt') -Destination (Join-Path $To 'slot.txt')
            [IO.File]::WriteAllText((Join-Path $To 'slot.txt'),'corrupt copy')
        }
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*verification*'
        $null=Undo-DirectoryExchange $ctx fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
    }
    It 'does not rename the source when the destination volume lacks space' {
        Mock Get-TransferFreeSpace -ModuleName Storage {0}
        {Invoke-DirectoryExchange $ctx modern legacy}|Should -Throw '*InsufficientSpace*'
        [IO.File]::ReadAllText((Join-Path $activeDirs.Program 'slot.txt'))|Should -BeExactly modern
    }
    It 'restores a full backup across volumes and retains the displaced current configuration' {
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=$activeDirs}
        [IO.File]::WriteAllText((Join-Path $activeDirs.LocalData 'slot.txt'),'latest displaced configuration')
        $null=Restore-BackupDirectories $ctx $backup fixture
        [IO.File]::ReadAllText((Join-Path $activeDirs.LocalData 'slot.txt'))|Should -BeExactly modern
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'Rescue/fixture/LocalData/slot.txt'))|Should -BeExactly 'latest displaced configuration'
    }
    It 'restores modern after first legacy capture with layout interruption <Interrupted> and keeps legacy selectable' -TestCases @(@{Interrupted=$false},@{Interrupted=$true}) {
        param($Interrupted)
        $backup=New-EnvironmentBackup $ctx @{Slot='modern';Directories=$activeDirs}
        foreach($role in $activeDirs.Keys){
            Remove-Item -LiteralPath (Join-Path $ctx.Root "Environments/legacy/$role") -Recurse -Force
            [IO.File]::WriteAllText((Join-Path $activeDirs[$role] 'slot.txt'),'legacy latest')
            $park=Join-Path $ctx.Root "Environments/modern/$role"
            [IO.Directory]::CreateDirectory((Split-Path $park -Parent))|Out-Null
            Copy-Item -LiteralPath (Join-Path $backup.Path $role) -Destination $park -Recurse
        }
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') @{RegistryRoots=@()}
        Mock Assert-Administrator -ModuleName Bootstrap {}
        Mock Get-GHUBInventory -ModuleName Bootstrap {@{ProductVersion='2021.3.5164'}}
        Mock New-EnvironmentManifest -ModuleName Bootstrap {[pscustomobject]@{Slot='legacy';ProductVersion='2021.3.5164';Directories=$activeDirs;RegistryValues=@();DriverPackages=@();Files=@();UpdatePolicy=@{}}}
        Mock Get-OwnedRegistryValues -ModuleName Bootstrap {@{Roots=@();Values=@()}}
        Mock Stop-GHUBEnvironment -ModuleName Bootstrap {}
        Mock Export-ManagedDrivers -ModuleName Bootstrap {@()}
        $legacy=Capture-CurrentEnvironment $ctx legacy -AutomaticUpdatesObservedOff -DeferRegistration
        Write-AtomicJson (Join-Path $ctx.Root 'Manifests/legacy.json') $legacy
        if($Interrupted){
            $script:layoutFailure=$false
            Mock Add-JournalEntry -ModuleName Bootstrap {
                param($Context,$TransactionId,$Kind,$StepId,$Before,$After)
                if($Kind -eq 'Done' -and $StepId -eq 'repair-layout-Program' -and -not $script:layoutFailure){$script:layoutFailure=$true;throw 'fixture layout interruption'}
                Core\Add-JournalEntry $Context $TransactionId $Kind $StepId $Before $After
            }
            {Restore-BackupDirectories $ctx $backup fixture}|Should -Throw '*layout interruption*'
        }
        $null=Restore-BackupDirectories $ctx $backup fixture
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'Environments/legacy/LocalData/slot.txt'))|Should -BeExactly 'legacy latest'
        $state=Read-SwitchState $ctx;$state.TransactionId='next';Write-SwitchState $ctx $state
        $null=Invoke-DirectoryExchange $ctx modern legacy
        [IO.File]::ReadAllText((Join-Path $activeDirs.LocalData 'slot.txt'))|Should -BeExactly 'legacy latest'
    }
}
