Set-StrictMode -Version Latest
foreach ($name in @('Core','Inventory','Storage','Drivers','Lifecycle','ExternalRecovery')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") -DisableNameChecking }

function Get-BootDecision { param($State,[string]$CurrentBootId)
    $action='Recover'; $target=Get-ObjectValue $State Target $null
    switch ($State.Phase) {
        PendingReboot { $action=if($State.RebootRequestedAtBootId -eq $CurrentBootId){'WaitForReboot'}else{'Resume'} }
        AwaitingLogon { $action='Resume' }
        Idle {
            if ($State.BootId -ne $CurrentBootId -and $State.Active -ne 'modern') { $action='SwitchModern'; $target='modern' }
            else { $action='StartActive'; $target=$State.Active }
        }
    }
    [pscustomobject]@{Action=$action;TargetSlot=$target}
}
function Test-MonitorGeneration { param($Observed,$Current)
    return ($Observed.Phase -eq 'Idle' -and $Current.Phase -eq 'Idle' -and $Observed.Sequence -eq $Current.Sequence -and $Observed.Active -eq $Current.Active)
}
function Test-LaunchTicket { param($Ticket,[string]$OwnerSid)
    try { return ($Ticket.Enabled -eq $true -and $Ticket.OwnerSid -eq $OwnerSid -and $Ticket.Slot -in @('modern','legacy') -and (ConvertTo-UtcTime $Ticket.ExpiresUtc) -gt [DateTime]::UtcNow) } catch { return $false }
}
function Read-EnvironmentManifest { param($Context,[string]$Slot)
    Assert-Slot $Slot
    $manifest=Read-AtomicJson (Join-Path $Context.Root "Manifests/$Slot.json")
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Slot -ne $Slot -or $manifest.OwnerSid -ne $Context.OwnerSid) { Throw-SwitchError InvalidManifest 'Invalid environment owner or schema.' }
    foreach ($field in @('ProductVersion','Files','Services','Startup','Tasks','RegistryValues','Devices','DriverPackages','KernelServices','UpdatePolicy','Qualification')) {
        if (-not $manifest.PSObject.Properties[$field]) { Throw-SwitchError InvalidManifest "Missing manifest field: $field" }
    }
    if ($manifest.Qualification -notin @('Prepared','TechnicalPassed','FunctionalPassed')) { Throw-SwitchError InvalidManifest 'Environment has not completed preparation.' }
    return $manifest
}
function Publish-SwitchStatus { param($Context,$State,[string]$Message='')
    Write-AtomicJson (Join-Path $Context.Root 'Status/status.json') ([pscustomobject]@{OwnerSid=$Context.OwnerSid;Sequence=$State.Sequence;Phase=$State.Phase;Active=$State.Active;Target=$State.Target;Health=$State.Health;Message=$Message;LastError=$State.LastError;UpdatedUtc=[DateTime]::UtcNow.ToString('o')})
    if($Context.Mode -eq 'Live' -and $Message){Write-Host ('['+(Get-Date -Format 'HH:mm:ss')+'] '+$Message)}
}
function Save-Phase { param($Context,$State,[string]$Phase,[string]$Message='')
    $next=Set-SwitchPhase $State $Phase; Write-SwitchState $Context $next; Publish-SwitchStatus $Context $next $Message; return $next
}
function Disable-LaunchTicket { param($Context)
    Write-AtomicJson (Join-Path $Context.Root 'Status/launch.json') @{OwnerSid=$Context.OwnerSid;Enabled=$false;Slot='modern';Sequence=-1;ExpiresUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')}
}
function Get-GHUBHealth { param($Context,$Manifest,[switch]$BeforeLaunch)
    $report=Test-DriverState $Context $Manifest -AllowPendingChildren:$BeforeLaunch
    $checks=@($report.Checks); $dirs=Get-ActiveDirectories $Context
    foreach ($role in $dirs.Keys) {
        $passed=Test-Path -LiteralPath $dirs[$role]
        $checks+=[pscustomobject]@{Passed=$passed;Device=$role;Failures=@(if(-not $passed){'DirectoryMissing'})}
    }
    foreach ($file in $Manifest.Files) {
        $path=Join-Path $dirs.Program $file.Relative
        $passed=(Test-Path -LiteralPath $path)
        if ($passed) { $null=Assert-NoReparsePoint $path; $passed=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ceq $file.Sha256 }
        $checks+=[pscustomobject]@{Passed=$passed;Device=$file.Relative;Failures=@(if(-not $passed){'ProgramIdentityMismatch'})}
    }
    $inventory=Get-GHUBInventory $Context
    $passed=$inventory.ProductVersion -eq $Manifest.ProductVersion
    $checks+=[pscustomobject]@{Passed=$passed;Device='ProductVersion';Failures=@(if(-not $passed){'VersionMismatch'})}
    foreach ($service in $Manifest.Services) {
        $actual=@($inventory.Services | Where-Object Name -EQ $service.Name)
        $failures=@()
        if ($actual.Count -ne 1 -or $actual[0].ImagePath -ine $service.ImagePath) { $failures+='ServiceMismatch' }
        if (-not $BeforeLaunch -and $actual.Count -eq 1) {
            if ((Get-ObjectValue $actual[0] State '') -ine 'Running') { $failures+='ServiceNotRunning' }
            if ((Get-ObjectValue $actual[0] StartMode 'Disabled') -ieq 'Disabled' -or (Get-ObjectValue $actual[0] Start 4) -eq 4) { $failures+='ServiceDisabled' }
        }
        $checks+=[pscustomobject]@{Passed=($failures.Count -eq 0);Device=$service.Name;Failures=$failures}
    }
    $policy=Test-UpdatePolicy $Context $Manifest
    $passed=$policy.Status -eq 'Ok'
    $checks+=[pscustomobject]@{Passed=$passed;Device='UpdatePolicy';Failures=@(if(-not $passed){$policy.Code})}
    if (-not $BeforeLaunch) {
        $program=$dirs.Program.TrimEnd('\')+'\'
        $bad=@($inventory.Processes | Where-Object { -not $_.Path -or -not $_.Path.StartsWith($program,[StringComparison]::OrdinalIgnoreCase) -or ($_.OwnerSid -ne $Context.OwnerSid -and $_.OwnerSid -ne 'S-1-5-18') })
        $agent=@($inventory.Processes | Where-Object Name -EQ 'lghub_agent.exe')
        $passed=$bad.Count -eq 0 -and $agent.Count -gt 0
        $checks+=[pscustomobject]@{Passed=$passed;Device='RunningProcesses';Failures=@(if(-not $passed){'ProcessIdentityMismatch'})}
    }
    [pscustomobject]@{TechnicalPassed=(@($checks | Where-Object {-not $_.Passed}).Count -eq 0);FunctionalStatus='Unverified';Checks=$checks;CapturedAt=[DateTime]::UtcNow.ToString('o')}
}
function Request-GHUBDriverReboot { param($Context,$Manifest,[string]$Message)
    Disable-LaunchTicket $Context
    $null=Stop-GHUBEnvironment $Context $Manifest
    $state=Read-SwitchState $Context;$state.RebootRequestedAtBootId=Get-BootId
    $null=Save-Phase $Context $state PendingReboot $Message
    New-OperationResult PendingReboot RebootRequired $Message
}
function Get-GHUBInstallationReport {param($Context,$Manifest,[switch]$Running)
    $dirs=Get-ActiveDirectories $Context;$checks=@()
    foreach($role in $dirs.Keys){$checks+=[pscustomobject]@{Device=$role;Passed=(Test-Path -LiteralPath $dirs[$role] -PathType Container);Failures=@()}}
    foreach($file in $Manifest.Files){
        $path=Join-Path $dirs.Program $file.Relative
        $passed=Test-Path -LiteralPath $path -PathType Leaf
        if($passed){$null=Assert-NoReparsePoint $path;$passed=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ceq $file.Sha256}
        $checks+=[pscustomobject]@{Device=$file.Relative;Passed=$passed;Failures=@(if(-not $passed){'ProgramIdentityMismatch'})}
    }
    if(-not $Running){
        foreach($role in @('LocalData','RoamingData','MachineData')){
            $record=@(Get-ObjectValue $Manifest Acls @()|Where-Object Role -EQ $role)
            $passed=$record.Count -eq 1
            if($passed){
                $expected=@($record[0].Files|Where-Object {$_.Relative -ine 'settings.db-shm'}|Sort-Object Relative|Select-Object Relative,IsDirectory,Length,Sha256)
                $actual=@(Get-TreeFiles $dirs[$role]|Where-Object {$_.Relative -ine 'settings.db-shm'}|Sort-Object Relative|Select-Object Relative,IsDirectory,Length,Sha256)
                $passed=(Get-TextHash (ConvertTo-Json -InputObject $expected -Depth 10 -Compress)) -ceq (Get-TextHash (ConvertTo-Json -InputObject $actual -Depth 10 -Compress))
            }
            $checks+=[pscustomobject]@{Device=('Configuration:'+ $role);Passed=$passed;Failures=@(if(-not $passed){'ConfigurationSnapshotMismatch'})}
        }
        foreach($value in $Manifest.RegistryValues){
            $passed=$true
            try{Test-GHUBRegistryPath $Context $value.Path;Assert-RegistryBefore $value (Read-RegistryValue $value.Path $value.Name)}catch{$passed=$false}
            $checks+=[pscustomobject]@{Device=('ConfigurationRegistry:'+ $value.Name);Passed=$passed;Failures=@(if(-not $passed){'ConfigurationRegistryMismatch'})}
        }
        $passed=$true
        try{Assert-GHUBRegistrySnapshot @($Manifest.RegistryValues) @((Get-GHUBRegistryValues $Context).Values)}catch{$passed=$false}
        $checks+=[pscustomobject]@{Device='ConfigurationRegistrySet';Passed=$passed;Failures=@(if(-not $passed){'ConfigurationRegistrySetMismatch'})}
    }
    $inventory=Get-GHUBInventory $Context
    $checks+=[pscustomobject]@{Device='ProductVersion';Passed=($inventory.ProductVersion -ceq $Manifest.ProductVersion);Failures=@()}
    if($Running){
        $program=$dirs.Program.TrimEnd('\')+'\'
        $bad=@($inventory.Processes|Where-Object {-not $_.Path -or -not $_.Path.StartsWith($program,[StringComparison]::OrdinalIgnoreCase) -or ($_.OwnerSid -ne $Context.OwnerSid -and $_.OwnerSid -ne 'S-1-5-18')})
        $agent=@($inventory.Processes|Where-Object Name -EQ 'lghub_agent.exe')
        $checks+=[pscustomobject]@{Device='ApplicationStarted';Passed=($bad.Count -eq 0 -and $agent.Count -gt 0);Failures=@()}
        foreach($service in $Manifest.Services){
            $found=@($inventory.Services|Where-Object Name -EQ $service.Name)
            $passed=$found.Count -eq 1 -and $found[0].ImagePath -ieq $service.ImagePath -and $found[0].State -ieq 'Running'
            $checks+=[pscustomobject]@{Device=$service.Name;Passed=$passed;Failures=@(if(-not $passed){'ApplicationServiceNotRunning'})}
        }
    }
    [pscustomobject]@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);ValidationMode='InstallationAndConfiguration';DriverChecksPerformed=$false;ConfigurationChecked=(-not [bool]$Running);PermissionComparisonPerformed=$false;IgnoredEphemeralFiles=@('settings.db-shm');Checks=$checks;CapturedAt=[DateTime]::UtcNow.ToString('o')}
}
function Complete-GHUBInstallationTransaction {param($Context,$Manifest)
    $state=Read-SwitchState $Context
    if($state.Phase -in @('Binding','PendingReboot','RollingBack')){$state=Save-Phase $Context $state AwaitingLogon}
    $installed=Get-GHUBInstallationReport $Context $Manifest
    if(-not $installed.Passed){Throw-SwitchError InstallationCheckFailed ($installed.Checks|Where-Object {-not $_.Passed}|ConvertTo-Json -Depth 12 -Compress)}
    Add-JournalEntry $Context $state.TransactionId Checkpoint installation-and-configuration $null $installed
    $null=Restore-EnvironmentAppLocalKernel $Context $Manifest -ForLaunch
    $null=Apply-EnvironmentServices $Context $Manifest -ForLaunch
    foreach($service in $Manifest.Services){Start-Service -Name $service.Name -ErrorAction Stop}
    $launch=Start-GHUBUserSession $Context $Manifest
    if($launch.Status -eq 'AwaitingLogon'){Publish-SwitchStatus $Context $state $launch.Message;return $launch}
    if($launch.Status -ne 'Ok'){Throw-SwitchError ApplicationLaunchFailed $launch.Message}
    if($state.Phase -ne 'Verifying'){$state=Save-Phase $Context $state Verifying}
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do{$running=Get-GHUBInstallationReport $Context $Manifest -Running;if($running.Passed){break};Start-Sleep -Seconds 1}while([DateTime]::UtcNow -lt $deadline)
    if(-not $running.Passed){Throw-SwitchError ApplicationLaunchFailed 'The selected application did not start.'}
    Add-JournalEntry $Context $state.TransactionId Checkpoint installation-launch $null $running
    $failure=@(Read-ValidJournal $Context $state.TransactionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'switch-failure'}|Select-Object -First 1)
    $state=Set-SwitchPhase $state Idle;$state.Active=$Manifest.Slot;$state.Target=$null;$state.TransactionId=$null;$state.Health='InstallationAndConfigurationPassed';$state.BootId=Get-BootId;$state.RebootRequestedAtBootId=$null;$state.LastError=$null
    if($failure.Count){$state.LastError=$failure[0].Before.Cause}
    Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state '程序安装完整，配置已还原，所选 G HUB 已启动。'
    if($failure.Count){return (New-OperationResult Blocked SwitchFailedRecovered '切换失败，已恢复原环境。' @{RequestedTarget=$failure[0].Before.RequestedTarget;RestoredSlot=$Manifest.Slot;Cause=$state.LastError})}
    New-OperationResult Ok Ok '程序安装完整，配置已还原，所选 G HUB 已启动。' $installed
}
function Complete-GHUBTransaction { param($Context,$Manifest)
    if(Test-InstallationConfigurationMode $Context){return (Complete-GHUBInstallationTransaction $Context $Manifest)}
    $state=Read-SwitchState $Context
    if ($state.Phase -eq 'PendingReboot' -and $state.RebootRequestedAtBootId -eq (Get-BootId) -and -not (Test-GHUBChildRebootSatisfied $Context $Manifest)) { return (New-OperationResult PendingReboot RebootRequired 'Restart Windows to complete this driver change.') }
    if ($state.Phase -in @('Binding','PendingReboot','RollingBack')) { $state=Save-Phase $Context $state AwaitingLogon }
    $null=Restore-EnvironmentAppLocalKernel $Context $Manifest -ForLaunch
    $children=Resume-GHUBVirtualChildren $Context $Manifest
    if ($children.RebootRequired) { return (Request-GHUBDriverReboot $Context $Manifest $children.Message) }
    $health=Get-GHUBHealth $Context $Manifest -BeforeLaunch
    if (-not $health.TechnicalPassed) { Throw-SwitchError DriverMismatch ($health.Checks | Where-Object {-not $_.Passed} | ConvertTo-Json -Compress -Depth 12) }
    $null=Apply-EnvironmentServices $Context $Manifest -ForLaunch
    foreach ($service in $Manifest.Services) { Start-Service -Name $service.Name -ErrorAction Stop }
    $launch=Start-GHUBUserSession $Context $Manifest
    if ($launch.Status -eq 'AwaitingLogon') { Publish-SwitchStatus $Context $state $launch.Message; return $launch }
    $state=Save-Phase $Context $state Verifying
    $deadline=(Get-Date).ToUniversalTime().AddSeconds(30)
    do {
        $children=Resume-GHUBVirtualChildren $Context $Manifest
        if ($children.RebootRequired) { return (Request-GHUBDriverReboot $Context $Manifest $children.Message) }
        $health=Get-GHUBHealth $Context $Manifest
        if($health.TechnicalPassed -and $children.Status -ne 'AwaitingDevices'){break}
        Start-Sleep -Seconds 1
    } while((Get-Date).ToUniversalTime() -lt $deadline)
    if ($children.Status -eq 'AwaitingDevices') {
        $children=Resume-GHUBVirtualChildren $Context $Manifest -AfterLaunch
        if ($children.RebootRequired) { return (Request-GHUBDriverReboot $Context $Manifest $children.Message) }
        if ($children.Status -ne 'Ok') { Throw-SwitchError HealthCheckFailed 'Target virtual devices did not finish binding.' }
        $health=Get-GHUBHealth $Context $Manifest
    }
    if (-not $health.TechnicalPassed) { Throw-SwitchError HealthCheckFailed 'Target G HUB failed post-launch checks.' }
    Add-JournalEntry $Context $state.TransactionId Checkpoint 'verified' $null $health
    $failure=@(Read-ValidJournal $Context $state.TransactionId | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'switch-failure' } | Select-Object -First 1)
    $state=Set-SwitchPhase $state Idle; $state.Active=$Manifest.Slot; $state.Target=$null; $state.TransactionId=$null; $state.Health='TechnicalPassed'; $state.BootId=Get-BootId; $state.RebootRequestedAtBootId=$null; $state.LastError=$null
    Write-SwitchState $Context $state; Publish-SwitchStatus $Context $state 'Technical checks passed; the selected G HUB environment is running.'
    if ($Context.Mode -eq 'Live') { Start-ScheduledTask -TaskName 'GHUBSwitcher-Monitor' }
    if ($failure.Count) {
        $state.LastError=$failure[0].Before.Cause
        Write-SwitchState $Context $state; Publish-SwitchStatus $Context $state 'Requested switch failed. The previous environment has been recovered.'
        return (New-OperationResult Blocked SwitchFailedRecovered '切换失败，已恢复原环境。' ([pscustomobject]@{RequestedTarget=$failure[0].Before.RequestedTarget;RestoredSlot=$Manifest.Slot;Cause=$state.LastError;RecoveryHealth=$health}))
    }
    New-OperationResult Ok Ok 'The selected G HUB environment is running.' $health
}
function Get-SourceCheckpoint { param($Context,[string]$TransactionId)
    $journal=@(Read-ValidJournal $Context $TransactionId)
    $record=@($journal | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'source' })
    if ($record.Count -ne 1) { Throw-SwitchError RecoveryRequired 'No unique source checkpoint.' }
    $selected=$record[0]
    $quiesced=@($journal | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'source-quiesced' })
    if ($quiesced.Count -gt 1) { Throw-SwitchError RecoveryRequired 'No unique quiesced source checkpoint.' }
    if ($quiesced.Count) {
        $selected=$quiesced[0]
        foreach ($field in @('Slot','OwnerSid','ProductVersion')) {
            if ((Get-ObjectValue $selected.Before $field '') -cne (Get-ObjectValue $record[0].Before $field '')) { Throw-SwitchError RecoveryRequired 'Quiesced source identity differs from the original checkpoint.' }
        }
        if ($selected.Sequence -le $record[0].Sequence -or @($journal | Where-Object { $_.Kind -eq 'Intent' -and $_.Sequence -lt $selected.Sequence }).Count) { Throw-SwitchError RecoveryRequired 'Quiesced source was not saved before environment mutation.' }
    }
    $source=$selected.Before
    $backups=@($journal | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -in @('backup','bootstrap-backup','update-backup') })
    if ($backups.Count -gt 1) { Throw-SwitchError RecoveryRequired 'No unique source backup checkpoint.' }
    if ($backups.Count) {
        $backup=$backups[0].Before
        if ($backups[0].Sequence -le $selected.Sequence -or $backup.Slot -cne $source.Slot -or $backup.OwnerSid -cne $source.OwnerSid) { Throw-SwitchError RecoveryRequired 'Source backup identity or order is invalid.' }
        if (($backup.Manifest.RegistryValues | ConvertTo-Json -Depth 30 -Compress) -cne ($source.RegistryValues | ConvertTo-Json -Depth 30 -Compress)) { Throw-SwitchError RecoveryRequired 'Source backup does not contain the checkpoint registry snapshot.' }
        $source | Add-Member -NotePropertyName BackupPath -NotePropertyValue $backup.Path -Force
        $source | Add-Member -NotePropertyName Acls -NotePropertyValue $backup.Trees -Force
    }
    return $source
}
function Invoke-GHUBSwitch { param($Context,[string]$TargetSlot)
    Assert-Administrator; Assert-Slot $TargetSlot
    $lease=Enter-SwitchLock $Context
    try {
        $state=Read-SwitchState $Context
        if ($state.Phase -ne 'Idle') { return (New-OperationResult Blocked Busy 'Finish or recover the existing transaction first.') }
        $source=Read-EnvironmentManifest $Context $state.Active; $target=Read-EnvironmentManifest $Context $TargetSlot
        $policy=Test-UpdatePolicy $Context $target; if($policy.Status -ne 'Ok'){return $policy}
        $inventory=Get-GHUBInventory $Context; Assert-GHUBProcessOwnership $inventory.Processes $Context.OwnerSid
        if ($inventory.ProductVersion -ne $source.ProductVersion) { Throw-SwitchError ExternalChange 'Active version changed outside managed maintenance.' }
        $installationMode=Test-InstallationConfigurationMode $Context
        $plan=$null
        if(-not $installationMode){$plan=New-DriverPlan $source $target $inventory;Assert-GHUBDriverPlanSource $plan}
        $id=[guid]::NewGuid().ToString('N'); $state.TransactionId=$id; $state.Target=$TargetSlot
        Add-JournalEntry $Context $id Checkpoint source $source $target
        $state=Save-Phase $Context $state Preparing
        try {
            Disable-LaunchTicket $Context
            $null=Stop-GHUBEnvironment $Context $source
            $source=Update-EnvironmentRuntimeRegistry $Context $source
            Add-JournalEntry $Context $id Checkpoint source-quiesced $source $null
            # Directory exchange keeps the current files in their own slot. Only
            # refresh metadata here; ordinary switches must not clone gigabytes.
            $directories=Get-ActiveDirectories $Context
            $trees=@(foreach($role in $directories.Keys){
                $path=Test-ManagedPath $Context $directories[$role] $role
                [pscustomobject]@{Role=$role;Files=@(Get-TreeFiles $path);RootSddl=(Get-Acl -LiteralPath $path).Sddl}
            })
            $source|Add-Member -NotePropertyName Acls -NotePropertyValue $trees -Force
            Write-AtomicJson (Join-Path $Context.Root "Manifests/$($source.Slot).json") $source
            if ($source.Slot -eq $target.Slot) { $target=$source }
            elseif($installationMode){
                # The parked directories contain the current settings. Old capture
                # metadata must never replace or reject later files in that slot.
                $targetTrees=@(foreach($role in $directories.Keys){
                    $path=Test-ManagedPath $Context (Join-Path $Context.Root "Environments/$($target.Slot)/$role") $role
                    [pscustomobject]@{Role=$role;Files=@(Get-TreeFiles $path);RootSddl=(Get-Acl -LiteralPath $path).Sddl}
                })
                $target|Add-Member Acls $targetTrees -Force
                Add-JournalEntry $Context $id Checkpoint target-configuration @{Slot=$target.Slot;OwnerSid=$target.OwnerSid;ProductVersion=$target.ProductVersion} $targetTrees
                Write-AtomicJson (Join-Path $Context.Root "Manifests/$($target.Slot).json") $target
            }
            $state=Save-Phase $Context $state Quiesced
            if(-not $installationMode){Save-GHUBDriverPlan $Context $plan}
            $null=Stop-EnvironmentAppLocalKernel $Context $source $target
            if(-not $installationMode){Assert-GHUBDriverPlanSource $plan}
            $state=Save-Phase $Context $state Swapping
            $null=Invoke-DirectoryExchange $Context $source.Slot $target.Slot
            if($target.PSObject.Properties['Acls']){Restore-EnvironmentAcl $Context $target.Acls}
            $null=Restore-EnvironmentAppLocalKernel $Context $target
            $state=Save-Phase $Context $state Binding
            $null=Apply-EnvironmentRegistry $Context $source $target
            $null=Apply-EnvironmentServices $Context $target
            $result=if($installationMode){New-OperationResult}else{Invoke-DriverPlan $Context $plan}
            if ($result.RebootRequired) {
                $state.RebootRequestedAtBootId=Get-BootId
                $state=Save-Phase $Context $state PendingReboot $result.Message
                return $result
            }
            return (Complete-GHUBTransaction $Context $target)
        } catch {
            $errorText=$_.Exception.Message
            return (Invoke-GHUBRollback $Context $errorText)
        }
    } finally { $lease.Dispose() }
}
function Undo-RegistryJournal { param($Context,[string]$TransactionId)
    $entries=@(Read-ValidJournal $Context $TransactionId | Where-Object { $_.Kind -eq 'Intent' -and $_.StepId -like 'registry-*' }); [array]::Reverse($entries)
    foreach ($entry in $entries) {
        $before=$entry.Before; Test-GHUBRegistryPath $Context $before.Path
        $actual=Read-RegistryValue $before.Path $before.Name
        try { Assert-RegistryBefore $before.Record $actual; continue } catch {}
        Assert-RegistryBefore $entry.After $actual
        Write-RegistryValue $before.Path $before.Name $before.Record
    }
}
function Invoke-GHUBRollback { param($Context,[string]$Cause)
    $state=Read-SwitchState $Context
    if(Get-ExternalRecoveryCheckpoint $Context $state){return (New-OperationResult RecoveryRequired ExternalRecoveryRequired 'External modern adoption requires its dedicated resume; current configuration was retained.')}
    try {
        Disable-LaunchTicket $Context
        if ($Cause -match '^ExternalChange:') { Throw-SwitchError RecoveryRequired 'External environment changes require inspection before automatic rollback.' }
        Repair-JournalTail $Context $state.TransactionId
        $source=Get-SourceCheckpoint $Context $state.TransactionId
        $failure=@(Read-ValidJournal $Context $state.TransactionId | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'switch-failure' })
        if (-not $failure.Count) { Add-JournalEntry $Context $state.TransactionId Checkpoint 'switch-failure' @{RequestedTarget=$state.Target;Cause=$Cause} $null }
        if ($state.Phase -ne 'RollingBack') { $state=Save-Phase $Context $state RollingBack $Cause }
        $state.Target=$source.Slot; $state.LastError=$Cause; Write-SwitchState $Context $state
        # Quiesce the currently installed process set before reversing directory moves.
        $inventory=Get-GHUBInventory $Context
        $driverIntent=@(Read-ValidJournal $Context $state.TransactionId | Where-Object { $_.Kind -eq 'Intent' -and ($_.StepId -like 'driver-*' -or $_.StepId -like 'filters-*' -or $_.StepId -like 'auxiliary-*') })
        $plan=$null
        $installationMode=Test-InstallationConfigurationMode $Context
        if ($driverIntent.Count -and -not $installationMode) {
            $original=@(Read-ValidJournal $Context $state.TransactionId | Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'source'})
            if ($original.Count -ne 1) { Throw-SwitchError ExternalChange 'Rollback has no unique captured forward target.' }
            $plan=New-GHUBRollbackDriverPlan $Context $source $original[0].After $inventory
            Assert-GHUBDriverPlanSource $plan
        }
        $active=New-EnvironmentManifest $Context $source.Slot $inventory
        $null=Stop-GHUBEnvironment $Context $active
        $null=Stop-EnvironmentAppLocalKernel $Context $active $source
        if ($null -ne $plan) { Assert-GHUBDriverPlanSource $plan }
        $null=Undo-DirectoryExchange $Context $state.TransactionId
        $null=Restore-EnvironmentAppLocalKernel $Context $source
        Undo-RegistryJournal $Context $state.TransactionId
        $null=Apply-EnvironmentServices $Context $source
        if ($driverIntent.Count -and -not $installationMode) {
            $null=Invoke-DriverPlan $Context $plan
            $state.RebootRequestedAtBootId=Get-BootId
            $state=Save-Phase $Context $state PendingReboot 'Previous environment restored; restart Windows to verify its drivers.'
            return (New-OperationResult PendingReboot RebootRequired 'Rollback requires a restart.' @($Cause))
        }
        if($installationMode){$latest=Read-EnvironmentManifest $Context $source.Slot;$source|Add-Member Acls (Get-ObjectValue $latest Acls @()) -Force}
        return (Complete-GHUBTransaction $Context $source)
    } catch {
        $state=Read-SwitchState $Context
        $state.Phase='RecoveryRequired';$state.Sequence++;$state.LastError=$Cause+' | Recovery: '+$_.Exception.Message;$state.Health='Unverified'
        Write-SwitchState $Context $state; Publish-SwitchStatus $Context $state 'Recovery needs attention. Backups and both environments were retained.'
        New-OperationResult RecoveryRequired RecoveryRequired $state.LastError
    }
}
function Resume-GHUBTransaction { param($Context)
    Assert-Administrator
    if(Get-ExternalRecoveryCheckpoint $Context){return (Resume-ExternalModernRecovery $Context)}
    $state=Read-SwitchState $Context; $decision=Get-BootDecision $state (Get-BootId)
    if ($decision.Action -eq 'SwitchModern') { return (Invoke-GHUBSwitch $Context modern) }
    if ($decision.Action -eq 'StartActive') { return (Invoke-GHUBSwitch $Context $state.Active) }
    $lease=Enter-SwitchLock $Context
    try {
        # The boot/login trigger can race with a manual worker; never use pre-lock state.
        $state=Read-SwitchState $Context; $decision=Get-BootDecision $state (Get-BootId)
        if ($decision.Action -eq 'WaitForReboot' -and -not (Test-InstallationConfigurationMode $Context)) {
            $manifest=Read-EnvironmentManifest $Context $state.Target
            if (-not (Test-GHUBChildRebootSatisfied $Context $manifest)) { return (New-OperationResult PendingReboot RebootRequired 'Restart Windows is still required.') }
        }
        if ($decision.Action -notin @('Recover','Resume','WaitForReboot')) { return (New-OperationResult Blocked Busy 'State changed while waiting for recovery; retry using the current state.') }
        if ($decision.Action -eq 'Recover') { return (Invoke-GHUBRollback $Context 'Interrupted transaction detected.') }
        try { return (Complete-GHUBTransaction $Context (Read-EnvironmentManifest $Context $state.Target)) }
        catch { return (Invoke-GHUBRollback $Context $_.Exception.Message) }
    } finally { $lease.Dispose() }
}
function Restore-GHUBEnvironment { param($Context,[string]$TargetSlot='modern')
    $state=Read-SwitchState $Context
    if(Get-ExternalRecoveryCheckpoint $Context $state){return (Resume-ExternalModernRecovery $Context)}
    if ($state.Phase -eq 'Idle') { return (Invoke-GHUBSwitch $Context $TargetSlot) }
    $lease=Enter-SwitchLock $Context
    try { Invoke-GHUBRollback $Context 'User requested recovery.' } finally {$lease.Dispose()}
}
function Watch-GHUBEnvironment { param($Context)
    Assert-Administrator
    if(Test-InstallationConfigurationMode $Context){return}
    while ($true) {
        Start-Sleep -Seconds 5
        $observed=Read-SwitchState $Context
        if ($observed.Phase -ne 'Idle') { continue }
        $inventory=Get-GHUBInventory $Context
        if (-not @($inventory.Processes).Count) { return }
        $manifest=Read-EnvironmentManifest $Context $observed.Active
        $driver=Test-DriverState $Context $manifest
        if ($driver.TechnicalPassed -and $inventory.ProductVersion -eq $manifest.ProductVersion) { continue }
        $lease=$null
        try {
            $lease=Enter-SwitchLock $Context; $current=Read-SwitchState $Context
            if (-not (Test-MonitorGeneration $observed $current)) { continue }
            Disable-LaunchTicket $Context
            $null=Stop-GHUBEnvironment $Context $manifest
            $current.Health='DriftDetected';$current.Sequence++;$current.LastError='Driver or program version changed outside maintenance.'
            Write-SwitchState $Context $current;Publish-SwitchStatus $Context $current $current.LastError
            return
        } finally {if($lease){$lease.Dispose()}}
    }
}
Export-ModuleMember -Function *-*
