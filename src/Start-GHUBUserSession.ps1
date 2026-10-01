$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Core.psm1') -DisableNameChecking
$root=Join-Path $env:ProgramData 'GHUBSwitcher'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ticket=Read-AtomicJson (Join-Path $root 'Status/launch.json')
$status=Read-AtomicJson (Join-Path $root 'Status/status.json')
if(-not $ticket.Enabled -or $ticket.OwnerSid -ne $sid -or (ConvertTo-UtcTime $ticket.ExpiresUtc) -le [DateTime]::UtcNow){exit 0}
if($status.Phase -notin @('AwaitingLogon','Verifying','Maintenance') -or $status.Target -ne $ticket.Slot){exit 0}
if($status.Sequence -lt $ticket.Sequence -or $status.Sequence -gt ($ticket.Sequence+1)){exit 0}
if(Test-IsAdministrator){throw 'Refusing to launch G HUB with an elevated token.'}
$program=Join-Path $env:ProgramFiles 'LGHUB/lghub.exe'
if(-not (Test-Path -LiteralPath $program)){throw 'Active G HUB executable missing.'}
Start-Process -FilePath $program -WorkingDirectory (Split-Path $program -Parent)
