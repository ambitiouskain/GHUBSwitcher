# Cross-volume moves have their own durable receipts. Source removal happens only
# after the complete target has been verified and the formal source was renamed.
function Get-TransferReceipts {param([string]$Root)
    $directory=Join-Path $Root 'State/Transfers'
    if(Test-Path -LiteralPath $directory){
        foreach($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File){
            $record=Read-AtomicJson $file.FullName
            if($record.SchemaVersion -ne 1 -or $record.Root -ine $Root -or $record.Id -notmatch '^[a-f0-9]{32}$' -or $record.Role -notin @('Program','LocalData','RoamingData','MachineData')){Throw-SwitchError RecoveryRequired 'Invalid transfer receipt.'}
            if($record.Stage -ine ($record.To+'.ghub-transfer-'+$record.Id) -or $record.Retained -ine ($record.From+'.ghub-transfer-'+$record.Id)){Throw-SwitchError RecoveryRequired 'Invalid transfer staging paths.'}
            $record
        }
    }
}
function Save-TransferReceipt {param($Record)
    Write-AtomicJson (Join-Path $Record.Root ('State/Transfers/'+$Record.Id+'.json')) $Record
}
function Test-NativeIdentity {param($A,$B)
    $null -ne $A -and $null -ne $B -and $A.VolumeSerial -eq $B.VolumeSerial -and $A.FileId -ceq $B.FileId
}
function Test-TransferredIdentity {param([string]$Path,$Expected,$Actual)
    $root=Get-ObjectValue $Expected TransferRoot ''
    if(-not $root){return $false}
    $role=Get-ObjectValue $Expected Role ''
    $records=@(Get-TransferReceipts $root|Where-Object {$_.Role -eq $role -and $_.Phase -in @('Promoting','TargetReady','Complete') -and $_.TargetIdentity})
    $current=$Expected;$visited=@{}
    for($n=0;$n -le $records.Count;$n++){
        $key=[string]$current.VolumeSerial+':'+$current.FileId
        if($visited.ContainsKey($key)){Throw-SwitchError RecoveryRequired 'Cyclic transfer identity history.'}
        $visited[$key]=$true
        $matches=@($records|Where-Object {Test-NativeIdentity $_.SourceIdentity $current})
        if($matches.Count -eq 0){return $false}
        if($matches.Count -ne 1){Throw-SwitchError RecoveryRequired 'Ambiguous transfer identity history.'}
        $record=$matches[0]
        if((Test-NativeIdentity $record.TargetIdentity $Actual) -and $record.To -ieq $Path){return $true}
        $current=$record.TargetIdentity
    }
    return $false
}
function Move-TransferDirectory {param([string]$From,[string]$To)
    Move-ManagedDirectory $From $To
}
function Remove-TransferTree {param([string]$Path,$Identity)
    $full=Assert-NoReparsePoint $Path
    if($full -notmatch '\.ghub-transfer-[a-f0-9]{32}$'){Throw-SwitchError UnsafePath 'Invalid transfer cleanup path.'}
    if(-not(Test-Path -LiteralPath $full)){return}
    if(-not(Test-NativeIdentity (Get-DirectoryIdentity $full) $Identity)){Throw-SwitchError RecoveryRequired 'Transfer cleanup directory was replaced.'}
    foreach($item in Get-ChildItem -LiteralPath $full -Recurse -Force){$null=Get-VerifiedPathIdentity $item.FullName}
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}
function Convert-TransferAcl {param([string]$Sddl,[bool]$IsDirectory)
    $acl=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $flags=[int]$acl.ControlFlags -bor [int][Security.AccessControl.ControlFlags]::DiscretionaryAclProtected
    $flags=$flags -band (-bnot ([int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited -bor [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInheritRequired))
    $acl.SetFlags([Security.AccessControl.ControlFlags]$flags)
    foreach($ace in $acl.DiscretionaryAcl){
        $ace.AceFlags=[Security.AccessControl.AceFlags]([int]$ace.AceFlags -band (-bnot [int][Security.AccessControl.AceFlags]::Inherited))
    }
    return $acl
}
function Get-TransferAclSignature {param([string]$Sddl,[bool]$IsDirectory)
    $acl=Convert-TransferAcl $Sddl $IsDirectory
    $rules=@(foreach($ace in $acl.DiscretionaryAcl){
        $bytes=[byte[]]::new($ace.BinaryLength);$ace.GetBinaryForm($bytes,0);[BitConverter]::ToString($bytes)
    })
    (@($rules|Sort-Object) -join '|')
}
function Set-TransferAcl {param([string]$Path,[string]$Sddl,[bool]$IsDirectory)
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    $normalized=Convert-TransferAcl $Sddl $IsDirectory
    $acl.SetSecurityDescriptorSddlForm($normalized.GetSddlForm([Security.AccessControl.AccessControlSections]::Access),[Security.AccessControl.AccessControlSections]::Access)
    if($IsDirectory){[IO.Directory]::SetAccessControl($Path,$acl)}else{[IO.File]::SetAccessControl($Path,$acl)}
}
function Copy-TransferTree {param([string]$From,[string]$To,$Trees)
    foreach($item in $Trees.Files|Where-Object IsDirectory|Sort-Object {$_.Relative.Length}){
        [IO.Directory]::CreateDirectory((Join-Path $To $item.Relative))|Out-Null
    }
    foreach($item in $Trees.Files|Where-Object {-not $_.IsDirectory}){
        $path=Join-Path $To $item.Relative
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
        Copy-Item -LiteralPath (Join-Path $From $item.Relative) -Destination $path
    }
    foreach($item in @($Trees.Files|Sort-Object {$_.Relative.Length} -Descending)){
        $path=Join-Path $To $item.Relative
        Set-TransferAcl $path $item.Sddl $item.IsDirectory
    }
    Set-TransferAcl $To $Trees.RootSddl $true
}
function Test-TransferTree {param([string]$Path,$Trees)
    $actual=@(Get-TreeFiles $Path)
    if($actual.Count -ne @($Trees.Files).Count){return $false}
    if((Get-TransferAclSignature (Get-Acl -LiteralPath $Path).Sddl $true) -cne (Get-TransferAclSignature $Trees.RootSddl $true)){return $false}
    foreach($item in $Trees.Files){
        $match=@($actual|Where-Object Relative -CEQ $item.Relative)
        if($match.Count -ne 1 -or $match[0].Sha256 -cne $item.Sha256 -or $match[0].IsDirectory -ne $item.IsDirectory){return $false}
        if((Get-TransferAclSignature $match[0].Sddl $item.IsDirectory) -cne (Get-TransferAclSignature $item.Sddl $item.IsDirectory)){return $false}
    }
    return $true
}
function Get-TransferFreeSpace {param([string]$Path)
    ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
}
function Resolve-InterruptedTransfer {param($Context,[string]$From,[string]$To,$Identity,[switch]$Rollback)
    $records=@(Get-TransferReceipts $Context.Root|Where-Object {$_.From -ieq $From -and $_.To -ieq $To -and $_.Phase -notin @('Complete','RolledBack')})
    if($records.Count -gt 1){Throw-SwitchError RecoveryRequired 'Ambiguous pending transfer.'}
    if(-not $records.Count){return}
    $record=$records[0]
    if($Identity -and -not(Test-NativeIdentity $Identity $record.SourceIdentity)){Throw-SwitchError RecoveryRequired 'Pending transfer does not match its operation.'}
    if(Test-Path -LiteralPath $To){
        if(-not $record.TargetIdentity -or -not(Test-NativeIdentity (Get-DirectoryIdentity $To) $record.TargetIdentity)){Throw-SwitchError RecoveryRequired 'Transferred target was replaced.'}
        # The target is complete. A partially deleted retained source must never
        # be put back over it or mistaken for an untouched formal source.
        if(Test-Path -LiteralPath $record.Retained){Remove-TransferTree $record.Retained $record.SourceIdentity}
        $record.Phase='Complete';Save-TransferReceipt $record
        return
    }
    if(-not $Rollback){Throw-SwitchError RecoveryRequired 'Resume this interrupted transfer through the recovery menu.'}
    if(Test-Path -LiteralPath $record.Retained){
        if((Test-Path -LiteralPath $From) -or -not(Test-NativeIdentity (Get-DirectoryIdentity $record.Retained) $record.SourceIdentity)){Throw-SwitchError RecoveryRequired 'Retained transfer source was replaced.'}
        Move-TransferDirectory $record.Retained $From
    }
    if(-not(Test-Path -LiteralPath $From) -or -not(Test-NativeIdentity (Get-DirectoryIdentity $From) $record.SourceIdentity) -or -not(Test-TransferTree $From $record.Trees)){Throw-SwitchError RecoveryRequired 'Complete transfer source is unavailable.'}
    if(Test-Path -LiteralPath $record.Stage){
        if(-not $record.StageIdentity -and $record.Phase -eq 'Copying'){
            # Creation precedes identity persistence. No copy can have begun in
            # this window; use nonrecursive deletion, preserving unexpected data.
            $null=Assert-NoReparsePoint $record.Stage
            [IO.Directory]::Delete($record.Stage,$false)
        }else{Remove-TransferTree $record.Stage $record.StageIdentity}
    }
    $record.Phase='RolledBack';Save-TransferReceipt $record
}
function Invoke-CrossVolumeTransfer {param($Context,[string]$From,[string]$To,$Identity,[string]$Role)
    if(-not $Context -or $Role -notin @('Program','LocalData','RoamingData','MachineData')){Throw-SwitchError UnsafePath 'Cross-volume moves require a managed context and role.'}
    $trees=[pscustomobject]@{Files=@(Get-TreeFiles $From);RootSddl=(Get-Acl -LiteralPath $From).Sddl}
    $bytes=[long]0;foreach($item in $trees.Files){$bytes+=[long]$item.Length}
    if((Get-TransferFreeSpace $To) -lt ($bytes+1GB)){Throw-SwitchError InsufficientSpace 'Cross-volume transfer requires its size plus 1 GiB reserve.'}
    $id=[guid]::NewGuid().ToString('N')
    $record=[pscustomobject]@{SchemaVersion=1;Id=$id;Root=$Context.Root;Role=$Role;From=$From;To=$To;Stage=($To+'.ghub-transfer-'+$id);Retained=($From+'.ghub-transfer-'+$id);SourceIdentity=$Identity;StageIdentity=$null;TargetIdentity=$null;Trees=$trees;Phase='Copying'}
    $null=Assert-NoReparsePoint $record.Stage;$null=Assert-NoReparsePoint $record.Retained
    Save-TransferReceipt $record
    [IO.Directory]::CreateDirectory($record.Stage)|Out-Null
    $record.StageIdentity=Get-DirectoryIdentity $record.Stage;Save-TransferReceipt $record
    Copy-TransferTree $From $record.Stage $trees
    if(-not(Test-TransferTree $record.Stage $trees) -or -not(Test-TransferTree $From $trees)){Throw-SwitchError IntegrityError 'Cross-volume copy verification failed.'}
    if(-not(Test-NativeIdentity (Get-DirectoryIdentity $From) $Identity)){Throw-SwitchError ExternalChange 'Transfer source was replaced.'}
    $record.Phase='PreservingSource';Save-TransferReceipt $record
    Move-TransferDirectory $From $record.Retained
    $record.TargetIdentity=$record.StageIdentity;$record.Phase='Promoting';Save-TransferReceipt $record
    Move-TransferDirectory $record.Stage $To
    $record.Phase='TargetReady';Save-TransferReceipt $record
    Remove-TransferTree $record.Retained $record.SourceIdentity
    $record.Phase='Complete';Save-TransferReceipt $record
}
