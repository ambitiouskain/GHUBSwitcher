BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Storage.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    if(-not('DirectoryLockFixture' -as [type])){Add-Type -Path "$PSScriptRoot/DirectoryLockFixture.cs"}
}
Describe 'Directory moves while Windows holds a temporary directory handle' {
    BeforeEach {$ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))}
    It 'waits for a real sharing lock to release and preserves the latest configuration' {
        $from=Join-Path $ctx.Root 'active/LocalData'
        $to=Join-Path $ctx.Root 'Environments/modern/LocalData'
        [IO.Directory]::CreateDirectory((Split-Path $to -Parent))|Out-Null
        [IO.File]::WriteAllText((Join-Path $from 'slot.txt'),'latest-modern-settings')
        $thread=[DirectoryLockFixture]::HoldBriefly($from,700)
        try {Move-ManagedDirectory $from $to} finally {$thread.Join()}
        Test-Path -LiteralPath $from|Should -BeFalse
        Get-Content -LiteralPath (Join-Path $to 'slot.txt')|Should -Be latest-modern-settings
    }
    It 'also retries the same-volume preservation move used inside a cross-volume transfer' {
        $from=Join-Path $ctx.Root 'active/LocalData'
        $to=$from+'.ghub-transfer-'+[guid]::NewGuid().ToString('N')
        $thread=[DirectoryLockFixture]::HoldBriefly($from,700)
        try {Move-TransferDirectory $from $to} finally {$thread.Join()}
        Test-Path -LiteralPath $from|Should -BeFalse
        Get-Content -LiteralPath (Join-Path $to 'slot.txt')|Should -Be modern
    }
    It 'also waits during journal rollback and restores the original directory identities' {
        $original=Get-DirectoryIdentity (Join-Path $ctx.Root 'active/LocalData')
        $null=Invoke-DirectoryExchange $ctx modern legacy
        $thread=[DirectoryLockFixture]::HoldBriefly((Join-Path $ctx.Root 'active/LocalData'),700)
        try {(Undo-DirectoryExchange $ctx fixture).Status|Should -Be Ok} finally {$thread.Join()}
        Test-SameDirectoryIdentity (Join-Path $ctx.Root 'active/LocalData') $original|Should -BeTrue
        Get-Content -LiteralPath (Join-Path $ctx.Root 'active/LocalData/slot.txt')|Should -Be modern
        Get-Content -LiteralPath (Join-Path $ctx.Root 'Environments/legacy/LocalData/slot.txt')|Should -Be legacy
    }
    It 'stops waiting after its deadline and leaves locked configuration intact' {
        $from=Join-Path $ctx.Root 'active/LocalData'
        $to=Join-Path $ctx.Root 'Environments/modern/LocalData'
        [IO.Directory]::CreateDirectory((Split-Path $to -Parent))|Out-Null
        $handle=[DirectoryLockFixture]::Hold($from)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try {{Move-ManagedDirectory $from $to -RetryTimeoutMilliseconds 250}|Should -Throw} finally {$handle.Dispose()}
        $timer.ElapsedMilliseconds|Should -BeGreaterOrEqual 200
        $timer.ElapsedMilliseconds|Should -BeLessThan 2000
        Get-Content -LiteralPath (Join-Path $from 'slot.txt')|Should -Be modern
        Test-Path -LiteralPath $to|Should -BeFalse
    }
    It 'does not overwrite a directory that already exists at the destination' {
        $from=Join-Path $ctx.Root 'active/LocalData'
        $to=Join-Path $ctx.Root 'Environments/legacy/LocalData'
        {Move-ManagedDirectory $from $to}|Should -Throw
        Get-Content -LiteralPath (Join-Path $from 'slot.txt')|Should -Be modern
        Get-Content -LiteralPath (Join-Path $to 'slot.txt')|Should -Be legacy
    }
}
