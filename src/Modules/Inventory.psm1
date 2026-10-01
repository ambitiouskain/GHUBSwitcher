Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

function Initialize-NativeLibrary {
    if ('GHubSwitcher.DeviceApi' -as [type]) { return }
    $paths=@((Join-Path $PSScriptRoot '../Native/GHubSwitcher.Native.dll'),(Join-Path $PSScriptRoot '../../build/GHubSwitcher.Native.dll'))
    $file=$paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $file) { Throw-SwitchError MissingNativeLibrary 'Build the native library first.' }
    Add-Type -Path $file
}
function Get-NativeDevices { Initialize-NativeLibrary; [GHubSwitcher.DeviceApi]::Enumerate() }
function Get-TaskExecutables {param($Task)
    foreach($action in @(Get-ObjectValue $Task Actions @())){
        $path=Get-ObjectValue $action Execute ''
        if($path){[string]$path}
    }
}
function Get-ClassFilterInventory {
    foreach($key in Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Class' -ErrorAction Stop){
        if($key.PSChildName -notmatch '^\{[0-9a-fA-F-]{36}\}$'){continue}
        [pscustomobject]@{ClassGuid=$key.PSChildName;UpperFilters=@($key.GetValue('UpperFilters',@()));LowerFilters=@($key.GetValue('LowerFilters',@()))}
    }
}
function ConvertTo-KernelImagePath {param([string]$Path)
    $value=$Path
    if($value.StartsWith('\??\',[StringComparison]::Ordinal)){$value=$value.Substring(4)}
    if($value -match '^(?i)\\SystemRoot\\'){$value=Join-Path $env:WINDIR $value.Substring(12)}
    $value=[Environment]::ExpandEnvironmentVariables($value)
    if($value -notmatch '^[a-zA-Z]:[\\/]'){Throw-SwitchError UnsafePath 'Kernel image must use an absolute local DOS path.'}
    try{return [IO.Path]::GetFullPath($value)}catch{Throw-SwitchError UnsafePath 'Invalid kernel image path.'}
}
function Get-AppLocalKernelNativeRecord {
    Initialize-NativeLibrary
    try{return [GHubSwitcher.ServiceApi]::CaptureKernel('LGHUBTemperatureService')}catch{
        $errorValue=$_.Exception
        while($null -ne $errorValue){if($errorValue -is [ComponentModel.Win32Exception] -and $errorValue.NativeErrorCode -eq 1060){return $null};$errorValue=$errorValue.InnerException}
        throw
    }
}
function Assert-AppLocalKernelFile {param([string]$Path,[string]$ExpectedHash='',[string]$ExpectedThumbprint='')
    $expected=Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys'
    $full=ConvertTo-KernelImagePath $Path
    if($full -ine $expected){Throw-SwitchError UnownedAppLocalKernel 'The temperature driver is outside its fixed LGHUB program location.'}
    if(-not(Test-Path -LiteralPath $full -PathType Leaf -ErrorAction Stop)){Throw-SwitchError AppLocalKernelMissing 'The captured temperature driver binary is missing.'}
    $currentPath=$full
    while($currentPath){
        if(((Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Throw-SwitchError UnsafePath 'The temperature driver path contains a reparse point.'}
        $parent=[IO.Directory]::GetParent($currentPath);$currentPath=if($parent){$parent.FullName}else{$null}
    }
    $signature=Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop
    if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)O=Logitech Inc(,|$)'){Throw-SwitchError UnownedAppLocalKernel 'The temperature driver requires a valid Logitech publisher signature.'}
    $hash=(Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if(($ExpectedHash -and $hash -cne $ExpectedHash.ToLowerInvariant()) -or ($ExpectedThumbprint -and $signature.SignerCertificate.Thumbprint -ine $ExpectedThumbprint)){Throw-SwitchError UnownedAppLocalKernel 'The temperature driver no longer matches its captured file identity.'}
    [pscustomobject]@{Relative='logi_core_temp.sys';Sha256=$hash;SignatureThumbprint=$signature.SignerCertificate.Thumbprint;Signer=$signature.SignerCertificate.Subject}
}
function Get-AppLocalKernelInventory {
    $drivers=@(Get-CimInstance Win32_SystemDriver -Filter "Name='LGHUBTemperatureService'" -ErrorAction Stop|Where-Object Name -IEQ 'LGHUBTemperatureService')
    if($drivers.Count -gt 1){Throw-SwitchError UnownedAppLocalKernel 'Ambiguous temperature driver service identity.'}
    $native=Get-AppLocalKernelNativeRecord
    if(-not $native){
        if(-not $drivers.Count){return}
        Throw-SwitchError AppLocalKernelMissing 'The temperature driver disappeared during capture.'
    }
    Initialize-NativeLibrary
    [GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord([GHubSwitcher.ServiceRecord]$native)
    $path=ConvertTo-KernelImagePath $native.ImagePath
    $rawPath=$native.ImagePath
    if($drivers.Count){
        $rawPath=$drivers[0].PathName
        if($path -ine (ConvertTo-KernelImagePath $rawPath)){Throw-SwitchError UnownedAppLocalKernel 'Kernel inventory and SCM image paths disagree.'}
    }
    if(-not(Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)){
        if($native.CurrentState -eq 1 -and $native.StartType -eq 4){return}
        Throw-SwitchError AppLocalKernelMissing 'A loaded or enabled temperature driver has no binary in the active environment.'
    }
    $file=Assert-AppLocalKernelFile $path
    $state=switch($native.CurrentState){1{'Stopped'}4{'Running'}default{Throw-SwitchError Busy 'The temperature driver is changing state during capture.'}}
    $startMode=switch($native.StartType){2{'Auto'}3{'Manual'}4{'Disabled'}}
    [pscustomobject]@{Name=$native.Name;State=$state;StartMode=$startMode;StartType=[int]$native.StartType;Path=$path;RawPath=$rawPath;Sha256=$file.Sha256;AppLocal=$true;RelativePath=$file.Relative;SignatureThumbprint=$file.SignatureThumbprint;FileEvidence=$file;Native=$native}
}
function Get-KernelInventory {param([string[]]$Names=@())
    $explicitNames=$PSBoundParameters.ContainsKey('Names')
    foreach($driver in Get-CimInstance Win32_SystemDriver | Where-Object {($explicitNames -and $_.Name -in $Names) -or (-not $explicitNames -and $_.Name -match '^logi_joy_|^logi_lamparray$|^lghub')}){
        $path=ConvertTo-KernelImagePath $driver.PathName
        $reg=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$driver.Name) -ErrorAction Stop
        [pscustomobject]@{Name=$driver.Name;State=$driver.State;StartMode=$driver.StartMode;StartType=[int]$reg.Start;Path=$path;RawPath=$driver.PathName;Sha256=$(if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path -ErrorAction Stop).Hash.ToLowerInvariant()}else{''})}
    }
}
function Resolve-ManagedDevice { param($Identity,[object[]]$PresentDevices)
    $hardware=@(Get-ObjectValue $Identity HardwareIds @())
    $class=Get-ObjectValue $Identity ClassGuid ''
    $candidates=@($PresentDevices | Where-Object {
        $device=$_
        $overlap=@($hardware | Where-Object { $_ -in @(Get-ObjectValue $device HardwareIds @()) })
        $overlap.Count -gt 0 -and ((Get-ObjectValue $device ClassGuid '') -ieq $class)
    })
    $exact=@($candidates | Where-Object { $_.InstanceId -ieq (Get-ObjectValue $Identity InstanceId '') })
    $container=Get-ObjectValue $Identity ContainerId ''
    $parsedContainer=[guid]::Empty
    $validContainer=[guid]::TryParse([string]$container,[ref]$parsedContainer) -and $parsedContainer -ne [guid]::Empty
    if ($validContainer) {
        $candidates=@($candidates | Where-Object { (Get-ObjectValue $_ ContainerId '') -ieq $container })
        $exact=@($exact | Where-Object { (Get-ObjectValue $_ ContainerId '') -ieq $container })
    }
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($candidates.Count -eq 0) { Throw-SwitchError DeviceMissing 'No present device matches the recorded identity.' }
    if ($candidates.Count -eq 1 -and $validContainer) { return $candidates[0] }
    Throw-SwitchError DeviceAmbiguous 'Device moved or identity is not unique; recapture its identity.'
}
function Get-ActiveDirectories { param($Context)
    if ($Context.Mode -eq 'Simulation') {
        $map=[ordered]@{}; foreach ($role in @('Program','LocalData','RoamingData','MachineData')) { $map[$role]=Join-Path $Context.Root "active/$role" }; return $map
    }
    [ordered]@{Program=(Join-Path $env:ProgramFiles 'LGHUB');LocalData=(Join-Path $Context.ProfileRoot 'AppData/Local/LGHUB');RoamingData=(Join-Path $Context.ProfileRoot 'AppData/Roaming/LGHUB');MachineData=(Join-Path $env:ProgramData 'LGHUB')}
}
function Get-GHUBRegistryLocations {param($Context)
    $software=@('Registry::HKEY_LOCAL_MACHINE\SOFTWARE','Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node',"Registry::HKEY_USERS\$($Context.OwnerSid)\SOFTWARE","Registry::HKEY_USERS\$($Context.OwnerSid)\SOFTWARE\WOW6432Node")
    $products=@();$uninstall=@();$startup=@()
    foreach($base in $software){
        foreach($name in @('GHUB','LGHUB')){$products+=$base+'\Logitech\'+$name}
        $windows=$base+'\Microsoft\Windows\CurrentVersion'
        $uninstall+=$windows+'\Uninstall'
        foreach($name in @('Run','RunOnce')){$startup+=$windows+'\'+$name}
    }
    [pscustomobject]@{ProductRoots=$products;UninstallParents=$uninstall;StartupRoots=$startup}
}
function Get-GHUBRegistryValues {param($Context)
    $locations=Get-GHUBRegistryLocations $Context
    $roots=[Collections.Generic.List[string]]::new()
    foreach($root in $locations.ProductRoots){$roots.Add($root)}
    foreach($parent in $locations.UninstallParents){
        if(-not(Test-Path -LiteralPath $parent -ErrorAction Stop)){continue}
        Get-ChildItem -LiteralPath $parent -ErrorAction Stop | ForEach-Object {
            $key=$_
            try{
                if([string]$key.GetValue('DisplayName',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -match '^(Logitech|Logicool) G HUB$'){
                    $path='Registry::'+$key.Name
                    if($path -notin $roots){$roots.Add($path)}
                }
            }finally{$key.Dispose()}
        }
    }
    $values=[Collections.Generic.List[object]]::new()
    $capture={
        $key=$_
        try{
            foreach($name in $key.GetValueNames()){
                $values.Add([pscustomobject]@{Path=('Registry::'+$key.Name);Name=$name;Exists=$true;Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)})
            }
        }finally{$key.Dispose()}
    }
    foreach($root in $roots){
        if(-not(Test-Path -LiteralPath $root -ErrorAction Stop)){continue}
        Get-Item -LiteralPath $root -ErrorAction Stop | ForEach-Object $capture
        Get-ChildItem -LiteralPath $root -Recurse -ErrorAction Stop | ForEach-Object $capture
    }
    [pscustomobject]@{Roots=$roots.ToArray();Values=$values.ToArray()}
}
function Get-GHUBInventory { param($Context,[switch]$CaptureDrivers)
    if ($Context.Mode -ne 'Live') { Throw-SwitchError InvalidManifest 'Simulation inventory must be supplied by the test fixture.' }
    $dirs=Get-ActiveDirectories $Context
    Initialize-NativeLibrary
    $captureSystemDrivers=$CaptureDrivers -or -not (Test-InstallationConfigurationMode $Context)
    $devices=@(if($captureSystemDrivers){Get-NativeDevices})
    $managed=@($devices | Where-Object { $_.Service -match '^logi_joy_|^logi_lamparray$|^lghub' -or $_.InstanceId -match '^LGHUBDEVICE\\' -or $_.HardwareIds -contains 'root\LGHUBVirtualBus' })
    $services=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '(?i)\\LGHUB\\' } | ForEach-Object {
        $reg=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$_.Name)
        [pscustomobject]@{Name=$_.Name;ImagePath=$_.PathName;Account=$_.StartName;StartMode=$_.StartMode;State=$_.State;Start=[int]$reg.Start;Type=[int]$reg.Type;DelayedAutoStart=(Get-ObjectValue $reg DelayedAutoStart 0);Dependencies=@(Get-ObjectValue $reg DependOnService @());FailureActions=(Get-ObjectValue $reg FailureActions $null);TriggerInfoPresent=(Test-Path -LiteralPath ($reg.PSPath+'\TriggerInfo'));Native=[GHubSwitcher.ServiceApi]::Capture($_.Name)}
    })
    $driverNames=@($managed | ForEach-Object { $_.Service; $_.UpperFilters; $_.LowerFilters } | Where-Object { $_ } | Sort-Object -Unique)
    $classes=@(if($captureSystemDrivers){Get-ClassFilterInventory})
    $managedClasses=@($classes|Where-Object {$_.ClassGuid -in @($managed|ForEach-Object ClassGuid)})
    $driverNames+=@($managedClasses|ForEach-Object {$_.UpperFilters; $_.LowerFilters})
    $kernel=@(if($captureSystemDrivers){Get-KernelInventory $driverNames|Where-Object {$_.Name -in $driverNames -and $_.Name -ine 'LGHUBTemperatureService'}})+@(Get-AppLocalKernelInventory)
    $versionPath=Join-Path $dirs.MachineData 'version.json'
    $version=''
    if (Test-Path -LiteralPath $versionPath) { $version=(Get-Content -Raw -LiteralPath $versionPath | ConvertFrom-Json).version }
    if (-not $version -and (Test-Path -LiteralPath (Join-Path $dirs.Program 'lghub_agent.exe'))) { $version=(Get-Item -LiteralPath (Join-Path $dirs.Program 'lghub_agent.exe')).VersionInfo.ProductVersion }
    $startup=@()
    foreach ($hive in (Get-GHUBRegistryLocations $Context).StartupRoots) {
        if (Test-Path -LiteralPath $hive) {
            $key=Get-Item -LiteralPath $hive
            try {
                foreach ($name in $key.GetValueNames()) { $value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if ([string]$value -match '(?i)\\LGHUB\\') { $startup += [pscustomobject]@{Path=$hive;Name=$name;Value=$value;Kind=$key.GetValueKind($name).ToString()} } }
            } finally {$key.Dispose()}
        }
    }
    $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object { (@(Get-TaskExecutables $_) -join ' ') -match '(?i)\\LGHUB\\' } | ForEach-Object { [pscustomobject]@{Name=$_.TaskName;Path=$_.TaskPath;Xml=(Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath)} })
    $processes=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^lghub.*\.exe$' } | ForEach-Object {
        $owner=Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        [pscustomobject]@{Id=$_.ProcessId;Name=$_.Name;Path=$_.ExecutablePath;OwnerSid=$owner.Sid;SessionId=$_.SessionId}
    })
    [pscustomobject]@{ProductVersion=$version;Directories=$dirs;Devices=$managed;AllDevices=$devices;Services=$services;KernelServices=$kernel;ClassFilters=$classes;Startup=$startup;Tasks=$tasks;Processes=$processes;CapturedAt=[DateTime]::UtcNow.ToString('o')}
}
function New-EnvironmentManifest { param($Context,[string]$Slot,$Inventory)
    Assert-Slot $Slot
    [pscustomobject][ordered]@{
        SchemaVersion=1;Slot=$Slot;ProductVersion=$Inventory.ProductVersion;OwnerSid=$Context.OwnerSid;CapturedAt=$Inventory.CapturedAt;Location='Active'
        Directories=$Inventory.Directories;Files=@();Services=@($Inventory.Services);Startup=@($Inventory.Startup);Tasks=@($Inventory.Tasks)
        RegistryValues=@();Devices=@($Inventory.Devices);DriverPackages=@();KernelServices=@($Inventory.KernelServices)
        ClassFilters=@(Get-ObjectValue $Inventory ClassFilters @() | Where-Object {$_.ClassGuid -in @($Inventory.Devices|ForEach-Object ClassGuid)})
        UpdatePolicy=[pscustomobject]@{Verified=$false;Method='';Evidence=@()};Qualification='Unverified'
    }
}
Export-ModuleMember -Function *-*
