BeforeAll {
    $module = Join-Path $PSScriptRoot '../src/Modules/Core.psm1'
    if (Test-Path $module) { Import-Module $module -Force }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
Describe 'Durable transaction core' {
    BeforeEach { $ctx = New-SwitchContext -Root (Join-Path $TestDrive ([guid]::NewGuid())) -OwnerSid $sid -ProfileRoot $TestDrive -Mode Simulation }
    It 'rejects skipping quiescence' {
        $state = New-SwitchState -Context $ctx -Active modern -BootId boot-a
        { Set-SwitchPhase -State $state -NextPhase Binding } | Should -Throw '*InvalidTransition*'
    }
    It 'can suspend a vendor update for its required reboot' {
        $state=New-SwitchState $ctx modern boot-a
        $state=Set-SwitchPhase $state Maintenance
        (Set-SwitchPhase $state PendingReboot).Phase | Should -Be PendingReboot
    }
    It 'persists state without silently accepting corrupt payloads' {
        $state = New-SwitchState -Context $ctx -Active modern -BootId boot-a
        Write-SwitchState $ctx $state
        (Read-SwitchState $ctx).Active | Should -Be modern
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'State/state.json'), '{"Payload":"AAAA","Sha256":"wrong"}')
        { Read-SwitchState $ctx } | Should -Throw '*IntegrityError*'
    }
    It 'rejects an unknown schema and owner' {
        $state = New-SwitchState $ctx modern boot-a
        $state.SchemaVersion = 2
        { Write-SwitchState $ctx $state } | Should -Throw '*InvalidManifest*'
        $state.SchemaVersion = 1; $state.OwnerSid = 'S-1-5-18'
        { Write-SwitchState $ctx $state } | Should -Throw '*OwnerMismatch*'
    }
    It 'does not allow two workers to hold the lock' {
        $lease = Enter-SwitchLock $ctx
        try { { Enter-SwitchLock $ctx } | Should -Throw '*Busy*' } finally { $lease.Dispose() }
        $next = Enter-SwitchLock $ctx; $next.Dispose()
    }
    It 'validates journal continuity and tolerates only an uncommitted final fragment' {
        Add-JournalEntry $ctx fixture Intent move-1 @{From='a'} @{To='b'}
        Add-JournalEntry $ctx fixture Done move-1 @{From='a'} @{To='b'}
        $path = Join-Path $ctx.Root 'Transactions/fixture.jsonl'
        [IO.File]::AppendAllText($path, '{"incomplete":')
        @(Read-ValidJournal $ctx fixture).Count | Should -Be 2
        [IO.File]::AppendAllText($path, "`n")
        { Read-ValidJournal $ctx fixture } | Should -Throw '*IntegrityError*'
    }
    It 'rejects a corrupted complete journal line' {
        Add-JournalEntry $ctx fixture Intent move-1 @{} @{}
        $path = Join-Path $ctx.Root 'Transactions/fixture.jsonl'
        [IO.File]::WriteAllText($path, "{}`n")
        { Read-ValidJournal $ctx fixture } | Should -Throw '*IntegrityError*'
    }
    It 'rejects invalid transaction path input' {
        { Add-JournalEntry $ctx '../escape' Intent step @{} @{} } | Should -Throw '*InvalidManifest*'
    }
    It 'keeps the previous good state when atomically replacing it' {
        $state = New-SwitchState $ctx modern boot-a
        Write-SwitchState $ctx $state
        $next = Set-SwitchPhase $state Preparing
        Write-SwitchState $ctx $next
        (Read-SwitchState $ctx).Phase | Should -Be Preparing
        (Read-AtomicJson (Join-Path $ctx.Root 'State/state.json.bak')).Phase | Should -Be Idle
    }
}
