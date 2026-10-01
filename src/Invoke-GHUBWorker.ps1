param([Parameter(Mandatory=$true)][ValidateSet('Switch','RestoreModern','BootResume','Monitor','Initialize','PrepareLegacy','MaintainModern','RemoveControl')][string]$Action,[ValidateSet('modern','legacy')][string]$TargetSlot='modern')
$ErrorActionPreference='Stop'
foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator','Bootstrap')){Import-Module (Join-Path $PSScriptRoot "Modules/$name.psm1") -DisableNameChecking}
$root=Join-Path $env:ProgramData 'GHUBSwitcher'
Assert-Administrator
$registration=Read-AtomicJson (Join-Path $root 'registration.json')
if(Get-ObjectValue $registration Detached $false){
    if($Action -in @('BootResume','Monitor')){exit 0}
    throw 'ControlRemoved: 切换器已退出管理，请先重新部署后再使用切换功能。'
}
$ctx=New-SwitchContext $root $registration.OwnerSid $registration.ProfileRoot -Mode Live
# Reject redirected app-package views before dispatch or writing transaction/status data.
Assert-GHUBPhysicalDirectories $ctx
try{
    switch($Action){
        Switch {$result=Invoke-GHUBSwitch $ctx $TargetSlot}
        Initialize {
            Write-Host '请先在当前新版 G HUB 设置中关闭自动更新，并准备好独立键盘。准备过程会停止 G HUB。'
            if((Read-Host '确认后输入 AUTO-OFF') -cne 'AUTO-OFF'){throw 'UpdatePolicyUnverified: preparation cancelled.'}
            $result=Initialize-GHUBSwitcher $ctx $registration.LegacyInstallerPath -AutomaticUpdatesObservedOff
        }
        PrepareLegacy {$result=Capture-LegacyEnvironment $ctx $registration.LegacyInstallerPath}
        RestoreModern {
            $state=Read-SwitchState $ctx
            if($state.Phase -eq 'Detaching'){$result=Remove-SwitcherControl $ctx}
            elseif(Get-ExternalRecoveryCheckpoint $ctx $state){$result=Resume-ExternalModernRecovery $ctx}
            elseif($state.Phase -eq 'PendingReboot'){$result=Resume-GHUBTransaction $ctx}
            elseif($state.Phase -eq 'Idle'){$result=Invoke-GHUBSwitch $ctx modern}
            else{
                $maintenance=@(Read-ValidJournal $ctx $state.TransactionId|Where-Object {$_.StepId -in @('bootstrap-backup','update-backup')})
                if($maintenance.Count){$result=Restore-ModernBackup $ctx}else{$result=Restore-GHUBEnvironment $ctx modern}
            }
        }
        BootResume {
            $state=Read-SwitchState $ctx
            $bootstrap=@();if($state.TransactionId){$bootstrap=@(Read-ValidJournal $ctx $state.TransactionId|Where-Object {$_.StepId -in @('bootstrap-backup','update-backup')})}
            if($state.Phase -eq 'Detaching'){$result=Remove-SwitcherControl $ctx}
            elseif(Get-ExternalRecoveryCheckpoint $ctx $state){$result=Resume-ExternalModernRecovery $ctx}
            elseif($bootstrap.Count -and $state.Phase -notin @('Idle','PendingReboot','AwaitingLogon')){$result=Restore-ModernBackup $ctx}else{$result=Resume-GHUBTransaction $ctx}
        }
        Monitor {Watch-GHUBEnvironment $ctx;return}
        MaintainModern {$result=Maintain-ModernEnvironment $ctx}
        RemoveControl {$result=Remove-SwitcherControl $ctx}
    }
    Write-AtomicJson (Join-Path $root 'Status/last-result.json') $result
    Write-AtomicJson (Join-Path $root 'Status/environments.json') @{ModernReady=(Test-Path -LiteralPath (Join-Path $root 'Manifests/modern.json'));LegacyReady=(Test-Path -LiteralPath (Join-Path $root 'Manifests/legacy.json'))}
    if($Action -in @('Initialize','PrepareLegacy','MaintainModern')){Write-Host $result.Message;Read-Host '按 Enter 关闭此窗口'|Out-Null}
    if($result.Status -eq 'AwaitingLogon'){exit 1}
    if($result.Status -in @('RecoveryRequired','Blocked') -and $Action -ne 'BootResume'){exit 1}
}catch{
    $message=$_.Exception.Message
    Write-AtomicJson (Join-Path $root 'Status/last-result.json') (New-OperationResult Blocked OperationFailed $message)
    if(Test-Path -LiteralPath (Join-Path $root 'State/state.json')){$state=Read-SwitchState $ctx;$state.LastError=$message;Publish-SwitchStatus $ctx $state $message}
    if($Action -in @('Initialize','PrepareLegacy','MaintainModern')){Write-Host ('操作失败：'+$message);Read-Host '按 Enter 关闭此窗口'|Out-Null}
    if($Action -eq 'BootResume'){exit 0}else{exit 1}
}
