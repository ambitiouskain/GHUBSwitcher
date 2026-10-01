Set-StrictMode -Version Latest
foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator','InstallerAudit','ExternalRecovery')) {Import-Module (Join-Path $PSScriptRoot "$name.psm1") -DisableNameChecking}

function Assert-LegacyPreparation {param([bool]$BackupValid,[bool]$SignatureValid,[string]$InstallerVersion)
    if(-not $BackupValid){Throw-SwitchError BackupInvalid 'A verified modern backup is required.'}
    if(-not $SignatureValid){Throw-SwitchError InvalidSignature 'The installer must have a valid Logitech signature.'}
    if($InstallerVersion -notmatch '^2021\.3([.]|$)'){Throw-SwitchError InstallerVersionMismatch 'Expected the 2021.3 installer.'}
}
function Invoke-PreservedMoves {param($Context,[string]$TransactionId,[string]$Name,[object[]]$Moves)
    Repair-JournalTail $Context $TransactionId
    $saved=@(Read-ValidJournal $Context $TransactionId | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq $Name})
    if($saved.Count -gt 1){Throw-SwitchError RecoveryRequired 'Ambiguous preservation plan.'}
    if($saved.Count){$Moves=@($saved[0].After)}else{Add-JournalEntry $Context $TransactionId Checkpoint $Name $null @($Moves)}
    foreach($move in $Moves){
        foreach($path in @($move.From,$move.To)){
            $full=Assert-NoReparsePoint $path
            if(-not $full.StartsWith($Context.Root+'\',[StringComparison]::OrdinalIgnoreCase)){$null=Test-ManagedPath $Context $full $move.Role}
        }
        Resolve-InterruptedTransfer $Context $move.From $move.To $move.Identity -Rollback
        if(Test-SameDirectoryIdentity $move.To $move.Identity){continue}
        if((Test-Path -LiteralPath $move.To) -or -not (Test-SameDirectoryIdentity $move.From $move.Identity)){Throw-SwitchError RecoveryRequired 'Preserved directory identity changed.'}
        [IO.Directory]::CreateDirectory((Split-Path $move.To -Parent))|Out-Null
        Add-JournalEntry $Context $TransactionId Intent ($Name+'-'+$move.Role) $move $null
        Move-ManagedDirectory $move.From $move.To -Context $Context -Role $move.Role
        Add-JournalEntry $Context $TransactionId Done ($Name+'-'+$move.Role) $move $null
    }
}
function Initialize-LegacyDataRoots {param($Context,[string]$TransactionId)
    $dirs=Get-ActiveDirectories $Context; $moves=@()
    $saved=@(Read-ValidJournal $Context $TransactionId|Where-Object {$_.StepId -eq 'isolate-data' -and $_.Kind -eq 'Checkpoint'})
    if(-not $saved.Count){
        foreach($role in @('LocalData','RoamingData','MachineData')){
            $path=Test-ManagedPath $Context $dirs[$role] $role
            if(Test-Path -LiteralPath $path){$moves+=[pscustomobject]@{Role=$role;From=$path;To=(Join-Path $Context.Root "Rescue/$TransactionId/pre-legacy/$role");Identity=(Get-DirectoryIdentity $path -Context $Context)}}
        }
    }
    Invoke-PreservedMoves $Context $TransactionId 'isolate-data' $moves
    foreach($role in @('LocalData','RoamingData','MachineData')){
        $path=Test-ManagedPath $Context $dirs[$role] $role
        [IO.Directory]::CreateDirectory($path)|Out-Null
        if(@(Get-ChildItem -LiteralPath $path -Force).Count){Throw-SwitchError ExternalChange 'Legacy data root is not empty; refusing to launch installer.'}
    }
}
function Repair-BackupSlotLayout {param($Context,$Backup,[string]$TransactionId,$RestoreMoves)
    $moves=@(); $other=if($Backup.Slot -eq 'modern'){'legacy'}else{'modern'}
    $journal=@(Read-ValidJournal $Context $TransactionId)
    if(-not @($journal|Where-Object {$_.StepId -eq 'repair-layout' -and $_.Kind -eq 'Checkpoint'}).Count){
        foreach($restore in $RestoreMoves){
            $role=$restore.Role
            $park=Test-ManagedPath $Context (Join-Path $Context.Root "Environments/$($Backup.Slot)/$role") $role
            if(Test-Path -LiteralPath $park){$moves+=[pscustomobject]@{Role=$role;From=$park;To=(Join-Path $Context.Root "Rescue/$TransactionId/parked-$($Backup.Slot)/$role");Identity=(Get-DirectoryIdentity $park -Context $Context)}}
            $otherPark=Test-ManagedPath $Context (Join-Path $Context.Root "Environments/$other/$role") $role
            if(Test-Path -LiteralPath $otherPark){continue}
            $proof=@($journal|Where-Object {$_.Kind -eq 'Intent' -and $_.StepId -like 'directory-*' -and $_.Before.From -ieq $otherPark})
            $identity=$null
            if($proof.Count){$identity=$proof[0].Before.Identity}
            $manifestPath=Join-Path $Context.Root "Manifests/$other.json"
            if(-not $identity -and (Test-Path -LiteralPath $manifestPath)){
                $manifest=Read-AtomicJson $manifestPath
                $identity=Get-ObjectValue (Get-ObjectValue $manifest DirectoryIdentities $null) $role $null
            }
            if($identity -and (Test-SameDirectoryIdentity $restore.Archive $identity)){
                $moves+=[pscustomobject]@{Role=$role;From=$restore.Archive;To=$otherPark;Identity=(Get-DirectoryIdentity $restore.Archive -Context $Context)}
            }elseif(Test-Path -LiteralPath $manifestPath){Throw-SwitchError RecoveryRequired 'Registered inactive slot cannot be identified. Preserved files require inspection.'}
        }
    }
    Invoke-PreservedMoves $Context $TransactionId 'repair-layout' $moves
    foreach($role in (Get-ActiveDirectories $Context).Keys){
        if(Test-Path -LiteralPath (Join-Path $Context.Root "Environments/$($Backup.Slot)/$role")){Throw-SwitchError RecoveryRequired 'Active slot is still parked.'}
    }
}
function Restore-BackupDirectories {param($Context,$Backup,[string]$TransactionId)
    if($Context.Mode -eq 'Live'){Assert-Administrator}
    if(-not (Test-EnvironmentBackup $Context $Backup)){Throw-SwitchError BackupInvalid 'Backup integrity check failed.'}
    Repair-JournalTail $Context $TransactionId
    $existing=@(Read-ValidJournal $Context $TransactionId | Where-Object {$_.StepId -eq 'restore-plan' -and $_.Kind -eq 'Checkpoint'})
    if($existing.Count -gt 1){Throw-SwitchError RecoveryRequired 'Ambiguous restoration plan.'}
    if($existing.Count){$moves=@($existing[0].After)}else{
        $dirs=Get-ActiveDirectories $Context;$moves=@()
        foreach($role in $dirs.Keys){
            $stage=Join-Path $Context.Root "RestoreStage/$TransactionId/$role";$archive=Join-Path $Context.Root "Rescue/$TransactionId/$role"
            $null=Assert-NoReparsePoint $stage;$null=Assert-NoReparsePoint $archive
            if((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $archive)){Throw-SwitchError RecoveryRequired 'Unexpected staging directory.'}
            [IO.Directory]::CreateDirectory((Split-Path $stage -Parent))|Out-Null
            Copy-Item -LiteralPath (Join-Path $Backup.Path $role) -Destination $stage -Recurse -Force
            $identity=$null;if(Test-Path -LiteralPath $dirs[$role]){$identity=Get-DirectoryIdentity $dirs[$role] -Context $Context}
            $moves+=[pscustomobject]@{Role=$role;Active=$dirs[$role];Stage=$stage;Archive=$archive;OldIdentity=$identity;NewIdentity=(Get-DirectoryIdentity $stage -Context $Context)}
        }
        Add-JournalEntry $Context $TransactionId Checkpoint restore-plan $null $moves
    }
    foreach($move in $moves){
        $null=Test-ManagedPath $Context $move.Active $move.Role
        foreach($path in @($move.Stage,$move.Archive)){
            $full=Assert-NoReparsePoint $path
            if(-not $full.StartsWith($Context.Root+'\',[StringComparison]::OrdinalIgnoreCase)){Throw-SwitchError UnsafePath 'Restore staging path escaped the protected root.'}
        }
        Resolve-InterruptedTransfer $Context $move.Active $move.Archive $move.OldIdentity -Rollback
        Resolve-InterruptedTransfer $Context $move.Stage $move.Active $move.NewIdentity -Rollback
        if(Test-SameDirectoryIdentity $move.Active $move.NewIdentity){continue}
        if(Test-Path -LiteralPath $move.Active){
            if(-not $move.OldIdentity -or -not (Test-SameDirectoryIdentity $move.Active $move.OldIdentity)){Throw-SwitchError RecoveryRequired 'Active directory identity changed during restore.'}
            [IO.Directory]::CreateDirectory((Split-Path $move.Archive -Parent))|Out-Null
            Add-JournalEntry $Context $TransactionId Intent ('restore-archive-'+$move.Role) $move $null
            Move-ManagedDirectory $move.Active $move.Archive -Context $Context -Role $move.Role
            Add-JournalEntry $Context $TransactionId Done ('restore-archive-'+$move.Role) $move $null
        }
        if(-not (Test-SameDirectoryIdentity $move.Stage $move.NewIdentity)){Throw-SwitchError RecoveryRequired 'Restore staging identity changed.'}
        Add-JournalEntry $Context $TransactionId Intent ('restore-active-'+$move.Role) $move $null
        Move-ManagedDirectory $move.Stage $move.Active -Context $Context -Role $move.Role
        Add-JournalEntry $Context $TransactionId Done ('restore-active-'+$move.Role) $move $null
    }
    Restore-EnvironmentAcl $Context $Backup.Trees
    Repair-BackupSlotLayout $Context $Backup $TransactionId $moves
    New-OperationResult
}
function Get-OwnedRegistryValues {param($Context)
    Get-GHUBRegistryValues $Context
}
function Register-Environment {param($Context,$Manifest)
    if($Manifest.OwnerSid -ne $Context.OwnerSid){Throw-SwitchError OwnerMismatch 'Invalid manifest owner.'}
    $external=Get-ObjectValue $Manifest ExternalRecoveryEvidence $null
    if($external){
        if($Manifest.Slot -ne 'modern' -or (Get-ObjectValue $Manifest InstallerEvidence $null)){Throw-SwitchError ExternalRecoveryInvalid 'External recovery is only valid for modern and cannot replace or be combined with installer evidence.'}
        $null=Test-ExternalRecoveryEvidence $Context $external $Manifest
    }
    if(-not $external -and ($Manifest.Slot -eq 'legacy' -or (Test-Path -LiteralPath (Join-Path $Context.Root "Manifests/$($Manifest.Slot).json")))){
        $evidence=Get-ObjectValue $Manifest InstallerEvidence $null
        if(-not $evidence -or -not $evidence.Passed -or $evidence.ProductVersion -ne $Manifest.ProductVersion){Throw-SwitchError UnclassifiedInstallerChange 'A matching installer change report is required before registration.'}
        $path=Assert-NoReparsePoint $evidence.Path
        if(-not $path.StartsWith((Join-Path $Context.Root 'Transactions')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $evidence.Sha256){Throw-SwitchError UnclassifiedInstallerChange 'Invalid installer report identity.'}
        $report=Read-AtomicJson $path
        if(-not $report.Passed -or $report.OwnerSid -ne $Context.OwnerSid -or $report.ProductVersion -ne $Manifest.ProductVersion){Throw-SwitchError UnclassifiedInstallerChange 'Installer report does not authorize this capture.'}
        $validationMode=Get-ObjectValue $report ValidationMode 'Automatic'
        if($validationMode -eq 'ManualReview'){
            try{
                $reviewed=Test-ReviewedInstallerEvidence $Context $evidence $Manifest
                if(-not $reviewed){throw 'Review evidence validation failed.'}
            }catch{Throw-SwitchError UnclassifiedInstallerChange ('Installer review evidence is invalid: '+$_.Exception.Message)}
        }elseif($validationMode -ne 'Automatic'){Throw-SwitchError UnclassifiedInstallerChange 'Unknown installer validation mode.'}
    }
    if((Test-UpdatePolicy $Context $Manifest).Status -ne 'Ok'){Throw-SwitchError UpdatePolicyUnverified 'Automatic update setting needs a recorded observation.'}
    if(-not (Test-InstallationConfigurationMode $Context)){foreach($package in $Manifest.DriverPackages){Assert-DriverPackage $Context $package}}
    if(-not (Get-ObjectValue $Manifest BackupPath '')){Throw-SwitchError BackupInvalid 'Missing recovery backup.'}
    if(-not (Test-EnvironmentBackup $Context @{Path=$Manifest.BackupPath})){Throw-SwitchError BackupInvalid 'Recovery backup is not valid.'}
    $Manifest.Qualification='Prepared'
    Write-AtomicJson (Join-Path $Context.Root "Manifests/$($Manifest.Slot).json") $Manifest
}
function Capture-CurrentEnvironment {param($Context,[string]$Slot,[switch]$AutomaticUpdatesObservedOff,[switch]$DeferRegistration)
    Assert-Administrator
    if(-not $AutomaticUpdatesObservedOff){Throw-SwitchError UpdatePolicyUnverified 'Confirm the setting in the actual G HUB interface first.'}
    Write-Host '正在读取 G HUB 程序、设备与服务信息，请稍候。'
    $inventory=Get-GHUBInventory $Context -CaptureDrivers
    if($Slot -eq 'legacy' -and $inventory.ProductVersion -notmatch '^2021\.3([.]|$)'){Throw-SwitchError InstallerVersionMismatch 'Installed application is not G HUB 2021.3.'}
    $manifest=New-EnvironmentManifest $Context $Slot $inventory
    $registry=Get-OwnedRegistryValues $Context;$manifest.RegistryValues=$registry.Values
    $registration=Read-AtomicJson (Join-Path $Context.Root 'registration.json')
    $registration.RegistryRoots=@(@($registration.RegistryRoots)+@($registry.Roots)|Sort-Object -Unique)
    Write-AtomicJson (Join-Path $Context.Root 'registration.json') $registration
    Write-AtomicJson (Join-Path $Context.Root "State/pre-capture-$Slot.json") $manifest
    if($Slot -eq 'modern' -and -not (Test-Path -LiteralPath (Join-Path $Context.Root 'State/original-control.json'))){Write-AtomicJson (Join-Path $Context.Root 'State/original-control.json') $manifest}
    Write-Host '正在停止 G HUB，以保存一致的配置备份。'
    $null=Stop-GHUBEnvironment $Context $manifest
    # Refresh final registry data after writers exit while retaining pre-stop service/startup settings.
    $registry=Get-OwnedRegistryValues $Context;$manifest.RegistryValues=$registry.Values
    $registration.RegistryRoots=@(@($registration.RegistryRoots)+@($registry.Roots)|Sort-Object -Unique)
    Write-AtomicJson (Join-Path $Context.Root 'registration.json') $registration
    Write-AtomicJson (Join-Path $Context.Root "State/pre-capture-$Slot.json") $manifest
    foreach($path in (Get-ActiveDirectories $Context).Values){if(-not (Test-Path -LiteralPath $path)){[IO.Directory]::CreateDirectory($path)|Out-Null}}
    Write-Host '正在导出驱动恢复包并校验程序文件。'
    $manifest.DriverPackages=@(Export-ManagedDrivers $Context $manifest)
    $manifest.Files=@(Get-TreeFiles $manifest.Directories.Program | Where-Object {-not $_.IsDirectory})
    $identities=[ordered]@{};foreach($role in (Get-ActiveDirectories $Context).Keys){$identities[$role]=Get-DirectoryIdentity $manifest.Directories[$role] -Context $Context}
    $manifest|Add-Member -NotePropertyName DirectoryIdentities -NotePropertyValue $identities -Force
    $manifest.UpdatePolicy=[pscustomobject]@{Verified=$true;ProductVersion=$manifest.ProductVersion;Method='ObservedUI';Evidence=@([pscustomobject]@{ObserverSid=$Context.OwnerSid;ObservedUtc=[DateTime]::UtcNow.ToString('o');Statement='User observed automatic updates disabled in this version; setting schema not modified by switcher.'})}
    Write-Host '正在复制并校验程序和配置备份；耗时取决于数据量。'
    $backup=New-EnvironmentBackup $Context $manifest
    $manifest|Add-Member -NotePropertyName Acls -NotePropertyValue $backup.Trees -Force
    $manifest|Add-Member -NotePropertyName BackupPath -NotePropertyValue $backup.Path -Force
    if(-not $DeferRegistration){Register-Environment $Context $manifest}
    return $manifest
}
function Initialize-GHUBSwitcher {param($Context,[string]$LegacyInstallerPath,[switch]$AutomaticUpdatesObservedOff)
    Assert-Administrator
    $lease=Enter-SwitchLock $Context
    try{
        Assert-PortableInstance $Context
        if(Test-Path -LiteralPath (Join-Path $Context.Root 'Manifests/modern.json')){Throw-SwitchError AlreadyInitialized 'Modern environment already registered.'}
        $installer=Get-Item -LiteralPath $LegacyInstallerPath
        $signature=Get-AuthenticodeSignature -LiteralPath $installer.FullName
        Assert-LegacyPreparation $true ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Logitech Inc') $installer.VersionInfo.FileVersion
        $manifest=Capture-CurrentEnvironment $Context modern -AutomaticUpdatesObservedOff:$AutomaticUpdatesObservedOff
        $state=New-SwitchState $Context modern (Get-BootId);Write-SwitchState $Context $state
        $null=Install-StartupControl $Context $manifest
        Publish-SwitchStatus $Context $state 'Modern backup prepared. Legacy environment is not installed yet.'
    }finally{$lease.Dispose()}
    Invoke-GHUBSwitch $Context modern
}
function Capture-LegacyEnvironment {param($Context,[string]$LegacyInstallerPath)
    Assert-Administrator
    $state=Read-SwitchState $Context
    if($state.Phase -ne 'Idle' -or $state.Active -ne 'modern'){Throw-SwitchError Busy 'Start from a healthy active modern environment.'}
    if(Test-Path -LiteralPath (Join-Path $Context.Root 'Manifests/legacy.json')){Throw-SwitchError AlreadyInitialized 'Legacy environment already exists.'}
    $modern=Read-EnvironmentManifest $Context modern
    $signature=Get-AuthenticodeSignature -LiteralPath $LegacyInstallerPath
    Assert-LegacyPreparation (Test-EnvironmentBackup $Context @{Path=$modern.BackupPath}) ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Logitech Inc') (Get-Item -LiteralPath $LegacyInstallerPath).VersionInfo.FileVersion
    $lease=Enter-SwitchLock $Context
    try{
        $id=[guid]::NewGuid().ToString('N');$state.TransactionId=$id;$state.Target='legacy'
        Add-JournalEntry $Context $id Checkpoint source $modern $null
        $state=Save-Phase $Context $state Maintenance 'Preparing official legacy installation.'
        Disable-LaunchTicket $Context
        $null=Stop-GHUBEnvironment $Context $modern
        $modern=Update-EnvironmentRuntimeRegistry $Context $modern
        Add-JournalEntry $Context $id Checkpoint 'source-quiesced' $modern $null
        $backup=New-EnvironmentBackup $Context $modern
        Add-JournalEntry $Context $id Checkpoint bootstrap-backup $backup $null
        $modern.Acls=$backup.Trees;$modern.BackupPath=$backup.Path
        Write-AtomicJson (Join-Path $Context.Root 'Manifests/modern.json') $modern
        $auditSource=Get-InstallerAuditSource $modern @((Get-GHUBInventory $Context).Tasks)
        $baseline=Get-InstallerSnapshot $Context
        Write-AtomicJson (Join-Path $Context.Root "Transactions/$id-installer-before.json") $baseline
        if($baseline.Errors.Count){Throw-SwitchError UnclassifiedInstallerChange 'Baseline contains unreadable system evidence; installer has not started.'}
        Write-Host '新版已完整备份。下面通过官方界面卸载当前 G HUB，然后安装 2021.3。请勿删除切换器备份。'
        if((Read-Host '输入 INSTALL 继续，其他输入取消') -cne 'INSTALL'){Throw-SwitchError UserCancelled 'Legacy preparation cancelled.'}
        $manager=Join-Path (Get-ActiveDirectories $Context).Program 'lghub_software_manager.exe'
        if(Test-Path -LiteralPath $manager){
            $managerProcess=Start-Process -FilePath $manager -PassThru
            try{$managerProcess.WaitForExit()}finally{$managerProcess.Dispose()}
        }
        Write-Host '请等待官方界面完成卸载后再确认；启动器退出不代表卸载已完成。若未打开，请从 Windows 已安装的应用中卸载 G HUB。'
        if((Read-Host '确认官方卸载已完成后输入 UNINSTALLED') -cne 'UNINSTALLED'){Throw-SwitchError UserCancelled 'Uninstall not confirmed.'}
        if(Test-Path -LiteralPath (Join-Path (Get-ActiveDirectories $Context).Program 'lghub_agent.exe')){Throw-SwitchError InstallerStillPresent 'Modern application is still present; will not run legacy installer over it.'}
        Initialize-LegacyDataRoots $Context $id
        $installerProcess=Start-Process -FilePath $LegacyInstallerPath -PassThru
        try{$installerProcess.WaitForExit()}finally{$installerProcess.Dispose()}
        Write-Host '请等待官方安装界面完成安装，再在旧版设置中关闭自动更新；启动器退出不代表安装已完成。确认界面显示 2021.3；暂时不要设置宏或登录同步。'
        if((Read-Host '确认官方安装已完成、界面显示 2021.3 且自动更新已关闭后输入 AUTO-OFF') -cne 'AUTO-OFF'){Throw-SwitchError UpdatePolicyUnverified 'Legacy update policy was not confirmed.'}
        $legacy=Capture-CurrentEnvironment $Context legacy -AutomaticUpdatesObservedOff -DeferRegistration
        Add-JournalEntry $Context $id Checkpoint 'legacy-capture-candidate' $null $legacy
        $after=Get-InstallerSnapshot $Context
        Write-AtomicJson (Join-Path $Context.Root "Transactions/$id-installer-after.json") $after
        $evidence=Confirm-InstallerChanges $Context $baseline $after $auditSource $legacy $id
        $legacy|Add-Member -NotePropertyName InstallerEvidence -NotePropertyValue $evidence -Force
        Register-Environment $Context $legacy
        foreach($role in (Get-ActiveDirectories $Context).Keys){
            $park=Join-Path $Context.Root "Environments/modern/$role"
            $null=Test-ManagedPath $Context $park $role
            if(Test-Path -LiteralPath $park){Throw-SwitchError UnsafePath 'Modern parked directory already exists.'}
            [IO.Directory]::CreateDirectory((Split-Path $park -Parent))|Out-Null
            Copy-Item -LiteralPath (Join-Path $backup.Path $role) -Destination $park -Recurse -Force
        }
        $null=Install-StartupControl $Context $legacy
        Add-JournalEntry $Context $id Checkpoint 'legacy-captured' $null $legacy
        $state.Phase='Idle';$state.Active='legacy';$state.Target=$null;$state.TransactionId=$null;$state.Sequence++;$state.Health='Unverified'
        Write-SwitchState $Context $state
    }catch{
        $state=Read-SwitchState $Context;$state.Phase='RecoveryRequired';$state.Sequence++;$state.LastError=$_.Exception.Message;$state.Health='Unverified'
        Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state 'Preparation interrupted. Use Restore Modern to recover from the verified backup.'
        return(New-OperationResult RecoveryRequired RecoveryRequired $state.LastError)
    }finally{$lease.Dispose()}
    Invoke-GHUBSwitch $Context modern
}
function Restore-ModernBackup {param($Context)
    Assert-Administrator
    $lease=Enter-SwitchLock $Context
    try{
        $state=Read-SwitchState $Context
        if(Get-ExternalRecoveryCheckpoint $Context $state){return (New-OperationResult RecoveryRequired ExternalRecoveryRequired 'External modern adoption requires its dedicated resume; current configuration was retained.')}
        $modern=Read-EnvironmentManifest $Context modern
        if($state.TransactionId){
            $journal=@(Read-ValidJournal $Context $state.TransactionId)
            $quiesced=@($journal|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'source-quiesced'})
            $backups=@($journal|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -in @('backup','bootstrap-backup','update-backup')})
            if($quiesced.Count -and -not $backups.Count){
                $unknown=@($journal|Where-Object {$_.Kind -ne 'Checkpoint' -or $_.StepId -notin @('source','source-quiesced','switch-failure')})
                if($unknown.Count){Throw-SwitchError RecoveryRequired 'No fresh source backup exists after recorded environment mutations.'}
                $source=Get-SourceCheckpoint $Context $state.TransactionId
                if($source.Slot -ne 'modern'){Throw-SwitchError RecoveryRequired 'The interrupted maintenance source is not modern.'}
                # No installer or directory mutation began; preserve the stopped source under this lease.
                return (Invoke-GHUBRollback $Context 'Preparation stopped before a new backup completed.')
            }
            $source=Get-SourceCheckpoint $Context $state.TransactionId
            if($source.Slot -ne 'modern'){Throw-SwitchError RecoveryRequired 'The interrupted maintenance source is not modern.'}
            $modern=$source
        }
        if(-not $state.TransactionId){$state.TransactionId=[guid]::NewGuid().ToString('N')}
        $state.Phase='RollingBack';$state.Target='modern';$state.Sequence++;Write-SwitchState $Context $state
        Disable-LaunchTicket $Context
        $inventory=Get-GHUBInventory $Context
        $current=New-EnvironmentManifest $Context legacy $inventory
        $null=Stop-GHUBEnvironment $Context $current
        if(-not (Test-InstallationConfigurationMode $Context)){$current.DriverPackages=@(Export-ManagedDrivers $Context $current)}
        # Prove that the installed driver topology is recoverable before displacing any program or data directory.
        $installationMode=Test-InstallationConfigurationMode $Context
        $plan=$null
        if(-not $installationMode){$plan=New-DriverPlan $current $modern $inventory;$null=Save-GHUBDriverPlan $Context $plan}
        $null=Stop-EnvironmentAppLocalKernel $Context $current $modern
        $backup=Read-AtomicJson (Join-Path $modern.BackupPath 'backup.json')
        $null=Restore-BackupDirectories $Context $backup $state.TransactionId
        if($installationMode){$modern|Add-Member Acls $backup.Trees -Force}
        $identities=[ordered]@{};foreach($role in (Get-ActiveDirectories $Context).Keys){$identities[$role]=Get-DirectoryIdentity (Get-ActiveDirectories $Context)[$role] -Context $Context}
        $modern|Add-Member -NotePropertyName DirectoryIdentities -NotePropertyValue $identities -Force
        $null=Apply-EnvironmentServices $Context $modern
        $null=Restore-EnvironmentAppLocalKernel $Context $modern
        $registry=Get-OwnedRegistryValues $Context;$current.RegistryValues=$registry.Values
        $null=Apply-EnvironmentRegistry $Context $current $modern
        Write-AtomicJson (Join-Path $Context.Root 'Manifests/modern.json') $modern
        $result=if($installationMode){New-OperationResult}else{Invoke-DriverPlan $Context $plan}
        if($result.RebootRequired){$state.RebootRequestedAtBootId=Get-BootId;$state=Save-Phase $Context $state PendingReboot;return $result}
        Complete-GHUBTransaction $Context $modern
    }catch{
        $state=Read-SwitchState $Context;$state.Phase='RecoveryRequired';$state.Sequence++;$state.LastError=$_.Exception.Message;$state.Health='Unverified'
        Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state $state.LastError
        New-OperationResult RecoveryRequired RecoveryRequired $state.LastError
    }finally{$lease.Dispose()}
}
function Assert-ModernMaintenance {param($State)
    if($State.Phase -ne 'Idle' -or $State.Active -ne 'modern'){Throw-SwitchError Busy 'Maintenance requires an idle modern environment.'}
}
function Get-ModernStartupRestore {param($Source,$Captured)
    # Startup values removed by this tool remain absent during an update. Keep
    # those recorded values, while preferring replacements created by the vendor.
    $prior=Get-ObjectValue $Source StartupRestore $Source
    $startup=@(Get-ObjectValue $Captured Startup @())
    foreach($entry in @(Get-ObjectValue $prior Startup @())){
        if(-not @($startup|Where-Object {$_.Path -ieq $entry.Path -and $_.Name -ieq $entry.Name}).Count){$startup+=$entry}
    }
    $tasks=@()
    foreach($task in @(Get-ObjectValue $Captured Tasks @())){
        $restore=$task
        $matches=@(Get-ObjectValue $prior Tasks @()|Where-Object {$_.Path -ieq $task.Path -and $_.Name -ieq $task.Name})
        if($matches.Count -eq 1){
            if(Test-InstallerTaskDisableTransition ([string]$matches[0].Xml) ([string]$task.Xml)){$restore=$matches[0]}
            elseif((Test-InstallerTaskXml ([string]$matches[0].Xml)) -and (Test-InstallerTaskXml ([string]$task.Xml))){
                # An update can replace the task action while retaining the disabled
                # setting installed by this tool. Restore its recorded enablement
                # without discarding the vendor's new definition.
                $before=Read-InstallerTaskXml ([string]$matches[0].Xml);$after=Read-InstallerTaskXml ([string]$task.Xml)
                $ns=[Xml.XmlNamespaceManager]::new($after.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
                $disabled=$after.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns)
                if($disabled -and $disabled.InnerText -in @('false','0')){
                    $enabled=$before.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns)
                    if($enabled){$disabled.InnerText=$enabled.InnerText}else{[void]$disabled.ParentNode.RemoveChild($disabled)}
                    $restore=$task|ConvertTo-Json -Depth 20|ConvertFrom-Json
                    $restore.Xml=$after.OuterXml
                }
            }
        }
        $tasks+=$restore
    }
    [pscustomobject]@{Startup=$startup;Tasks=$tasks}
}
function Maintain-ModernEnvironment {param($Context)
    Assert-Administrator
    $lease=Enter-SwitchLock $Context
    try{
        $state=Read-SwitchState $Context;Assert-ModernMaintenance $state
        $modern=Read-EnvironmentManifest $Context modern
        $state.TransactionId=[guid]::NewGuid().ToString('N');$state.Target='modern'
        Add-JournalEntry $Context $state.TransactionId Checkpoint source $modern $null
        $state=Save-Phase $Context $state Maintenance 'Modern update maintenance is active.'
        Disable-LaunchTicket $Context
        $null=Stop-GHUBEnvironment $Context $modern
        $modern=Update-EnvironmentRuntimeRegistry $Context $modern
        Add-JournalEntry $Context $state.TransactionId Checkpoint 'source-quiesced' $modern $null
        $backup=New-EnvironmentBackup $Context $modern
        Add-JournalEntry $Context $state.TransactionId Checkpoint update-backup $backup $null
        $auditSource=Get-InstallerAuditSource $modern @((Get-GHUBInventory $Context).Tasks)
        $baseline=Get-InstallerSnapshot $Context
        Write-AtomicJson (Join-Path $Context.Root ("Transactions/"+$state.TransactionId+'-installer-before.json')) $baseline
        if($baseline.Errors.Count){Throw-SwitchError UnclassifiedInstallerChange 'Incomplete baseline; update has not started.'}
        $null=Apply-EnvironmentServices $Context $modern -ForLaunch
        foreach($service in $modern.Services){Start-Service -Name $service.Name}
        $launch=Start-GHUBUserSession $Context $modern
        if($launch.Status -ne 'Ok'){Throw-SwitchError AwaitingLogon 'Log in as the registered user before updating.'}
        Write-Host '请在新版 G HUB 中手动检查并完成更新，之后再次关闭自动更新。更新期间不要切换版本。'
        if((Read-Host '全部完成后输入 UPDATED-AUTO-OFF') -cne 'UPDATED-AUTO-OFF'){Throw-SwitchError UpdatePolicyUnverified 'Update completion was not confirmed.'}
        $new=Capture-CurrentEnvironment $Context modern -AutomaticUpdatesObservedOff -DeferRegistration
        Add-JournalEntry $Context $state.TransactionId Checkpoint 'modern-capture-candidate' $null $new
        $after=Get-InstallerSnapshot $Context
        Write-AtomicJson (Join-Path $Context.Root ("Transactions/"+$state.TransactionId+'-installer-after.json')) $after
        $evidence=Confirm-InstallerChanges $Context $baseline $after $auditSource $new $state.TransactionId
        $new|Add-Member -NotePropertyName InstallerEvidence -NotePropertyValue $evidence -Force
        $new|Add-Member -NotePropertyName StartupRestore -NotePropertyValue (Get-ModernStartupRestore $modern $new) -Force
        Register-Environment $Context $new
        $null=Install-StartupControl $Context $new
        Add-JournalEntry $Context $state.TransactionId Checkpoint 'update-captured' $null $new
        if(Test-InstallationConfigurationMode $Context){return (Complete-GHUBTransaction $Context $new)}
        $state.RebootRequestedAtBootId=Get-BootId
        $state=Save-Phase $Context $state PendingReboot 'Restart Windows after vendor update; then the new manifest is verified.'
        New-OperationResult PendingReboot RebootRequired 'Update captured. Restart Windows to verify the refreshed environment.'
    }catch{
        $state=Read-SwitchState $Context
        if($state.Phase -eq 'Maintenance'){$state.Phase='RecoveryRequired';$state.Sequence++;$state.LastError=$_.Exception.Message;Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state $state.LastError}
        New-OperationResult RecoveryRequired RecoveryRequired $_.Exception.Message
    }finally{$lease.Dispose()}
}
function Restore-DetachedServiceConfiguration {param($Record)
    Initialize-NativeLibrary
    [GHubSwitcher.ServiceApi]::Restore([GHubSwitcher.ServiceRecord]$Record,$false)
}
function Remove-SwitcherControl {param($Context)
    Assert-Administrator
    $lease=Enter-SwitchLock $Context
    try{
        $state=Read-SwitchState $Context
        if($state.Phase -eq 'Detaching'){
            $saved=@(Read-ValidJournal $Context $state.TransactionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'detach-control'})
            if($saved.Count -ne 1){Throw-SwitchError RecoveryRequired 'No unique detachment checkpoint.'}
            $modern=$saved[0].Before.Modern;$original=$saved[0].Before.Original
        }else{
            Assert-ModernMaintenance $state
            $modern=Read-EnvironmentManifest $Context modern
            $accepted=if(Test-InstallationConfigurationMode $Context){(Get-GHUBInstallationReport $Context $modern -Running).Passed}else{(Get-GHUBHealth $Context $modern).TechnicalPassed}
            if(-not $accepted){Throw-SwitchError HealthCheckFailed 'Modern installation must be running before detaching.'}
            $original=Read-AtomicJson (Join-Path $Context.Root 'State/original-control.json')
            $state.TransactionId=[guid]::NewGuid().ToString('N')
            Add-JournalEntry $Context $state.TransactionId Checkpoint detach-control @{Modern=$modern;Original=$original} $null
            $state=Save-Phase $Context $state Detaching 'Removing switcher control.'
        }
        Disable-LaunchTicket $Context
        $null=Stop-GHUBEnvironment $Context $modern
        foreach($service in $modern.Services){
            $prior=@($original.Services|Where-Object Name -EQ $service.Name)
            $record=[GHubSwitcher.ServiceRecord]$service.Native
            if($prior.Count -eq 1){$record.StartType=$prior[0].Native.StartType;$record.DelayedAutoStart=$prior[0].Native.DelayedAutoStart;$record.FailureActions=[GHubSwitcher.FailureAction[]]$prior[0].Native.FailureActions}
            Restore-DetachedServiceConfiguration $record
        }
        $restore=Get-ObjectValue $modern StartupRestore $modern
        foreach($entry in $restore.Startup){
            $current=Read-RegistryValue $entry.Path $entry.Name
            if($current.Exists -and [string]$current.Value -ne [string]$entry.Value){Throw-SwitchError ExternalChange 'Original startup location is now owned by another value.'}
            Write-RegistryValue $entry.Path $entry.Name @{Exists=$true;Kind=$entry.Kind;Value=$entry.Value}
        }
        foreach($task in $restore.Tasks){Register-ScheduledTask -TaskName $task.Name -TaskPath $task.Path -Xml $task.Xml -Force|Out-Null}
        foreach($name in @('GHUBSwitcher-Monitor','GHUBSwitcher-RecoverAtBoot','GHUBSwitcher-UserSession')){
            if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){
                # BootResume may be executing this very worker; unregistering a
                # task removes its registration, while stopping it kills our work.
                if($name -ne 'GHUBSwitcher-RecoverAtBoot'){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue}
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            }
        }
        foreach($service in $modern.Services){Start-Service -Name $service.Name}
        $registration=Read-AtomicJson (Join-Path $Context.Root 'registration.json')
        $registration|Add-Member -NotePropertyName Detached -NotePropertyValue $true -Force
        Write-AtomicJson (Join-Path $Context.Root 'registration.json') $registration
        $state=Set-SwitchPhase $state Detached;$state.TransactionId=$null;$state.Target=$null;$state.Health='Unverified';$state.LastError=$null
        Write-SwitchState $Context $state
        Publish-SwitchStatus $Context $state 'Switcher control removed. Backups and environments retained.'
        New-OperationResult Ok ControlRemoved '已退出切换器管理。新版保留，请正常启动 G HUB；备份未删除。'
    }catch{
        $state=Read-SwitchState $Context
        if($state.Phase -ne 'Detaching'){throw}
        $state.LastError=$_.Exception.Message;$state.Sequence++
        Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state $state.LastError
        New-OperationResult RecoveryRequired DetachInterrupted '退出管理未完成，请选择 8 续接；程序和配置未删除。'
    }finally{$lease.Dispose()}
}
Export-ModuleMember -Function *-*
