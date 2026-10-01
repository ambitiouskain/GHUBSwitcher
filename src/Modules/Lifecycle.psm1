Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Inventory.psm1') -DisableNameChecking

function Assert-GHUBProcessOwnership { param([object[]]$Processes,[string]$OwnerSid)
    foreach ($p in $Processes) {
        if ($p.Name -match '^lghub_(software_manager|installer).*\.exe$') { Throw-SwitchError UpdateInProgress 'A G HUB installer or software manager is running.' }
        if ($p.OwnerSid -ne $OwnerSid -and -not ($p.OwnerSid -eq 'S-1-5-18' -and $p.Name -eq 'lghub_updater.exe')) { Throw-SwitchError OtherSessionActive 'G HUB is running in another or unidentified user session.' }
    }
}
function Test-UpdatePolicy { param($Context,$Manifest)
    $policy=Get-ObjectValue $Manifest UpdatePolicy $null
    if (-not (Get-ObjectValue $policy Verified $false) -or (Get-ObjectValue $policy ProductVersion '') -ne (Get-ObjectValue $Manifest ProductVersion '') -or (Get-ObjectValue $policy Method '') -notin @('ObservedUI','VerifiedSetting') -or @(Get-ObjectValue $policy Evidence @()).Count -eq 0) {
        return (New-OperationResult Blocked UpdatePolicyUnverified 'This version has no recorded verification that automatic updates are disabled.')
    }
    New-OperationResult
}
function Assert-RegistryBefore { param($Expected,$Actual)
    if ($Expected.Exists -ne $Actual.Exists -or ($Expected.Exists -and ($Expected.Kind -ne $Actual.Kind -or ($Expected.Value | ConvertTo-Json -Compress -Depth 20) -cne ($Actual.Value | ConvertTo-Json -Compress -Depth 20)))) { Throw-SwitchError ExternalChange 'Registry value no longer matches the captured source.' }
}
function Test-GHUBRuntimeRegistryPath { param($Context,[string]$Path)
    # Only this per-user Data subtree is known to change as G HUB runs.
    # Product identity, uninstall registration, and other users remain immutable.
    foreach ($product in @('GHUB','LGHUB')) {
        $root="Registry::HKEY_USERS\$($Context.OwnerSid)\SOFTWARE\Logitech\$product\Data"
        if ($Path -ieq $root -or $Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Assert-GHUBRegistrySnapshot { param([object[]]$Expected,[object[]]$Actual)
    $before=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $after=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in @(@{Records=$Expected;Map=$before},@{Records=$Actual;Map=$after})) {
        foreach ($record in $pair.Records) {
            $key=$record.Path+[char]0+$record.Name
            if ($pair.Map.ContainsKey($key)) { Throw-SwitchError InvalidManifest 'Duplicate registry value in snapshot.' }
            $pair.Map[$key]=$record
            $null=$keys.Add($key)
        }
    }
    $missing=[pscustomobject]@{Exists=$false;Kind='';Value=$null}
    foreach ($key in @($keys | Sort-Object)) {
        $want=if($before.ContainsKey($key)){$before[$key]}else{$missing}
        $found=if($after.ContainsKey($key)){$after[$key]}else{$missing}
        Assert-RegistryBefore $want $found
    }
}
function Update-EnvironmentRuntimeRegistry { param($Context,$Manifest)
    if (@((Get-GHUBInventory $Context).Processes).Count) { Throw-SwitchError Busy 'G HUB must be stopped before capturing runtime registry settings.' }
    $current=Get-GHUBRegistryValues $Context
    $expectedIdentity=@($Manifest.RegistryValues | Where-Object { -not (Test-GHUBRuntimeRegistryPath $Context $_.Path) })
    $currentIdentity=@($current.Values | Where-Object { -not (Test-GHUBRuntimeRegistryPath $Context $_.Path) })
    Assert-GHUBRegistrySnapshot $expectedIdentity $currentIdentity
    $updated=$Manifest | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    $updated.RegistryValues=@($current.Values)
    $updated | Add-Member -NotePropertyName RuntimeRegistryCapturedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    return $updated
}
function Test-GHUBRegistryPath { param($Context,[string]$Path)
    $allowed=@('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB','Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\LGHUB',"Registry::HKEY_USERS\$($Context.OwnerSid)\SOFTWARE\Logitech\GHUB","Registry::HKEY_USERS\$($Context.OwnerSid)\SOFTWARE\Logitech\LGHUB")
    $registrationPath=Join-Path $Context.Root 'registration.json'
    if(Test-Path -LiteralPath $registrationPath){$registration=Read-AtomicJson $registrationPath;$allowed+=@(Get-ObjectValue $registration RegistryRoots @())}
    foreach ($root in $allowed) { if ($Path -ieq $root -or $Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { return } }
    Throw-SwitchError UnsafePath 'Registry path is not in the G HUB allowlist.'
}
function Read-RegistryValue { param([string]$Path,[string]$Name)
    if (Test-Path -LiteralPath $Path) {
        $key=Get-Item -LiteralPath $Path
        if ($Name -in $key.GetValueNames()) { return [pscustomobject]@{Exists=$true;Kind=$key.GetValueKind($Name).ToString();Value=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)} }
    }
    [pscustomobject]@{Exists=$false;Kind='';Value=$null}
}
function Write-RegistryValue {param([string]$Path,[string]$Name,$Record)
    if(-not (Test-Path -LiteralPath $Path)){
        if(-not $Record.Exists){return}
        New-Item -Path $Path -Force | Out-Null
    }
    $providerKey=Get-Item -LiteralPath $Path
    $writableKey=$null
    try {
        # Registry provider keys are opened read-only, including in elevated sessions.
        $writableKey=$providerKey.OpenSubKey('',$true)
        if(-not $writableKey){throw 'Registry key could not be opened for writing.'}
        if(-not $Record.Exists){$writableKey.DeleteValue($Name,$false);return}
        $kind=[Microsoft.Win32.RegistryValueKind]$Record.Kind
        $value=switch($kind.ToString()){
            Binary {,[byte[]]$Record.Value}
            None {,[byte[]]$Record.Value}
            MultiString {,[string[]]$Record.Value}
            DWord {[int]$Record.Value}
            QWord {[long]$Record.Value}
            String {[string]$Record.Value}
            ExpandString {[string]$Record.Value}
            default {throw 'Unsupported registry value kind.'}
        }
        $writableKey.SetValue($Name,$value,$kind)
    } finally {
        if($writableKey){$writableKey.Dispose()}
        $providerKey.Dispose()
    }
}
function Apply-EnvironmentRegistry { param($Context,$Source,$Target)
    Assert-Administrator
    $state=Read-SwitchState $Context
    if (Get-ObjectValue $Source RuntimeRegistryCapturedAt '') {
        # Catch new names as well as changes/deletions after the quiesced snapshot.
        # Older journals retain their existing per-value compare-and-write behavior.
        Assert-GHUBRegistrySnapshot @($Source.RegistryValues) @((Get-GHUBRegistryValues $Context).Values)
    }
    # NUL separates the path/name pair; ordinal comparison must retain the separator.
    $from=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $to=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pair in @(@{Records=$Source.RegistryValues;Map=$from},@{Records=$Target.RegistryValues;Map=$to})){
        foreach($value in $pair.Records){
            $id=$value.Path+[char]0+$value.Name
            if($pair.Map.ContainsKey($id)){Throw-SwitchError InvalidManifest 'Duplicate registry value in manifest.'}
            $pair.Map[$id]=$value;$null=$keys.Add($id)
        }
    }
    foreach ($id in @($keys | Sort-Object)) {
        $record=if($to.ContainsKey($id)){$to[$id]}else{$from[$id]}; Test-GHUBRegistryPath $Context $record.Path
        $missing=[pscustomobject]@{Exists=$false;Kind='';Value=$null}
        $expected=if($from.ContainsKey($id)){$from[$id]}else{$missing}; $next=if($to.ContainsKey($id)){$to[$id]}else{$missing}
        $actual=Read-RegistryValue $record.Path $record.Name
        Assert-RegistryBefore $expected $actual
        Add-JournalEntry $Context $state.TransactionId Intent ('registry-'+(Get-TextHash $id)) @{Path=$record.Path;Name=$record.Name;Record=$actual} $next
        Write-RegistryValue $record.Path $record.Name $next
        Add-JournalEntry $Context $state.TransactionId Done ('registry-'+(Get-TextHash $id)) $actual $next
    }
    New-OperationResult
}
function Get-ManifestAppLocalKernel {param($Manifest)
    $entries=@(Get-ObjectValue $Manifest KernelServices @()|Where-Object {$_.Name -ieq 'LGHUBTemperatureService' -or (Get-ObjectValue $_ AppLocal $false)})
    if(-not $entries.Count){return $null}
    if($entries.Count -ne 1){Throw-SwitchError UnownedAppLocalKernel 'Ambiguous app-local kernel manifest.'}
    $entry=$entries[0];$native=Get-ObjectValue $entry Native $null;$file=Get-ObjectValue $entry FileEvidence $null
    if($entry.Name -ine 'LGHUBTemperatureService' -or -not(Get-ObjectValue $entry AppLocal $false) -or -not $native -or -not $file){Throw-SwitchError UnownedAppLocalKernel 'The app-local kernel lacks captured native and file evidence.'}
    foreach($field in @('Name','ImagePath','ServiceType','StartType','ErrorControl','Account','DisplayName','LoadOrderGroup','TagId','Dependencies','CurrentState')){
        $present=if($native -is [Collections.IDictionary]){$native.Contains($field)}else{$null -ne $native.PSObject.Properties[$field]}
        if(-not $present){Throw-SwitchError UnownedAppLocalKernel ('Missing native kernel configuration: '+$field)}
    }
    if($entry.StartType -ne $native.StartType -or $entry.State -notin @('Running','Stopped')){Throw-SwitchError UnownedAppLocalKernel 'The kernel runtime and native configuration metadata disagree.'}
    if($entry.RelativePath -cne 'logi_core_temp.sys' -or $file.Relative -cne $entry.RelativePath -or $entry.Sha256 -cnotmatch '^[0-9a-f]{64}$' -or $file.Sha256 -cne $entry.Sha256 -or (ConvertTo-KernelImagePath $native.ImagePath) -ine $entry.Path -or $native.Name -ine $entry.Name -or $entry.SignatureThumbprint -notmatch '^[0-9a-fA-F]{40}$'){Throw-SwitchError UnownedAppLocalKernel 'App-local kernel manifest identities do not agree.'}
    $files=@(Get-ObjectValue $Manifest Files @())
    if($files.Count){
        $matches=@($files|Where-Object {$_.Relative -ceq $entry.RelativePath -and $_.Sha256 -ceq $entry.Sha256})
        if($matches.Count -ne 1){Throw-SwitchError UnownedAppLocalKernel 'The kernel file does not match the program manifest.'}
    }
    Initialize-NativeLibrary
    try{[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord([GHubSwitcher.ServiceRecord]$native)}catch{Throw-SwitchError UnownedAppLocalKernel $_.Exception.Message}
    return $entry
}
function Invoke-AppLocalKernelStop {param($Native,[string]$Sha256)
    Initialize-NativeLibrary
    [GHubSwitcher.ServiceApi]::QuiesceAppLocalKernel([GHubSwitcher.ServiceRecord]$Native,$Sha256,30000)
    $current=Get-AppLocalKernelNativeRecord
    [pscustomobject]@{Stopped=($null -ne $current -and $current.CurrentState -eq 1 -and $current.StartType -eq 4);Native=$current}
}
function Invoke-AppLocalKernelRestore {param($Native,[string]$Sha256,[bool]$Start)
    Initialize-NativeLibrary
    [GHubSwitcher.ServiceApi]::RestoreAppLocalKernel([GHubSwitcher.ServiceRecord]$Native,$Sha256,$Start,30000)
}
function Stop-EnvironmentAppLocalKernel {param($Context,$Source,$Target=$null)
    $from=Get-ManifestAppLocalKernel $Source;$to=Get-ManifestAppLocalKernel $Target
    if(-not $from -and -not $to){return (New-OperationResult)}
    Assert-Administrator
    $current=Get-AppLocalKernelNativeRecord
    if(-not $from){
        if(-not $current){return (New-OperationResult)}
        if($current.CurrentState -eq 1 -and $current.StartType -eq 4 -and (ConvertTo-KernelImagePath $current.ImagePath) -ieq $to.Path){return (New-OperationResult)}
        Throw-SwitchError UnownedAppLocalKernel 'An app-local kernel outside the active source is not stopped and disabled.'
    }
    if(-not $current){Throw-SwitchError AppLocalKernelMissing 'The source app-local kernel service is missing.'}
    $null=Assert-AppLocalKernelFile $from.Path $from.Sha256 $from.SignatureThumbprint
    $state=Read-SwitchState $Context
    Add-JournalEntry $Context $state.TransactionId Intent 'app-local-kernel-stop' $current $from
    try{
        $result=Invoke-AppLocalKernelStop $from.Native $from.Sha256
        if(-not $result.Stopped){throw 'SCM did not confirm STOPPED and DISABLED.'}
        Add-JournalEntry $Context $state.TransactionId Done 'app-local-kernel-stop' $current $result
    }catch{Throw-SwitchError AppLocalKernelRestartRequired ('The temperature kernel driver did not unload. Do not exchange program directories; restart and recover before retrying. '+$_.Exception.Message)}
    New-OperationResult
}
function Restore-EnvironmentAppLocalKernel {param($Context,$Target,[switch]$ForLaunch)
    $entry=Get-ManifestAppLocalKernel $Target
    if(-not $entry){return (New-OperationResult)}
    Assert-Administrator
    $null=Assert-AppLocalKernelFile $entry.Path $entry.Sha256 $entry.SignatureThumbprint
    $current=Get-AppLocalKernelNativeRecord;$state=Read-SwitchState $Context
    $start=$ForLaunch -and $entry.State -eq 'Running'
    Add-JournalEntry $Context $state.TransactionId Intent 'app-local-kernel-restore' $current @{Expected=$entry;Start=$start}
    Invoke-AppLocalKernelRestore $entry.Native $entry.Sha256 -Start $start
    Add-JournalEntry $Context $state.TransactionId Done 'app-local-kernel-restore' $current @{Expected=$entry;Start=$start}
    New-OperationResult
}
function Stop-GHUBEnvironment { param($Context,$Manifest)
    Assert-Administrator
    $inventory=Get-GHUBInventory $Context
    Assert-GHUBProcessOwnership $inventory.Processes $Context.OwnerSid
    foreach ($service in $Manifest.Services) {
        if (-not $service.Native) { Throw-SwitchError InvalidManifest 'Service configuration was not captured.' }
        [GHubSwitcher.ServiceApi]::Restore([GHubSwitcher.ServiceRecord]$service.Native,$true,$true)
    }
    foreach ($item in $inventory.Processes) {
        $process=Get-Process -Id $item.Id -ErrorAction SilentlyContinue
        if ($process) { $null=$process.CloseMainWindow() }
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do { $remaining=@(Get-Process -Name 'lghub','lghub_gl','lghub_system_tray' -ErrorAction SilentlyContinue); if(-not $remaining.Count){break}; Start-Sleep -Milliseconds 250 } while([DateTime]::UtcNow -lt $deadline)
    foreach ($service in $Manifest.Services) {
        $current=Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        if ($current -and $current.Status -ne 'Stopped') { Stop-Service -Name $service.Name -ErrorAction Stop; $current.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30)) }
    }
    $remaining=Get-GHUBInventory $Context; Assert-GHUBProcessOwnership $remaining.Processes $Context.OwnerSid
    $program=(Get-ActiveDirectories $Context).Program.TrimEnd('\')+'\'
    foreach ($item in $remaining.Processes) {
        if (-not $item.Path -or -not $item.Path.StartsWith($program,[StringComparison]::OrdinalIgnoreCase)) { Throw-SwitchError UnsafePath 'Refusing to kill a process outside the recorded installation.' }
        # Ownership and installation path are validated above; SYSTEM cannot answer a cross-user confirmation.
        Stop-Process -Id $item.Id -Force -ErrorAction Stop
    }
    Start-Sleep -Seconds 2
    if (@((Get-GHUBInventory $Context).Processes).Count) { Throw-SwitchError Busy 'G HUB restarted during quiescence.' }
    New-OperationResult
}
function Apply-EnvironmentServices { param($Context,$Manifest,[switch]$ForLaunch)
    Assert-Administrator; Initialize-NativeLibrary
    $program=(Get-ActiveDirectories $Context).Program
    foreach ($service in $Manifest.Services) {
        if ($service.Native.ImagePath -notlike ('"'+$program+'\*') -and $service.Native.ImagePath -notlike ($program+'\*')) { Throw-SwitchError UnsafePath 'Service image outside G HUB program directory.' }
        [GHubSwitcher.ServiceApi]::Restore([GHubSwitcher.ServiceRecord]$service.Native,$true,(-not $ForLaunch))
    }
    New-OperationResult
}
function Install-StartupControl { param($Context,$Manifest)
    Assert-Administrator
    foreach ($entry in $Manifest.Startup) {
        $actual=Read-RegistryValue $entry.Path $entry.Name
        if ($actual.Exists -and [string]$actual.Value -eq [string]$entry.Value) { Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop }
        elseif ($actual.Exists) { Throw-SwitchError ExternalChange 'Startup entry changed since capture.' }
    }
    foreach ($task in $Manifest.Tasks) { Disable-ScheduledTask -TaskName $task.Name -TaskPath $task.Path | Out-Null }
    $app=Join-Path $Context.Root 'App'; $shell="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $system=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    foreach ($actionName in @('BootResume','Monitor')) {
        $name=if($actionName -eq 'BootResume'){'GHUBSwitcher-RecoverAtBoot'}else{'GHUBSwitcher-Monitor'}
        $action=New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $app 'Invoke-GHUBWorker.ps1')+'" -Action '+$actionName)
        if ($actionName -eq 'BootResume') {
            $resumeSettings=New-ScheduledTaskSettingsSet -MultipleInstances Queue -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn -User $Context.OwnerSid))
            Register-ScheduledTask -TaskName $name -Action $action -Trigger $triggers -Principal $system -Settings $resumeSettings -Force | Out-Null
        }
        else { Register-ScheduledTask -TaskName $name -Action $action -Principal $system -Settings $settings -Force | Out-Null }
    }
    $principal=New-ScheduledTaskPrincipal -UserId $Context.OwnerSid -LogonType Interactive -RunLevel Limited
    $action=New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $app 'Start-GHUBUserSession.ps1')+'"')
    Register-ScheduledTask -TaskName 'GHUBSwitcher-UserSession' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    New-OperationResult
}
function Start-GHUBUserSession { param($Context,$Manifest)
    Assert-Administrator
    $sessions=@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $Context.OwnerSid })
    if (-not $sessions.Count) { return (New-OperationResult AwaitingLogon AwaitingLogon 'Waiting for the original user to log in.') }
    $state=Read-SwitchState $Context
    Write-AtomicJson (Join-Path $Context.Root 'Status/launch.json') ([pscustomobject]@{OwnerSid=$Context.OwnerSid;Slot=$Manifest.Slot;Sequence=$state.Sequence;Enabled=$true;ExpiresUtc=[DateTime]::UtcNow.AddMinutes(2).ToString('o')})
    Start-ScheduledTask -TaskName 'GHUBSwitcher-UserSession'
    New-OperationResult
}
Export-ModuleMember -Function *-*
