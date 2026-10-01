BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    $path="$PSScriptRoot/../src/Modules/Storage.psm1"
    if (Test-Path $path) { Import-Module $path -Force -DisableNameChecking }
}
Describe 'Resolved filesystem paths before storage operations' {
    BeforeEach {
        $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $redirectedPath=''
        Mock Get-NativePathIdentity -ModuleName Storage {
            param($Path)
            $full=[IO.Path]::GetFullPath($Path)
            if ($full -ieq $redirectedPath) { $full+='-redirected' }
            [pscustomobject]@{FinalPath=('\\?\'+$full);VolumeSerial=17;FileId='fixture-id';IsReparsePoint=$false}
        }
    }
    It 'rejects a redirected directory before exchanging any environment folder' {
        $redirectedPath=Join-Path $ctx.Root 'active/LocalData'
        { Invoke-DirectoryExchange $ctx modern legacy } | Should -Throw '*UnsafePath*'
        foreach ($role in @('Program','LocalData','RoamingData','MachineData')) {
            Get-Content -LiteralPath (Join-Path $ctx.Root "active/$role/slot.txt") | Should -Be modern
            Get-Content -LiteralPath (Join-Path $ctx.Root "Environments/legacy/$role/slot.txt") | Should -Be legacy
        }
        @(Read-ValidJournal $ctx fixture | Where-Object Kind -EQ Intent).Count | Should -Be 0
    }
    It 'rejects a redirected tree root before capturing its files' {
        $redirectedPath=Join-Path $ctx.Root 'active/LocalData'
        { @(Get-TreeFiles $redirectedPath) } | Should -Throw '*UnsafePath*'
    }
    It 'rejects a redirected active directory in a read-only entry preflight' {
        $redirectedPath=Join-Path $ctx.Root 'active/LocalData'
        $before=Read-SwitchState $ctx | ConvertTo-Json -Compress
        { Assert-GHUBPhysicalDirectories $ctx } | Should -Throw '*UnsafePath*'
        (Read-SwitchState $ctx | ConvertTo-Json -Compress) | Should -BeExactly $before
        Get-Content -LiteralPath (Join-Path $redirectedPath 'slot.txt') | Should -Be modern
    }
    It 'rejects a redirected configuration child even when the containing directory is physical' {
        $redirectedPath=Join-Path $ctx.Root 'active/LocalData/slot.txt'
        $before=Read-SwitchState $ctx | ConvertTo-Json -Compress
        { Assert-GHUBPhysicalDirectories $ctx } | Should -Throw '*UnsafePath*'
        (Read-SwitchState $ctx | ConvertTo-Json -Compress) | Should -BeExactly $before
    }
    It 'allows missing active directories without recursive scans or hashing configuration contents' {
        $existing=Join-Path $ctx.Root 'active/LocalData'
        $missing=Join-Path $ctx.Root 'not-present'
        Mock Get-ActiveDirectories -ModuleName Storage { [ordered]@{LocalData=$existing;RoamingData=$missing} }
        Mock Get-ChildItem -ModuleName Storage {
            param($LiteralPath,[switch]$Recurse)
            if($Recurse){throw 'The entry preflight must not recursively scan configuration trees.'}
            Get-Item -LiteralPath (Join-Path $LiteralPath 'slot.txt')
        }
        Mock Get-FileHash -ModuleName Storage { throw 'The entry preflight must not hash configuration files.' }
        { Assert-GHUBPhysicalDirectories $ctx } | Should -Not -Throw
        Test-Path -LiteralPath $missing | Should -BeFalse
    }
    It 'rejects a redirected child before hashing its contents' {
        $root=Join-Path $ctx.Root 'active/LocalData'
        $redirectedPath=Join-Path $root 'slot.txt'
        Mock Get-FileHash -ModuleName Storage { throw 'File content was read before its path identity was verified.' }
        { @(Get-TreeFiles $root) } | Should -Throw '*UnsafePath*'
    }
    It 'accepts equivalent native DOS paths (prefix: <Prefix>, uppercase: <Uppercase>)' -TestCases @(
        @{Prefix='';Uppercase=$false},
        @{Prefix='\\?\';Uppercase=$false},
        @{Prefix='\\?\';Uppercase=$true}
    ) {
        param($Prefix,$Uppercase)
        Mock Get-NativePathIdentity -ModuleName Storage {
            param($Path)
            $full=[IO.Path]::GetFullPath($Path)
            if ($Uppercase) { $full=$full.ToUpperInvariant() }
            [pscustomobject]@{FinalPath=($Prefix+$full);VolumeSerial=17;FileId='fixture-id';IsReparsePoint=$false}
        }
        $root=Join-Path $ctx.Root 'active/LocalData'
        (Get-DirectoryIdentity $root).FileId | Should -Not -BeNullOrEmpty
        $files=@(Get-TreeFiles $root)
        $files.Count | Should -Be 1
        $files[0].Relative | Should -Be slot.txt
        $files[0].Sha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $root 'slot.txt')).Hash.ToLowerInvariant()
    }
}
Describe 'Recoverable environment directory exchange' {
    BeforeEach { $ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    It 'switches four independent folders and retains the previous data' {
        (Invoke-DirectoryExchange $ctx modern legacy).Status | Should -Be Ok
        foreach ($role in @('Program','LocalData','RoamingData','MachineData')) {
            Get-Content -LiteralPath (Join-Path $ctx.Root "active/$role/slot.txt") | Should -Be legacy
            Get-Content -LiteralPath (Join-Path $ctx.Root "Environments/modern/$role/slot.txt") | Should -Be modern
        }
    }
    It 'recovers even when a rename happened before its completion log' {
        Mock Move-ManagedDirectory -ModuleName Storage {
            param($From,$To)
            [IO.Directory]::Move($From,$To)
            if ($From -like '*active*LocalData') { throw 'simulated power loss' }
        }
        { Invoke-DirectoryExchange $ctx modern legacy } | Should -Throw '*power loss*'
        (Undo-DirectoryExchange $ctx fixture).Status | Should -Be Ok
        foreach ($role in @('Program','LocalData','RoamingData','MachineData')) {
            Get-Content -LiteralPath (Join-Path $ctx.Root "active/$role/slot.txt") | Should -Be modern
        }
    }
    It 'does not overwrite an unexpected directory in a parked source slot' {
        [IO.Directory]::CreateDirectory((Join-Path $ctx.Root 'Environments/modern/Program')) | Out-Null
        { Invoke-DirectoryExchange $ctx modern legacy } | Should -Throw '*UnsafePath*'
        Get-Content (Join-Path $ctx.Root 'active/Program/slot.txt') | Should -Be modern
    }
    It 'recovers a reconciled physical user directory (interrupted after rename: <Interrupted>)' -TestCases @(@{Interrupted=$false},@{Interrupted=$true}) {
        param($Interrupted)
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $entry=@(Read-ValidJournal $ctx fixture | Where-Object { $_.Kind -eq 'Intent' -and $_.Before.Role -eq 'LocalData' -and $_.Before.To -like '*active*' })[0]
        $move=$entry.Before
        [IO.Directory]::Move($move.To,(Join-Path $ctx.Root 'retained-cache-directory'))
        [IO.Directory]::CreateDirectory($move.To) | Out-Null
        [IO.File]::WriteAllText((Join-Path $move.To 'slot.txt'),'legacy-physical')
        $change=[pscustomobject]@{StepId=$entry.StepId;Role=$move.Role;From=$move.From;To=$move.To;OriginalIdentity=$move.Identity;PhysicalIdentity=(Get-DirectoryIdentity $move.To)}
        Add-JournalEntry $ctx fixture Checkpoint physical-directory-identities $null @{TransactionId='fixture';Reason='AppPackageRedirection';Changes=@($change)}
        if($Interrupted){
            Add-JournalEntry $ctx fixture Intent ('undo-'+$entry.StepId) $move $null
            [IO.Directory]::Move($move.To,$move.From)
        }
        (Undo-DirectoryExchange $ctx fixture).Status | Should -Be Ok
        Get-Content -LiteralPath (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be modern
        Get-Content -LiteralPath (Join-Path $ctx.Root 'Environments/legacy/LocalData/slot.txt') | Should -Be legacy-physical
        Test-Path -LiteralPath (Join-Path $ctx.Root 'retained-cache-directory/slot.txt') | Should -BeTrue
    }
    It 'rejects a reconciliation whose original identity does not match the immutable move record' {
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $entry=@(Read-ValidJournal $ctx fixture | Where-Object { $_.Kind -eq 'Intent' -and $_.Before.Role -eq 'LocalData' -and $_.Before.To -like '*active*' })[0]
        $move=$entry.Before
        $change=[pscustomobject]@{StepId=$entry.StepId;Role=$move.Role;From=$move.From;To=$move.To;OriginalIdentity=@{VolumeSerial=0;FileId='wrong'};PhysicalIdentity=(Get-DirectoryIdentity $move.To)}
        Add-JournalEntry $ctx fixture Checkpoint physical-directory-identities $null @{TransactionId='fixture';Reason='AppPackageRedirection';Changes=@($change)}
        { Undo-DirectoryExchange $ctx fixture } | Should -Throw '*RecoveryRequired*'
        Get-Content -LiteralPath (Join-Path $ctx.Root 'active/LocalData/slot.txt') | Should -Be legacy
        @(Read-ValidJournal $ctx fixture | Where-Object StepId -Like 'undo-*').Count | Should -Be 0
    }
    It 'rejects a prefix lookalike and traversal path' {
        { Test-ManagedPath $ctx ($ctx.Root+'-other/Program') Program } | Should -Throw '*UnsafePath*'
        { Test-ManagedPath $ctx (Join-Path $ctx.Root '../outside') Program } | Should -Throw '*UnsafePath*'
    }
    It 'refuses a junction before touching its target' {
        $target=Join-Path $TestDrive 'outside'; [IO.Directory]::CreateDirectory($target) | Out-Null
        $link=Join-Path $ctx.Root 'junction'; New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        { Assert-NoReparsePoint (Join-Path $link 'file') } | Should -Throw '*UnsafePath*'
    }
    It 'detects backup corruption rather than restoring it' {
        $manifest=[pscustomobject]@{Slot='modern';Directories=(Get-ActiveDirectories $ctx)}
        $backup=New-EnvironmentBackup $ctx $manifest
        Test-EnvironmentBackup $ctx $backup | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $backup.Path 'Program/slot.txt'),'tampered')
        Test-EnvironmentBackup $ctx $backup | Should -BeFalse
    }
}
