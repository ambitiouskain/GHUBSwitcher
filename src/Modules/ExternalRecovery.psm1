Set-StrictMode -Version Latest
foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','InstallerAudit')){Import-Module (Join-Path $PSScriptRoot "$name.psm1") -DisableNameChecking}

function Assert-ExternalRecoveryPath {param($Context,[string]$Path,[string]$Area='Transactions')
    $full=Assert-NoReparsePoint $Path
    $base=if($Area){Join-Path $Context.Root $Area}else{$Context.Root}
    if(-not $full.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){Throw-SwitchError ExternalRecoveryInvalid 'Evidence path escaped the protected root.'}
    if($Context.Mode -eq 'Live'){
        $check=if(Test-Path -LiteralPath $full){$full}else{Split-Path $full -Parent}
        $acl=Get-Acl -LiteralPath $check
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            $writes=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
            if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writes) -ne 0 -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')){Throw-SwitchError ExternalRecoveryInvalid 'Recovery evidence is writable by an unprivileged principal.'}
        }
    }
    $full
}
function Get-ExternalManifestIdentity {param($Manifest,[switch]$BackupComparable)
    $copy=$Manifest|ConvertTo-Json -Depth 80|ConvertFrom-Json
    foreach($name in @('ExternalRecoveryEvidence','Qualification')){$copy.PSObject.Properties.Remove($name)}
    if($BackupComparable){foreach($name in @('BackupPath','Acls')){$copy.PSObject.Properties.Remove($name)}}
    Get-InstallerContentIdentity $copy
}
function Get-ExternalFileSet {param([object[]]$Files)
    $seen=@{}
    @($Files|Sort-Object Relative|ForEach-Object {
        if($seen.ContainsKey($_.Relative)){Throw-SwitchError ExternalRecoveryInvalid 'Duplicate file identity.'};$seen[$_.Relative]=$true
        [pscustomobject]@{Relative=$_.Relative;IsDirectory=[bool]$_.IsDirectory;Length=[long]$_.Length;Sha256=$_.Sha256}
    })
}
function Get-ExternalServiceIdentity {param($Service)
    $copy=$Service|ConvertTo-Json -Depth 40|ConvertFrom-Json
    foreach($name in @('State','Start','StartMode')){$copy.PSObject.Properties.Remove($name)}
    if(Get-ObjectValue $copy Native $null){foreach($name in @('CurrentState','ControlsAccepted','StartType')){$copy.Native.PSObject.Properties.Remove($name)}}
    Get-InstallerContentIdentity $copy
}
function Get-ExternalRecoverySnapshot {param($Context,$Manifest,[switch]$RequireQuiesced)
    $inventory=Get-GHUBInventory $Context
    Assert-GHUBProcessOwnership @($inventory.Processes) $Context.OwnerSid
    if($RequireQuiesced -and (@($inventory.Processes).Count -or @($inventory.Services|Where-Object {$_.State -ne 'Stopped' -or $_.Start -ne 4 -or $_.Native.StartType -ne 4}).Count)){Throw-SwitchError Busy 'External recovery confirmation requires stopped G HUB writers and disabled application services.'}
    if($inventory.ProductVersion -ne $Manifest.ProductVersion){Throw-SwitchError ExternalChange 'The current program version differs from the recovery candidate.'}
    $installationMode=Test-InstallationConfigurationMode $Context
    if(-not $installationMode){
    $wanted=@($Manifest.Devices|Sort-Object InstanceId|ForEach-Object {$copy=$_|ConvertTo-Json -Depth 30|ConvertFrom-Json;$copy.PSObject.Properties.Remove('PackageId');$copy})
    $present=@($inventory.Devices|Sort-Object InstanceId)
    if((Get-InstallerContentIdentity $wanted) -cne (Get-InstallerContentIdentity $present)){Throw-SwitchError ExternalChange 'The current driver topology differs from the recovery candidate.'}
    foreach($device in $Manifest.Devices){
        $actual=@($present|Where-Object InstanceId -EQ $device.InstanceId)
        if($actual.Count -ne 1 -or -not (Test-GHUBDeviceBinding $device $actual[0] @($Manifest.DriverPackages)).Passed){Throw-SwitchError ExternalChange 'The current driver binding or INF differs from the recovery candidate.'}
    }
    if((Get-InstallerContentIdentity @($Manifest.KernelServices|Sort-Object Name)) -cne (Get-InstallerContentIdentity @($inventory.KernelServices|Sort-Object Name))){Throw-SwitchError ExternalChange 'The current kernel service configuration differs from the recovery candidate.'}
    $filters=@($inventory.ClassFilters|Where-Object {$_.ClassGuid -in @($Manifest.Devices|ForEach-Object ClassGuid)}|Sort-Object ClassGuid)
    if((Get-InstallerContentIdentity @($Manifest.ClassFilters|Sort-Object ClassGuid)) -cne (Get-InstallerContentIdentity $filters)){Throw-SwitchError ExternalChange 'The current class filters differ from the recovery candidate.'}
    }
    $services=@($inventory.Services|Sort-Object Name)
    if($services.Count -ne @($Manifest.Services).Count){Throw-SwitchError ExternalChange 'The current application service set differs from the candidate.'}
    foreach($service in $Manifest.Services){
        $actual=@($services|Where-Object Name -EQ $service.Name)
        if($actual.Count -ne 1 -or (Get-ExternalServiceIdentity $actual[0]) -cne (Get-ExternalServiceIdentity $service)){Throw-SwitchError ExternalChange 'The application service configuration differs from the candidate.'}
    }
    # Process ids, service run state and inventory capture time are not identities.
    [pscustomobject]@{ProductVersion=$inventory.ProductVersion;Services=$services;Devices=@($inventory.Devices|Sort-Object InstanceId);KernelServices=@($inventory.KernelServices|Sort-Object Name);ClassFilters=@($inventory.ClassFilters|Sort-Object ClassGuid);ValidationMode=$(if($installationMode){'InstallationAndConfiguration'}else{'Strict'})}
}
function Assert-ExternalRecoverySnapshot {param($Expected,$Actual,[switch]$LaunchStarted)
    $fields=if((Get-ObjectValue $Actual ValidationMode '') -ceq 'InstallationAndConfiguration'){@('ProductVersion')}else{@('ProductVersion','Devices','KernelServices','ClassFilters')}
    foreach($name in $fields){
        if((Get-InstallerContentIdentity $Expected.$name) -cne (Get-InstallerContentIdentity $Actual.$name)){Throw-SwitchError ExternalChange "Recovery $name changed since confirmation."}
    }
    if(@($Expected.Services).Count -ne @($Actual.Services).Count){Throw-SwitchError ExternalChange 'Recovery service set changed.'}
    foreach($service in $Expected.Services){
        $current=@($Actual.Services|Where-Object Name -EQ $service.Name)
        if($current.Count -ne 1 -or (Get-ExternalServiceIdentity $service) -cne (Get-ExternalServiceIdentity $current[0])){Throw-SwitchError ExternalChange 'Recovery application service configuration changed.'}
        $allowed=@([int]$service.Start);if($LaunchStarted){$allowed+=3}
        if([int]$current[0].Start -notin $allowed -or [int]$current[0].Native.StartType -notin $allowed){Throw-SwitchError ExternalChange 'Recovery application service startup policy changed.'}
    }
}
function Assert-ExternalRecoveryBaseline {param($Context,$Manifest,[switch]$LaunchStarted)
    if($Manifest.Slot -ne 'modern' -or $Manifest.OwnerSid -ne $Context.OwnerSid -or $Manifest.Location -ne 'Active'){Throw-SwitchError ExternalRecoveryInvalid 'Only this owner active modern installation can be adopted.'}
    if(Get-ObjectValue $Manifest InstallerEvidence $null){Throw-SwitchError ExternalRecoveryInvalid 'External recovery cannot be combined with installer evidence.'}
    if((Test-UpdatePolicy $Context $Manifest).Status -ne 'Ok'){Throw-SwitchError ExternalRecoveryObservation 'The current version automatic update observation is missing.'}
    $backupPath=Assert-ExternalRecoveryPath $Context $Manifest.BackupPath Backups
    if(-not (Test-EnvironmentBackup $Context @{Path=$backupPath})){Throw-SwitchError ExternalRecoveryInvalid 'Recovery backup integrity failed.'}
    $backup=Read-AtomicJson (Join-Path $backupPath 'backup.json')
    if($backup.Slot -ne 'modern' -or $backup.Path -ine $backupPath -or (Get-ExternalManifestIdentity $backup.Manifest -BackupComparable) -cne (Get-ExternalManifestIdentity $Manifest -BackupComparable)){Throw-SwitchError ExternalRecoveryInvalid 'The complete backup does not belong to this candidate.'}
    if((Get-InstallerContentIdentity $Manifest.Acls) -cne (Get-InstallerContentIdentity $backup.Trees)){Throw-SwitchError ExternalRecoveryInvalid 'Candidate ACL restoration records do not belong to this backup.'}
    $dirs=Get-ActiveDirectories $Context
    if(@($backup.Trees).Count -ne 4){Throw-SwitchError ExternalRecoveryInvalid 'The backup must contain all four distinct managed roles.'}
    foreach($role in @('Program','LocalData','RoamingData','MachineData')){
        $path=Test-ManagedPath $Context (Get-ObjectValue $Manifest.Directories $role '') $role
        if($path -ine $dirs[$role] -or -not (Test-SameDirectoryIdentity $path (Get-ObjectValue $Manifest.DirectoryIdentities $role $null))){Throw-SwitchError ExternalChange "The current $role directory identity changed."}
        $tree=@($backup.Trees|Where-Object Role -EQ $role)
        if($tree.Count -ne 1){Throw-SwitchError ExternalRecoveryInvalid 'Duplicate or missing backup role.'}
        $expected=Get-InstallerContentIdentity @(Get-ExternalFileSet $tree[0].Files)
        if(-not $LaunchStarted -or $role -eq 'Program'){
            if($expected -cne (Get-InstallerContentIdentity @(Get-ExternalFileSet @(Get-TreeFiles $path)))){Throw-SwitchError ExternalChange "The current $role files differ from the confirmed recovery baseline."}
        }
        if($role -eq 'Program'){
            if((Get-InstallerContentIdentity @(Get-ExternalFileSet @($tree[0].Files|Where-Object {-not $_.IsDirectory}))) -cne (Get-InstallerContentIdentity @(Get-ExternalFileSet $Manifest.Files))){Throw-SwitchError ExternalRecoveryInvalid 'Candidate program hashes differ from the backup.'}
        }
    }
    if(-not (Test-InstallationConfigurationMode $Context)){foreach($package in $Manifest.DriverPackages){Assert-DriverPackage $Context $package}}
    if($Context.Mode -eq 'Live'){
        foreach($name in @('lghub.exe','lghub_agent.exe')){
            $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $dirs.Program $name)
            if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Logitech Inc'){Throw-SwitchError InvalidSignature 'Current recovery executables need valid Logitech signatures.'}
        }
    }
}
function Assert-ExternalRecoveryObservation {param($Context,$Manifest,$Observation)
    if((Get-ObjectValue $Observation ObserverSid '') -ne $Context.OwnerSid -or (Get-ObjectValue $Observation ProductVersion '') -ne $Manifest.ProductVersion -or (Get-ObjectValue $Observation ConfigurationRestored $false) -ne $true -or (Get-ObjectValue $Observation AutomaticUpdatesDisabled $false) -ne $true -or -not (Get-ObjectValue $Observation Statement '') -or (Get-ObjectValue $Observation BackupPath '') -ine $Manifest.BackupPath){Throw-SwitchError ExternalRecoveryObservation 'A current-version user observation of restored configuration and disabled updates, bound to this backup, is required.'}
    try{$time=ConvertTo-UtcTime $Observation.ObservedUtc;if($time -gt [DateTime]::UtcNow.AddMinutes(5)){throw 'future'}}catch{Throw-SwitchError ExternalRecoveryObservation 'The user observation needs a valid observation time.'}
}
function Save-ExternalRecoveryArtifact {param($Context,[string]$Id,[string]$Name,[string]$SourcePath,$Value)
    $path=Assert-ExternalRecoveryPath $Context (Join-Path $Context.Root "Transactions/$Id-external-$Name.json")
    if(Test-Path -LiteralPath $path){Throw-SwitchError ExternalRecoveryInvalid 'An evidence artifact already exists.'}
    if($SourcePath){$source=Assert-ExternalRecoveryPath $Context $SourcePath '';[IO.File]::Copy($source,$path)}else{Write-AtomicJson $path $Value}
    [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();SourcePath=$SourcePath}
}
function Read-ExternalRecoveryArtifact {param($Context,$Reference,[switch]$Raw)
    $path=Assert-ExternalRecoveryPath $Context $Reference.Path
    if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Reference.Sha256){Throw-SwitchError ExternalRecoveryInvalid 'Recovery evidence artifact hash changed.'}
    if($Raw){return [IO.File]::ReadAllText($path)}
    Read-AtomicJson $path
}
function Get-ExternalRecoveryCheckpoint {param($Context,$State=$null)
    if(-not $State){$State=Read-SwitchState $Context}
    if($State.Phase -eq 'Idle' -or -not $State.TransactionId){return $null}
    $entries=@(Read-ValidJournal $Context $State.TransactionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'external-recovery-adoption'})
    if($entries.Count -gt 1){Throw-SwitchError ExternalRecoveryInvalid 'Ambiguous adoption checkpoint.'}
    if($entries.Count){return $entries[0]}
    # This durable marker closes the journal-before-state crash window. It never points back to a rollback source.
    $pendingPath=Join-Path $Context.Root 'State/external-recovery-pending.json'
    if(Test-Path -LiteralPath $pendingPath){
        $pending=Read-AtomicJson (Assert-ExternalRecoveryPath $Context $pendingPath State)
        $report=Read-ExternalRecoveryArtifact $Context $pending.Evidence
        if($State.TransactionId -eq $report.PriorTransactionId){
            $prior=Read-ExternalRecoveryArtifact $Context $report.Artifacts.State
            if((Get-InstallerContentIdentity $State) -cne (Get-InstallerContentIdentity $prior)){Throw-SwitchError ExternalChange 'State changed during pending external recovery adoption.'}
            return [pscustomobject]@{Kind='Checkpoint';StepId='external-recovery-adoption';Before=$prior;After=$pending.Evidence}
        }
    }
    return $null
}
function Confirm-ExternalModernRecovery {param($Context,[string]$CandidatePath,$ExpectedState,[string]$PreviousManifestPath,$UserObservation)
    if($Context.Mode -eq 'Live'){Assert-Administrator}
    $lease=Enter-SwitchLock $Context
    try{
        $state=Read-SwitchState $Context
        if((Get-InstallerContentIdentity $state) -cne (Get-InstallerContentIdentity $ExpectedState) -or $state.Phase -ne 'RecoveryRequired' -or $state.Active -ne 'modern' -or $state.Target -ne 'modern'){Throw-SwitchError ExternalChange 'Recovery state changed or is not eligible for external modern adoption.'}
        if(Get-ExternalRecoveryCheckpoint $Context $state){Throw-SwitchError ExternalRecoveryInvalid 'Resume the existing adoption instead of confirming another.'}
        $candidatePath=Assert-ExternalRecoveryPath $Context $CandidatePath ''
        $previousPath=Assert-ExternalRecoveryPath $Context $PreviousManifestPath ''
        if($previousPath -ine (Join-Path $Context.Root 'Manifests/modern.json')){Throw-SwitchError ExternalRecoveryInvalid 'The original modern manifest must be retained.'}
        $candidate=Read-AtomicJson $candidatePath
        Assert-ExternalRecoveryObservation $Context $candidate $UserObservation
        Assert-ExternalRecoveryBaseline $Context $candidate
        $snapshot=Get-ExternalRecoverySnapshot $Context $candidate -RequireQuiesced
        $registration=Read-AtomicJson (Join-Path $Context.Root 'registration.json')
        $previous=Read-AtomicJson $previousPath
        if($registration.OwnerSid -ne $Context.OwnerSid -or $registration.ProfileRoot -ine $Context.ProfileRoot -or $previous.OwnerSid -ne $Context.OwnerSid -or $previous.Slot -ne 'modern'){Throw-SwitchError OwnerMismatch 'Previous registration does not belong to this owner.'}
        $id=[guid]::NewGuid().ToString('N');$artifacts=[ordered]@{}
        $artifacts.State=Save-ExternalRecoveryArtifact $Context $id state (Join-Path $Context.Root 'State/state.json')
        $artifacts.PreviousManifest=Save-ExternalRecoveryArtifact $Context $id previous-manifest $previousPath
        $artifacts.Registration=Save-ExternalRecoveryArtifact $Context $id registration (Join-Path $Context.Root 'registration.json')
        $artifacts.Candidate=Save-ExternalRecoveryArtifact $Context $id candidate $candidatePath
        $artifacts.Backup=Save-ExternalRecoveryArtifact $Context $id backup (Join-Path $candidate.BackupPath 'backup.json')
        $artifacts.Observation=Save-ExternalRecoveryArtifact $Context $id observation '' $UserObservation
        $artifacts.Snapshot=Save-ExternalRecoveryArtifact $Context $id snapshot '' $snapshot
        $tasks=@();if($Context.Mode -eq 'Live'){$tasks=@(Get-ScheduledTask|Where-Object TaskName -Like 'GHUBSwitcher-*'|ForEach-Object {@{Name=$_.TaskName;Path=$_.TaskPath;State=[string]$_.State;Xml=(Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath)}})}
        $artifacts.Tasks=Save-ExternalRecoveryArtifact $Context $id tasks '' @{Tasks=@($tasks)}
        $prior=@()
        if($state.TransactionId){
            Assert-SafeIdentifier $state.TransactionId
            foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Context.Root 'Transactions') -File|Where-Object {$_.Name -eq ($state.TransactionId+'.jsonl') -or $_.Name.StartsWith($state.TransactionId+'-',[StringComparison]::OrdinalIgnoreCase)})){
                $prior+=Save-ExternalRecoveryArtifact $Context $id ('prior-'+$prior.Count) $file.FullName
            }
        }
        $report=[pscustomobject]@{SchemaVersion=1;Kind='ExternalModernRecovery';AdoptionId=$id;OwnerSid=$Context.OwnerSid;ProductVersion=$candidate.ProductVersion;InstallationObserved=$false;Scope='Current restored modern baseline only; the external installation process was not observed.';PriorTransactionId=$state.TransactionId;BootId=(Get-BootId);CapturedUtc=[DateTime]::UtcNow.ToString('o');ManifestIdentity=(Get-ExternalManifestIdentity $candidate);Artifacts=$artifacts;PriorArtifacts=$prior}
        $path=Join-Path $Context.Root "Transactions/$id-external-recovery-evidence.json";Write-AtomicJson $path $report
        [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();AdoptionId=$id;ProductVersion=$candidate.ProductVersion}
    }finally{$lease.Dispose()}
}
function Test-ExternalRecoveryEvidence {param($Context,$Evidence,$Manifest)
    $report=Read-ExternalRecoveryArtifact $Context $Evidence
    if($report.SchemaVersion -ne 1 -or $report.Kind -ne 'ExternalModernRecovery' -or $report.InstallationObserved -ne $false -or $report.OwnerSid -ne $Context.OwnerSid -or $report.AdoptionId -cne $Evidence.AdoptionId -or $report.ProductVersion -ne $Manifest.ProductVersion -or $Manifest.Slot -ne 'modern' -or $report.ManifestIdentity -cne (Get-ExternalManifestIdentity $Manifest)){Throw-SwitchError ExternalRecoveryInvalid 'The evidence does not identify this modern candidate.'}
    Assert-SafeIdentifier $report.AdoptionId
    $seen=@{}
    foreach($reference in @($report.Artifacts.PSObject.Properties|ForEach-Object Value)+@($report.PriorArtifacts)){
        if($seen.ContainsKey($reference.Path)){Throw-SwitchError ExternalRecoveryInvalid 'Duplicate evidence artifact identity.'};$seen[$reference.Path]=$true
        $null=Read-ExternalRecoveryArtifact $Context $reference -Raw
    }
    $savedState=Read-ExternalRecoveryArtifact $Context $report.Artifacts.State
    Assert-SwitchState $Context $savedState
    if($savedState.TransactionId -cne $report.PriorTransactionId){Throw-SwitchError ExternalRecoveryInvalid 'Prior transaction identity mismatch.'}
    $savedCandidate=Read-ExternalRecoveryArtifact $Context $report.Artifacts.Candidate
    if((Get-ExternalManifestIdentity $savedCandidate) -cne $report.ManifestIdentity){Throw-SwitchError ExternalRecoveryInvalid 'The preserved candidate was changed.'}
    Assert-ExternalRecoveryObservation $Context $Manifest (Read-ExternalRecoveryArtifact $Context $report.Artifacts.Observation)
    $state=Read-SwitchState $Context;$checkpoint=Get-ExternalRecoveryCheckpoint $Context $state
    $launchStarted=$false
    if($state.TransactionId -ceq $report.AdoptionId){
        if(-not $checkpoint -or (Get-InstallerContentIdentity $checkpoint.After) -cne (Get-InstallerContentIdentity $Evidence) -or $state.Active -ne 'modern' -or $state.Target -ne 'modern' -or $state.Phase -notin @('Maintenance','Verifying','RecoveryRequired') -or $state.Sequence -le $savedState.Sequence){Throw-SwitchError ExternalRecoveryInvalid 'Adoption state does not match its checkpoint.'}
        $launchStarted=@(Read-ValidJournal $Context $state.TransactionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'external-recovery-launch'}).Count -gt 0
    }elseif((Get-InstallerContentIdentity $state) -cne (Get-InstallerContentIdentity $savedState)){Throw-SwitchError ExternalChange 'Current state changed after recovery confirmation.'}
    foreach($name in @('Registration','Backup','Candidate')){
        $reference=$report.Artifacts.$name
        $path=Assert-ExternalRecoveryPath $Context $reference.SourcePath ''
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $reference.Sha256){Throw-SwitchError ExternalChange "Current $name identity changed after recovery confirmation."}
    }
    $previousPath=Assert-ExternalRecoveryPath $Context $report.Artifacts.PreviousManifest.SourcePath Manifests
    $currentManifest=Read-AtomicJson $previousPath
    $oldMatches=(Get-FileHash -LiteralPath $previousPath).Hash.ToLowerInvariant() -ceq $report.Artifacts.PreviousManifest.Sha256
    if(-not $oldMatches -and (-not $checkpoint -or (Get-ExternalManifestIdentity $currentManifest) -cne $report.ManifestIdentity)){Throw-SwitchError ExternalChange 'The previous modern manifest changed before adoption.'}
    Assert-ExternalRecoveryBaseline $Context $Manifest -LaunchStarted:$launchStarted
    $expected=Read-ExternalRecoveryArtifact $Context $report.Artifacts.Snapshot
    Assert-ExternalRecoverySnapshot $expected (Get-ExternalRecoverySnapshot $Context $Manifest -RequireQuiesced:(-not $launchStarted)) -LaunchStarted:$launchStarted
    return $true
}
function Adopt-ExternalModernEnvironment {param($Context,$Evidence,[switch]$VerifyOnly,[switch]$DeferLaunch)
    if($Context.Mode -eq 'Live'){Assert-Administrator}
    $lease=Enter-SwitchLock $Context
    try{
        $report=Read-ExternalRecoveryArtifact $Context $Evidence
        $manifest=Read-ExternalRecoveryArtifact $Context $report.Artifacts.Candidate
        $manifest|Add-Member ExternalRecoveryEvidence $Evidence -Force
        $null=Test-ExternalRecoveryEvidence $Context $Evidence $manifest
        if($VerifyOnly){return (New-OperationResult Ok ExternalRecoveryVerified 'The current modern recovery baseline is verified.')}
        $state=Read-SwitchState $Context
        if($state.TransactionId -ne $report.AdoptionId){
            # The journal is durable before the only dedicated RecoveryRequired -> Maintenance transition.
            Write-AtomicJson (Join-Path $Context.Root 'State/external-recovery-pending.json') @{Evidence=$Evidence}
            Repair-JournalTail $Context $report.AdoptionId
            $existing=@(Read-ValidJournal $Context $report.AdoptionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'external-recovery-adoption'})
            if(-not $existing.Count){Add-JournalEntry $Context $report.AdoptionId Checkpoint external-recovery-adoption $state $Evidence}
            elseif($existing.Count -ne 1 -or (Get-InstallerContentIdentity $existing[0].After) -cne (Get-InstallerContentIdentity $Evidence)){Throw-SwitchError ExternalRecoveryInvalid 'Conflicting adoption journal.'}
            $state.TransactionId=$report.AdoptionId;$state.Phase='Maintenance';$state.Target='modern';$state.Health='Unverified';$state.LastError=$null;$state.Sequence++
            Write-SwitchState $Context $state
        }
        Disable-LaunchTicket $Context
        # Import only at the registration boundary; Bootstrap imports this module as well.
        if(-not (Get-Command Register-Environment -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -DisableNameChecking}
        Register-Environment $Context $manifest
        Publish-SwitchStatus $Context $state 'Recovered modern is prepared; controlled launch and health verification remain.'
        if($DeferLaunch){return (New-OperationResult Prepared ExternalRecoveryPrepared 'Modern recovery registered; launch is deferred.' $Evidence)}
    }finally{$lease.Dispose()}
    Complete-ExternalModernRecovery $Context
}
function Complete-ExternalModernRecovery {param($Context,[switch]$DeferLaunch)
    if($Context.Mode -eq 'Live'){Assert-Administrator}
    $lease=Enter-SwitchLock $Context
    try{
        $state=Read-SwitchState $Context;$checkpoint=Get-ExternalRecoveryCheckpoint $Context $state
        if(-not $checkpoint){Throw-SwitchError ExternalRecoveryInvalid 'There is no adoption transaction to complete.'}
        $report=Read-ExternalRecoveryArtifact $Context $checkpoint.After
        if($state.TransactionId -cne $report.AdoptionId){Throw-SwitchError ExternalRecoveryInvalid 'Use dedicated resume to persist the new adoption state before completion.'}
        $manifest=Read-ExternalRecoveryArtifact $Context $report.Artifacts.Candidate
        $manifest|Add-Member ExternalRecoveryEvidence $checkpoint.After -Force
        try{
            $null=Test-ExternalRecoveryEvidence $Context $checkpoint.After $manifest
            if(-not (Get-Command Register-Environment -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -DisableNameChecking}
            Register-Environment $Context $manifest
            if($DeferLaunch){return (New-OperationResult Prepared ExternalRecoveryPrepared 'Modern recovery registered; launch is deferred.')}
            if(Test-InstallationConfigurationMode $Context){return (Complete-GHUBInstallationTransaction $Context $manifest)}
            $health=Get-GHUBHealth $Context $manifest -BeforeLaunch
            if(-not $health.TechnicalPassed){Throw-SwitchError HealthCheckFailed 'Current modern failed the recovery pre-launch checks.'}
            Repair-JournalTail $Context $state.TransactionId
            $launch=@(Read-ValidJournal $Context $state.TransactionId|Where-Object {$_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'external-recovery-launch'})
            if(-not $launch.Count){Add-JournalEntry $Context $state.TransactionId Checkpoint external-recovery-launch $null @{Services=@($manifest.Services|ForEach-Object Name);Start=3}}
            $state.Phase='Maintenance';$state.Sequence++;Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state 'Verifying recovered modern without exchanging files or binding drivers.'
            foreach($service in $manifest.Services){Set-Service -Name $service.Name -StartupType Manual -ErrorAction Stop;Start-Service -Name $service.Name -ErrorAction Stop}
            $launchResult=Start-GHUBUserSession $Context $manifest
            if($launchResult.Status -eq 'AwaitingLogon'){Disable-LaunchTicket $Context;return $launchResult}
            $state=Save-Phase $Context $state Verifying
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            do{
                $health=Get-GHUBHealth $Context $manifest
                if($health.TechnicalPassed){break}
                Start-Sleep -Seconds 1
            }while([DateTime]::UtcNow -lt $deadline)
            if(-not $health.TechnicalPassed){Throw-SwitchError HealthCheckFailed 'Current modern failed the recovery post-launch checks.'}
            Add-JournalEntry $Context $state.TransactionId Checkpoint external-recovery-verified $null $health
            $manifest.Qualification='TechnicalPassed';Write-AtomicJson (Join-Path $Context.Root 'Manifests/modern.json') $manifest
            $state=Set-SwitchPhase $state Idle;$state.Active='modern';$state.Target=$null;$state.TransactionId=$null;$state.Health='TechnicalPassed';$state.BootId=Get-BootId;$state.RebootRequestedAtBootId=$null;$state.LastError=$null
            Write-SwitchState $Context $state;Publish-SwitchStatus $Context $state 'Recovered modern passed technical checks; startup control can now be enabled.'
            New-OperationResult Ok ExternalRecoveryAdopted 'The current modern installation was adopted; previous recovery evidence and user configuration were preserved.' $health
        }catch{
            $message=$_.Exception.Message;$state=Read-SwitchState $Context
            if($state.TransactionId -eq $report.AdoptionId){$state.Phase='RecoveryRequired';$state.Sequence++;$state.Health='Unverified';$state.LastError=$message;Write-SwitchState $Context $state;Disable-LaunchTicket $Context;Publish-SwitchStatus $Context $state 'Modern adoption needs attention; current files and settings were retained.'}
            New-OperationResult RecoveryRequired ExternalRecoveryRequired $message
        }
    }finally{$lease.Dispose()}
}
function Resume-ExternalModernRecovery {param($Context,[switch]$DeferLaunch)
    $state=Read-SwitchState $Context;$checkpoint=Get-ExternalRecoveryCheckpoint $Context $state
    if($checkpoint -and $state.TransactionId -ne $checkpoint.After.AdoptionId){return (Adopt-ExternalModernEnvironment $Context $checkpoint.After -DeferLaunch:$DeferLaunch)}
    Complete-ExternalModernRecovery $Context -DeferLaunch:$DeferLaunch
}
Export-ModuleMember -Function *-External*
