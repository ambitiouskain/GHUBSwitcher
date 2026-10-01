Describe 'Worker rejects a redirected filesystem before changing live state' {
    It 'rejects <Action> before dispatch, status writes, or recovery' -TestCases @(@{Action='Switch'},@{Action='BootResume'}) {
        param($Action)
        $worker=(Resolve-Path "$PSScriptRoot/../src/Invoke-GHUBWorker.ps1").Path
        $marker=Join-Path $TestDrive "$Action-mutation.txt"
        $harness=Join-Path $TestDrive "$Action-harness.ps1"
        $source=@'
param($Worker,$Action,$Marker)
$ErrorActionPreference='Stop'
function Import-Module {}
function Assert-Administrator {}
function Get-ObjectValue { $false }
function Test-Path { $false }
function Read-AtomicJson { [pscustomobject]@{OwnerSid='fixture';ProfileRoot='fixture'} }
function New-SwitchContext { [pscustomobject]@{Root='fixture'} }
function Assert-GHUBPhysicalDirectories { throw 'UnsafePath: redirected active LocalData directory.' }
function Read-SwitchState { [pscustomobject]@{Phase='PendingReboot';TransactionId=$null} }
function Get-ExternalRecoveryCheckpoint { $null }
function Invoke-GHUBSwitch { [IO.File]::WriteAllText($Marker,'switched');[pscustomobject]@{Status='Ok'} }
function Resume-GHUBTransaction { [IO.File]::WriteAllText($Marker,'resumed');[pscustomobject]@{Status='Ok'} }
function Write-AtomicJson { [IO.File]::WriteAllText($Marker,'status written') }
function Publish-SwitchStatus { [IO.File]::WriteAllText($Marker,'published') }
function New-OperationResult { [pscustomobject]@{Status='Blocked'} }
& $Worker -Action $Action
'@
        [IO.File]::WriteAllText($harness,$source)
        $shell="$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe"
        $savedPreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output=& $shell -NoProfile -ExecutionPolicy Bypass -File $harness -Worker $worker -Action $Action -Marker $marker 2>&1
            $code=$LASTEXITCODE
        } finally { $ErrorActionPreference=$savedPreference }
        Test-Path -LiteralPath $marker | Should -BeFalse -Because 'redirected execution must leave the transaction and status untouched'
        $code | Should -Not -Be 0
        ($output | Out-String) | Should -Match 'UnsafePath'
    }
}
Describe 'Worker maintenance dispatch and detached guard' {
    It 'routes <Action> with an update backup to complete backup recovery' -TestCases @(@{Action='BootResume'},@{Action='RestoreModern'}) {
        param($Action)
        $worker=(Resolve-Path "$PSScriptRoot/../src/Invoke-GHUBWorker.ps1").Path
        $marker=Join-Path $TestDrive "$Action-route.txt"
        $harness=Join-Path $TestDrive "$Action-route.ps1"
        $source=@'
param($Worker,$Action,$Marker,[switch]$Detached,[switch]$Detaching)
$ErrorActionPreference='Stop'
function Import-Module {}
function Assert-Administrator {}
function Assert-GHUBPhysicalDirectories {}
function Get-ObjectValue {param($Object,$Name,$Default) if($Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}}
function Read-AtomicJson { [pscustomobject]@{OwnerSid='fixture';ProfileRoot='fixture';Detached=[bool]$Detached} }
function New-SwitchContext { [pscustomobject]@{Root='fixture'} }
function Read-SwitchState { [pscustomobject]@{Phase=$(if($Detaching){'Detaching'}else{'RecoveryRequired'});TransactionId='fixture'} }
function Get-ExternalRecoveryCheckpoint { $null }
function Read-ValidJournal { [pscustomobject]@{Kind='Checkpoint';StepId='update-backup'} }
function Restore-ModernBackup { [IO.File]::WriteAllText($Marker,'backup-restored');[pscustomobject]@{Status='Ok'} }
function Remove-SwitcherControl { [IO.File]::WriteAllText($Marker,'detach-resumed');[pscustomobject]@{Status='Ok'} }
function Resume-GHUBTransaction { [IO.File]::WriteAllText($Marker,'ordinary-resume');[pscustomobject]@{Status='Ok'} }
function Restore-GHUBEnvironment { [IO.File]::WriteAllText($Marker,'ordinary-rollback');[pscustomobject]@{Status='Ok'} }
function Write-AtomicJson {}
function Publish-SwitchStatus {}
function New-OperationResult { [pscustomobject]@{Status='Blocked'} }
function Test-Path { $false }
& $Worker -Action $Action
'@
        [IO.File]::WriteAllText($harness,$source)
        $shell="$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe"
        & $shell -NoProfile -ExecutionPolicy Bypass -File $harness -Worker $worker -Action $Action -Marker $marker
        $LASTEXITCODE | Should -Be 0
        Get-Content -LiteralPath $marker | Should -Be 'backup-restored'
        $savedPreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output=& $shell -NoProfile -ExecutionPolicy Bypass -File $harness -Worker $worker -Action $Action -Marker ($marker+'.detached') -Detached 2>&1
        }finally{$ErrorActionPreference=$savedPreference}
        Test-Path -LiteralPath ($marker+'.detached') | Should -BeFalse
        if($Action -ne 'BootResume'){($output | Out-String) | Should -Match 'ControlRemoved'}
        & $shell -NoProfile -ExecutionPolicy Bypass -File $harness -Worker $worker -Action BootResume -Marker ($marker+'.detaching') -Detaching
        Get-Content -LiteralPath ($marker+'.detaching') | Should -Be 'detach-resumed'
    }
}
