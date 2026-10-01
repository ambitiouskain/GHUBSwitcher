param([Parameter(Mandatory=$true)][string]$OwnerSid,[switch]$PauseOnFailure)
$ErrorActionPreference='Stop'
$stage=$null
$guard=$null
try{
    if($PSVersionTable.PSEdition -eq 'Desktop'){
        Import-Module (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
    }
    $checker=Join-Path $PSScriptRoot 'PackagePreflight.ps1'
    if((Get-FileHash -LiteralPath $checker).Hash -cne '__GHUB_PACKAGE_CHECK_SHA256__'){throw 'Release verifier hash mismatch.'}
    . $checker
    $release=Get-VerifiedPackageBootstrap $PSScriptRoot
foreach($name in @('Core','Storage','Release')){Import-Module (Join-Path $PSScriptRoot "Modules/$name.psm1") -DisableNameChecking}
Assert-Administrator
if(-not [Environment]::Is64BitProcess){throw 'x64 PowerShell required.'}
if($OwnerSid -notmatch '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$'){throw 'OwnerMismatch: invalid desktop user SID.'}
$null=[Security.Principal.SecurityIdentifier]::new($OwnerSid)
$profile=(Get-ItemProperty -LiteralPath ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\"+$OwnerSid)).ProfileImagePath
$profile=[Environment]::ExpandEnvironmentVariables($profile)
$null=Assert-NoReparsePoint $profile
$root=Join-Path $env:ProgramData 'GHUBSwitcher'
$null=Assert-NoReparsePoint $root
if(Test-Path -LiteralPath $root){throw 'AlreadyInstalled: Existing root must be inspected; refusing to overwrite it.'}
$oldSource=Join-Path $PSScriptRoot 'Installers/lghub_installer_2021.3.exe'
$guard=[IO.File]::Open($oldSource,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$null=Get-VerifiedLegacyInstaller $oldSource
$installerHash=($release.Files|Where-Object {$_.Path.Replace('\','/') -ieq 'Installers/lghub_installer_2021.3.exe'}).Sha256
if((Get-FileHash -LiteralPath $oldSource).Hash.ToLowerInvariant() -cne $installerHash){throw 'Legacy installer hash mismatch.'}
$stage=Join-Path $env:ProgramData ('GHUBSwitcher.Install-'+[guid]::NewGuid().ToString('N'))
$null=Assert-NoReparsePoint $stage
function Protect-Directory([string]$Path,[bool]$OwnerRead){
    [IO.Directory]::CreateDirectory($Path)|Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($principal in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($principal),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    if($OwnerRead){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($OwnerSid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))}
    else{$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($OwnerSid),'Traverse','None','None','Allow'))}
    Set-Acl -LiteralPath $Path -AclObject $acl
}
Protect-Directory $stage $false
foreach($name in @('App','Status')){Protect-Directory (Join-Path $stage $name) $true}
foreach($name in @('State','Manifests','Transactions','Backups','Environments','DriverPackages','Installers','Rescue','RestoreStage')){Protect-Directory (Join-Path $stage $name) $false}
foreach($file in $release.Files){
    if($file.Path -like 'source/*' -or $file.Path -like 'tests/*' -or $file.Path -like 'docs/*' -or $file.Path -like 'verification/*' -or $file.Path -like 'Installers/*'){continue}
    $target=Join-Path $stage ('App/'+$file.Path)
    [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file.Path) -Destination $target
    if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -cne $file.Sha256){throw 'Installed file failed hash verification.'}
}
$protectedInstaller=Join-Path $root 'Installers/lghub_installer_2021.3.exe'
$stagedInstaller=Join-Path $stage 'Installers/lghub_installer_2021.3.exe'
Copy-Item -LiteralPath $oldSource -Destination $stagedInstaller
if((Get-FileHash -LiteralPath $stagedInstaller).Hash.ToLowerInvariant() -cne $installerHash){throw 'Installed legacy installer failed hash verification.'}
$null=Get-VerifiedLegacyInstaller $stagedInstaller
$guard.Dispose();$guard=$null
@{SchemaVersion=1;Files=@($release.Files|Where-Object {$_.Path -notlike 'source/*' -and $_.Path -notlike 'tests/*' -and $_.Path -notlike 'docs/*' -and $_.Path -notlike 'verification/*' -and $_.Path -notlike 'Installers/*'})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'App/release-manifest.json') -Encoding UTF8
$registration=[pscustomobject]@{SchemaVersion=1;OwnerSid=$OwnerSid;ProfileRoot=$profile;LegacyInstallerPath=$protectedInstaller;RegistryRoots=@();ValidationMode='InstallationAndConfiguration';InstalledUtc=[DateTime]::UtcNow.ToString('o')}
$registrationPath=Join-Path $stage 'registration.json'
Write-AtomicJson $registrationPath $registration
$acl=Get-Acl -LiteralPath $registrationPath
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($OwnerSid),'Read','Allow'))
Set-Acl -LiteralPath $registrationPath -AclObject $acl
Write-AtomicJson (Join-Path $stage 'Status/environments.json') @{ModernReady=$false;LegacyReady=$false}
$null=Assert-NoReparsePoint $root
[IO.Directory]::Move($stage,$root)
$stage=$null
Write-Host '切换器已安装，继续按主窗口提示准备两套环境。'
}catch{
    if($PauseOnFailure){Write-Host ('安装未完成：'+$_.Exception.Message);Read-Host '按 Enter 返回主窗口'|Out-Null;exit 1}
    throw
}finally{
    if($guard){$guard.Dispose()}
    if($stage -and (Test-Path -LiteralPath $stage)){
        $parent=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
        if([IO.Path]::GetFullPath($stage).StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $stage -Leaf) -match '^GHUBSwitcher\.Install-[a-f0-9]{32}$'){
            $null=Assert-NoReparsePoint $stage
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}
