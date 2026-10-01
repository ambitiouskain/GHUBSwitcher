Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Throw-SwitchError { param([string]$Code,[string]$Message) throw "$Code`: $Message" }
function Get-ObjectValue { param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } }
    elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-Sha256 { param([byte[]]$Bytes)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-TextHash { param([string]$Text) Get-Sha256 ([Text.Encoding]::UTF8.GetBytes($Text)) }
function ConvertTo-UtcTime {param($Value)
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function ConvertTo-Envelope { param($Value)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 80 -Compress))
    [ordered]@{Payload=[Convert]::ToBase64String($bytes);Sha256=(Get-Sha256 $bytes)} | ConvertTo-Json -Compress
}
function ConvertFrom-Envelope { param([string]$Text)
    try {
        $envRecord=$Text | ConvertFrom-Json
        $bytes=[Convert]::FromBase64String($envRecord.Payload)
        if ((Get-Sha256 $bytes) -cne $envRecord.Sha256) { throw 'hash mismatch' }
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch { Throw-SwitchError IntegrityError 'JSON envelope is incomplete or corrupted.' }
}
function Write-DurableText { param([string]$Path,[string]$Text,[switch]$Append)
    $mode=[IO.FileMode]::Create
    if ($Append) { $mode=[IO.FileMode]::Append }
    $file=[IO.FileStream]::new($Path,$mode,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try { $data=[Text.Encoding]::UTF8.GetBytes($Text); $file.Write($data,0,$data.Length); $file.Flush($true) }
    finally { $file.Dispose() }
}
function Write-AtomicJson { param([string]$Path,$Value)
    $parent=Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp=Join-Path $parent ((Split-Path $Path -Leaf)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    Write-DurableText $temp (ConvertTo-Envelope $Value)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,($Path+'.bak'),$false) }
    else { [IO.File]::Move($temp,$Path) }
}
function Read-AtomicJson { param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { Throw-SwitchError MissingState $Path }
    ConvertFrom-Envelope ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))
}
function Test-InstallationConfigurationMode {param($Context)
    $path=Join-Path $Context.Root 'registration.json'
    if(-not [IO.File]::Exists($path)){return $false}
    $registration=Read-AtomicJson $path
    if((Get-ObjectValue $registration ValidationMode '') -cne 'InstallationAndConfiguration'){return $false}
    if((Get-ObjectValue $registration OwnerSid '') -cne $Context.OwnerSid){Throw-SwitchError OwnerMismatch 'Acceptance settings belong to another user.'}
    return $true
}
function Test-IsAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Administrator { if (-not (Test-IsAdministrator)) { Throw-SwitchError AccessDenied 'Administrator privileges are required.' } }
function Assert-Slot { param([string]$Slot) if ($Slot -notin @('modern','legacy')) { Throw-SwitchError InvalidManifest 'Unknown environment slot.' } }
function Assert-SafeIdentifier { param([string]$Value) if ($Value -notmatch '^[A-Za-z0-9_-]{1,80}$') { Throw-SwitchError InvalidManifest 'Invalid identifier.' } }
function New-SwitchContext {
    param([string]$Root,[string]$OwnerSid,[string]$ProfileRoot,[ValidateSet('Live','Simulation')][string]$Mode='Live',$Platform=$null)
    if ($OwnerSid -notmatch '^S-1-\d+(-\d+)+$') { Throw-SwitchError OwnerMismatch 'Invalid owner SID.' }
    $fullRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $profile=[IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
    if ($Mode -eq 'Live' -and $fullRoot -ine (Join-Path $env:ProgramData 'GHUBSwitcher')) { Throw-SwitchError UnsafePath 'Live root must be the registered ProgramData location.' }
    [pscustomobject]@{SchemaVersion=1;Root=$fullRoot;OwnerSid=$OwnerSid;ProfileRoot=$profile;Mode=$Mode;Platform=$Platform}
}
function New-SwitchState { param($Context,[string]$Active,[string]$BootId)
    Assert-Slot $Active
    [pscustomobject][ordered]@{SchemaVersion=1;Sequence=0;Phase='Idle';Active=$Active;Target=$null;TransactionId=$null;OwnerSid=$Context.OwnerSid;BootId=$BootId;RebootRequestedAtBootId=$null;Health='Unverified';LastError=$null}
}
function Assert-SwitchState { param($Context,$State)
    $fields=@('SchemaVersion','Sequence','Phase','Active','Target','TransactionId','OwnerSid','BootId','RebootRequestedAtBootId','Health','LastError')
    $actual=@($State.PSObject.Properties.Name)
    if ($State -is [Collections.IDictionary]) { $actual=@($State.Keys) }
    if (@(Compare-Object $fields $actual).Count -ne 0 -or $State.SchemaVersion -ne 1) { Throw-SwitchError InvalidManifest 'Invalid state schema.' }
    if ($State.OwnerSid -ne $Context.OwnerSid) { Throw-SwitchError OwnerMismatch 'State belongs to another user.' }
    Assert-Slot $State.Active
    if ($null -ne $State.Target) { Assert-Slot $State.Target }
    if ($null -ne $State.TransactionId) { Assert-SafeIdentifier $State.TransactionId }
    if ($State.Phase -notin @('Idle','Preparing','Quiesced','Swapping','Binding','PendingReboot','AwaitingLogon','Verifying','RollingBack','RecoveryRequired','Maintenance','Detaching','Detached')) { Throw-SwitchError InvalidManifest 'Invalid phase.' }
    if ([long]$State.Sequence -lt 0) { Throw-SwitchError InvalidManifest 'Invalid sequence.' }
}
function Write-SwitchState { param($Context,$State)
    Assert-SwitchState $Context $State
    Write-AtomicJson (Join-Path $Context.Root 'State/state.json') $State
}
function Read-SwitchState { param($Context)
    $value=Read-AtomicJson (Join-Path $Context.Root 'State/state.json')
    Assert-SwitchState $Context $value
    return $value
}
function Set-SwitchPhase { param($State,[string]$NextPhase)
    $allowed=@{
        Idle=@('Preparing','Maintenance','Detaching');Preparing=@('Quiesced','RollingBack');Quiesced=@('Swapping','RollingBack')
        Swapping=@('Binding','RollingBack');Binding=@('PendingReboot','AwaitingLogon','RollingBack')
        PendingReboot=@('AwaitingLogon','RollingBack','RecoveryRequired');AwaitingLogon=@('Verifying','PendingReboot','RollingBack')
        Verifying=@('Idle','PendingReboot','RollingBack');Maintenance=@('Verifying','PendingReboot','RollingBack','RecoveryRequired')
        RollingBack=@('PendingReboot','AwaitingLogon','RecoveryRequired');RecoveryRequired=@('RollingBack')
        Detaching=@('Detached');Detached=@()
    }
    if (-not $allowed.ContainsKey($State.Phase) -or $NextPhase -notin $allowed[$State.Phase]) { Throw-SwitchError InvalidTransition "$($State.Phase) -> $NextPhase" }
    $copy=$State | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $copy.Phase=$NextPhase; $copy.Sequence=[long]$copy.Sequence+1
    return $copy
}
function Enter-SwitchLock { param($Context)
    $dir=Join-Path $Context.Root 'State'; [IO.Directory]::CreateDirectory($dir) | Out-Null
    try { return [IO.FileStream]::new((Join-Path $dir 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { Throw-SwitchError Busy 'Another worker is running.' }
}
function Read-ValidJournal { param($Context,[string]$TransactionId)
    Assert-SafeIdentifier $TransactionId
    $path=Join-Path $Context.Root "Transactions/$TransactionId.jsonl"
    if (-not [IO.File]::Exists($path)) { return }
    $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $lines=$raw.Split([char]10)
    $count=$lines.Length-1
    $sequence=0
    for ($i=0;$i -lt $count;$i++) {
        $entry=ConvertFrom-Envelope $lines[$i].TrimEnd([char]13)
        $sequence++
        if ($entry.SchemaVersion -ne 1 -or $entry.Sequence -ne $sequence -or $entry.TransactionId -ne $TransactionId -or $entry.Kind -notin @('Intent','Done','Checkpoint')) { Throw-SwitchError IntegrityError 'Invalid journal sequence or identity.' }
        $entry
    }
}
function Add-JournalEntry { param($Context,[string]$TransactionId,[ValidateSet('Intent','Done','Checkpoint')][string]$Kind,[string]$StepId,$Before,$After)
    Assert-SafeIdentifier $TransactionId
    $existing=@(Read-ValidJournal $Context $TransactionId)
    $dir=Join-Path $Context.Root 'Transactions'; [IO.Directory]::CreateDirectory($dir) | Out-Null
    $path=Join-Path $dir "$TransactionId.jsonl"
    if ([IO.File]::Exists($path)) {
        $raw=[IO.File]::ReadAllText($path)
        if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { Throw-SwitchError RecoveryRequired 'Truncated journal must be repaired before resuming.' }
    }
    $entry=[ordered]@{SchemaVersion=1;Sequence=$existing.Count+1;TransactionId=$TransactionId;Kind=$Kind;StepId=$StepId;Before=$Before;After=$After;TimestampUtc=[DateTime]::UtcNow.ToString('o')}
    Write-DurableText $path ((ConvertTo-Envelope $entry)+"`n") -Append
}
function Repair-JournalTail { param($Context,[string]$TransactionId)
    $null=@(Read-ValidJournal $Context $TransactionId)
    $path=Join-Path $Context.Root "Transactions/$TransactionId.jsonl"
    if (-not [IO.File]::Exists($path)) { return }
    $raw=[IO.File]::ReadAllText($path)
    if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) {
        $valid=$raw.Substring(0,$raw.LastIndexOf("`n")+1)
        $temp=$path+'.repair'; Write-DurableText $temp $valid
        [IO.File]::Replace($temp,$path,($path+'.truncated'),$false)
    }
}
function New-OperationResult { param([string]$Status='Ok',[string]$Code='Ok',[string]$Message='',$Evidence=@())
    [pscustomobject]@{Status=$Status;Code=$Code;Message=$Message;RebootRequired=($Status -eq 'PendingReboot');Evidence=@($Evidence)}
}
function Get-BootId { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
Export-ModuleMember -Function *-*
