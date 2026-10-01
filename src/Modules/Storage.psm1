Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Inventory.psm1') -DisableNameChecking

function Assert-NoReparsePoint { param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { Throw-SwitchError UnsafePath 'UNC, device and parent traversal paths are forbidden.' }
    $current=$full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -Force -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-SwitchError UnsafePath "Reparse point: $current" }
        }
        $parent=[IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }; $current=$parent.FullName
    }
    return $full.TrimEnd('\')
}
function Test-ManagedPath { param($Context,[string]$Path,[string]$Role)
    if ($Role -notin @('Program','LocalData','RoamingData','MachineData')) { Throw-SwitchError UnsafePath 'Invalid directory role.' }
    $full=Assert-NoReparsePoint $Path
    $dirs=Get-ActiveDirectories $Context
    $allowed=@($dirs[$Role],(Join-Path $Context.Root "Environments/modern/$Role"),(Join-Path $Context.Root "Environments/legacy/$Role"))
    if ($full -notin $allowed) { Throw-SwitchError UnsafePath "Not an exact managed directory: $full" }
    return $full
}
function Get-NativePathIdentity { param([string]$Path)
    Initialize-NativeLibrary
    [GHubSwitcher.PathApi]::Inspect($Path)
}
function Get-VerifiedPathIdentity { param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $info=Get-NativePathIdentity $full
    if ($info.IsReparsePoint) { Throw-SwitchError UnsafePath "Path identity is a link: $full" }
    $resolved=[string](Get-ObjectValue $info FinalPath '')
    if ($resolved.StartsWith('\\?\',[StringComparison]::Ordinal)) { $resolved=$resolved.Substring(4) }
    if ($resolved -notmatch '^[a-zA-Z]:[\\/]') { Throw-SwitchError UnsafePath "Path has no absolute local DOS identity: $full" }
    $resolved=[IO.Path]::GetFullPath($resolved)
    if (-not $full.TrimEnd('\').Equals($resolved.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
        Throw-SwitchError UnsafePath "Path resolves outside its requested location: $full"
    }
    return $info
}
function Get-DirectoryIdentity { param([string]$Path,$Context=$null)
    $full=Assert-NoReparsePoint $Path
    $info=Get-VerifiedPathIdentity $full
    $identity=[pscustomobject]@{VolumeSerial=$info.VolumeSerial;FileId=$info.FileId}
    if($Context){
        $role=Split-Path $full -Leaf
        foreach($entry in (Get-ActiveDirectories $Context).GetEnumerator()){if($entry.Value -ieq $full){$role=$entry.Key;break}}
        $identity|Add-Member -NotePropertyName TransferRoot -NotePropertyValue $Context.Root
        $identity|Add-Member -NotePropertyName Role -NotePropertyValue $role
    }
    return $identity
}
function Assert-GHUBPhysicalDirectories { param($Context)
    $directories=Get-ActiveDirectories $Context
    foreach ($role in $directories.Keys) {
        $path=$directories[$role]
        if (Test-Path -LiteralPath $path) {
            $null=Get-DirectoryIdentity $path
            if($role -in @('LocalData','RoamingData')){
                # Package redirection can affect individual config files while
                # the directory handle itself still resolves to the real profile.
                foreach($item in (Get-ChildItem -LiteralPath $path -Force)){
                    $null=Get-VerifiedPathIdentity $item.FullName
                }
            }
        }
    }
}
function Test-SameDirectoryIdentity { param([string]$Path,$Identity)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $actual=Get-DirectoryIdentity $Path
    if($actual.VolumeSerial -eq $Identity.VolumeSerial -and $actual.FileId -eq $Identity.FileId){return $true}
    return (Test-TransferredIdentity $Path $Identity $actual)
}
function Get-TreeFiles { param([string]$Root)
    $full=Assert-NoReparsePoint $Root
    $null=Get-VerifiedPathIdentity $full
    foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-SwitchError UnsafePath "Reparse point in tree: $($item.FullName)" }
        $null=Get-VerifiedPathIdentity $item.FullName
        [pscustomobject]@{Relative=$item.FullName.Substring($full.Length+1);IsDirectory=$item.PSIsContainer;Length=$(if($item.PSIsContainer){0}else{$item.Length});Sha256=$(if($item.PSIsContainer){''}else{(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()});Sddl=(Get-Acl -LiteralPath $item.FullName).Sddl}
    }
}
function Move-ManagedDirectory {
    param([string]$From,[string]$To,[ValidateRange(0,30000)][int]$RetryTimeoutMilliseconds=10000,$Context=$null,[string]$Role='')
    $identity=Get-DirectoryIdentity $From -Context $Context
    $null=Assert-NoReparsePoint $To
    if([IO.Path]::GetPathRoot($From) -ine [IO.Path]::GetPathRoot($To)){return (Invoke-CrossVolumeTransfer $Context $From $To $identity $Role)}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        if(-not(Test-SameDirectoryIdentity $From $identity)){Throw-SwitchError ExternalChange 'The directory identity changed while waiting for its file handles to close.'}
        try{[IO.Directory]::Move($From,$To);return}catch{
            $exception=$_.Exception;$sharingLock=$false
            while($exception){
                if($exception -is [IO.IOException] -and ($exception.HResult -band 65535) -in @(32,33)){$sharingLock=$true;break}
                $exception=$exception.InnerException
            }
            $remaining=$RetryTimeoutMilliseconds-$timer.ElapsedMilliseconds
            if(-not $sharingLock -or $remaining -le 0){throw}
            Start-Sleep -Milliseconds ([int][Math]::Min(250,$remaining))
        }
    }
}
function Invoke-DirectoryExchange { param($Context,[string]$SourceSlot,[string]$TargetSlot)
    Assert-Slot $SourceSlot; Assert-Slot $TargetSlot
    if ($SourceSlot -eq $TargetSlot) { return (New-OperationResult) }
    $state=Read-SwitchState $Context
    if (-not $state.TransactionId) { Throw-SwitchError InvalidManifest 'Missing active transaction.' }
    $dirs=Get-ActiveDirectories $Context
    $moves=@()
    foreach ($role in $dirs.Keys) {
        $active=Test-ManagedPath $Context $dirs[$role] $role
        $park=Test-ManagedPath $Context (Join-Path $Context.Root "Environments/$SourceSlot/$role") $role
        $target=Test-ManagedPath $Context (Join-Path $Context.Root "Environments/$TargetSlot/$role") $role
        if (-not (Test-Path -LiteralPath $active) -or -not (Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $park)) { Throw-SwitchError UnsafePath "Unexpected directory state for $role" }
        $sourceId=Get-DirectoryIdentity $active -Context $Context; $targetId=Get-DirectoryIdentity $target -Context $Context
        $moves+=@([pscustomobject]@{Role=$role;From=$active;To=$park;Identity=$sourceId},[pscustomobject]@{Role=$role;From=$target;To=$active;Identity=$targetId})
    }
    $n=0
    foreach ($move in $moves) {
        $n++; $id="directory-$n"
        $null=Test-ManagedPath $Context $move.From $move.Role
        $null=Test-ManagedPath $Context $move.To $move.Role
        [IO.Directory]::CreateDirectory((Split-Path $move.To -Parent)) | Out-Null
        if (-not (Test-SameDirectoryIdentity $move.From $move.Identity)) { Throw-SwitchError UnsafePath 'Source identity changed.' }
        Add-JournalEntry $Context $state.TransactionId Intent $id $move $null
        Move-ManagedDirectory $move.From $move.To -Context $Context -Role $move.Role
        Add-JournalEntry $Context $state.TransactionId Done $id $move $null
    }
    New-OperationResult
}
function Undo-DirectoryExchange { param($Context,[string]$TransactionId)
    Repair-JournalTail $Context $TransactionId
    $journal=@(Read-ValidJournal $Context $TransactionId)
    $intents=@($journal | Where-Object { $_.Kind -eq 'Intent' -and $_.StepId -like 'directory-*' })
    # An administrator may explicitly reconcile a previously recorded app-package
    # view with physical user directories. Keep the original move records intact.
    $corrections=@($journal | Where-Object { $_.Kind -eq 'Checkpoint' -and $_.StepId -eq 'physical-directory-identities' })
    if($corrections.Count -gt 1){Throw-SwitchError RecoveryRequired 'Ambiguous physical directory reconciliation.'}
    if($corrections.Count){
        $record=$corrections[0].After
        if($record.TransactionId -cne $TransactionId -or $record.Reason -cne 'AppPackageRedirection' -or @($record.Changes).Count -notin @(1,2)){
            Throw-SwitchError RecoveryRequired 'Invalid physical directory reconciliation.'
        }
        $seen=@{};$active=Get-ActiveDirectories $Context
        foreach($change in $record.Changes){
            $matches=@($intents | Where-Object StepId -EQ $change.StepId)
            if($matches.Count -ne 1 -or $seen.ContainsKey($change.Role) -or $change.Role -notin @('LocalData','RoamingData')){Throw-SwitchError RecoveryRequired 'Invalid reconciled directory move.'}
            $entry=$matches[0];$move=$entry.Before
            if($corrections[0].Sequence -le $entry.Sequence -or $move.Role -cne $change.Role -or $move.From -ine $change.From -or $move.To -ine $change.To -or $move.To -ine $active[$change.Role] -or $move.From -in @($active.Values)){
                Throw-SwitchError RecoveryRequired 'Reconciliation does not match its original move.'
            }
            $null=Test-ManagedPath $Context $change.From $change.Role
            $null=Test-ManagedPath $Context $change.To $change.Role
            if($change.OriginalIdentity.VolumeSerial -ne $move.Identity.VolumeSerial -or $change.OriginalIdentity.FileId -cne $move.Identity.FileId -or $change.PhysicalIdentity.VolumeSerial -ne $move.Identity.VolumeSerial -or $change.PhysicalIdentity.FileId -notmatch '^[0-9a-fA-F]{16}$'){
                Throw-SwitchError RecoveryRequired 'Reconciliation identity differs from its original move.'
            }
            $seen[$change.Role]=$true
            $replacement=$move | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json
            $replacement.Identity=$change.PhysicalIdentity
            $entry.Before=$replacement
        }
    }
    [array]::Reverse($intents)
    foreach ($entry in $intents) {
        $move=$entry.Before
        $null=Test-ManagedPath $Context $move.From $move.Role; $null=Test-ManagedPath $Context $move.To $move.Role
        Resolve-InterruptedTransfer $Context $move.From $move.To $move.Identity -Rollback
        Resolve-InterruptedTransfer $Context $move.To $move.From $null -Rollback
        if (Test-SameDirectoryIdentity $move.From $move.Identity) { continue }
        if ((Test-Path -LiteralPath $move.From) -or -not (Test-SameDirectoryIdentity $move.To $move.Identity)) { Throw-SwitchError RecoveryRequired "Cannot identify directory for $($entry.StepId)." }
        Add-JournalEntry $Context $TransactionId Intent ('undo-'+$entry.StepId) $move $null
        Move-ManagedDirectory $move.To $move.From -Context $Context -Role $move.Role
        Add-JournalEntry $Context $TransactionId Done ('undo-'+$entry.StepId) $move $null
    }
    New-OperationResult
}
function New-EnvironmentBackup { param($Context,$Manifest)
    Assert-Slot $Manifest.Slot
    if ($Context.Mode -eq 'Live') {
        Assert-Administrator
        if (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^lghub.*\.exe$' }).Count -gt 0) { Throw-SwitchError Busy 'G HUB processes must be stopped before backup.' }
    }
    $source=Get-ActiveDirectories $Context
    $all=@(); $bytes=[long]0
    foreach ($role in $source.Keys) {
        $null=Test-ManagedPath $Context $source[$role] $role
        if (-not (Test-Path -LiteralPath $source[$role])) { Throw-SwitchError BackupInvalid "Missing directory: $role" }
        $files=@(Get-TreeFiles $source[$role])
        foreach($file in $files){$bytes+=[long]$file.Length}
        $all+=[pscustomobject]@{Role=$role;Files=$files;RootSddl=(Get-Acl -LiteralPath $source[$role]).Sddl}
    }
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Context.Root))
    if ($drive.AvailableFreeSpace -lt ($bytes+1GB)) { Throw-SwitchError InsufficientSpace 'Backup requires its complete size plus 1 GiB reserve.' }
    $id=$Manifest.Slot+'-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('N')
    $path=Join-Path $Context.Root "Backups/$id"
    $null=Assert-NoReparsePoint $path
    [IO.Directory]::CreateDirectory($path) | Out-Null
    foreach ($tree in $all) { Copy-Item -LiteralPath $source[$tree.Role] -Destination (Join-Path $path $tree.Role) -Recurse -Force }
    $backup=[pscustomobject]@{SchemaVersion=1;Path=$path;Slot=$Manifest.Slot;OwnerSid=$Context.OwnerSid;Trees=$all;Manifest=$Manifest;Complete=$true}
    Write-AtomicJson (Join-Path $path 'backup.json') $backup
    if (-not (Test-EnvironmentBackup $Context $backup)) { Throw-SwitchError BackupInvalid 'Copied backup failed verification.' }
    return $backup
}
function Test-EnvironmentBackup { param($Context,$Backup)
    try {
        $path=Assert-NoReparsePoint $Backup.Path
        $prefix=(Join-Path $Context.Root 'Backups').TrimEnd('\')+'\'
        if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $record=Read-AtomicJson (Join-Path $path 'backup.json')
        if (-not $record.Complete -or $record.OwnerSid -ne $Context.OwnerSid -or $record.SchemaVersion -ne 1) { return $false }
        foreach ($tree in $record.Trees) {
            $treePath=Join-Path $path $tree.Role
            $actual=@(Get-TreeFiles $treePath)
            if ($actual.Count -ne @($tree.Files).Count) { return $false }
            foreach ($file in $tree.Files) {
                $match=@($actual | Where-Object { $_.Relative -ceq $file.Relative })
                if ($match.Count -ne 1 -or $match[0].Sha256 -cne $file.Sha256 -or $match[0].IsDirectory -ne $file.IsDirectory) { return $false }
            }
        }
        return $true
    } catch { return $false }
}
function Restore-EnvironmentAcl { param($Context,[object[]]$Trees)
    $dirs=Get-ActiveDirectories $Context
    foreach($tree in $Trees){
        $path=Test-ManagedPath $Context $dirs[$tree.Role] $tree.Role
        Set-TransferAcl $path $tree.RootSddl $true
        foreach($item in $tree.Files){
            $child=Assert-NoReparsePoint (Join-Path $path $item.Relative)
            if(-not $child.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){Throw-SwitchError UnsafePath 'ACL target escaped its role directory.'}
            if(Test-Path -LiteralPath $child){Set-TransferAcl $child $item.Sddl $item.IsDirectory}
        }
    }
}
. (Join-Path $PSScriptRoot 'Transfers.ps1')
Export-ModuleMember -Function *-*
