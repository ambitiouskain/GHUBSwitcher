param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$VerificationDirectory,
    [switch]$Distribution,
    [string]$LegacyInstallerPath
)
$ErrorActionPreference='Stop'
$legacyGuard=$null
$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if($output -eq [IO.Path]::GetPathRoot($output).TrimEnd('\','/') -or $output -eq $root -or $output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be a separate deliverable directory.'}
if(Test-Path -LiteralPath $output){
    if(-not (Test-Path -LiteralPath $output -PathType Container) -or @(Get-ChildItem -LiteralPath $output -Force).Count -gt 0){throw 'Output directory must be empty.'}
}
if($Distribution){
    Import-Module (Join-Path $root 'src/Modules/Release.psm1') -Force -DisableNameChecking
    if(-not $LegacyInstallerPath -or -not (Test-Path -LiteralPath $LegacyInstallerPath -PathType Leaf)){throw 'Missing legacy installer.'}
    $legacyGuard=[IO.File]::Open($LegacyInstallerPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$legacy=Get-VerifiedLegacyInstaller $LegacyInstallerPath}catch{$legacyGuard.Dispose();throw}
}else{
if(-not $VerificationDirectory -or -not (Test-Path -LiteralPath $VerificationDirectory -PathType Container)){throw 'VerificationDirectory must contain the development verification records.'}
$verification=[IO.Path]::GetFullPath($VerificationDirectory).TrimEnd('\','/')
if($verification -eq $output -or $verification.StartsWith($output+'\',[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($verification+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Verification and output directories must be separate.'}
if(@(Get-ChildItem -LiteralPath $verification -File -Recurse -Force).Count -eq 0){throw 'VerificationDirectory must contain the development verification records.'}
}

function Copy-ReleaseFile {param([IO.FileInfo]$File,[string]$Destination)
    [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent))|Out-Null
    if($File.Extension -in @('.ps1','.psm1','.psd1')){[IO.File]::WriteAllText($Destination,[IO.File]::ReadAllText($File.FullName),[Text.UTF8Encoding]::new($true))}
    else{Copy-Item -LiteralPath $File.FullName -Destination $Destination}
}

try{
& (Join-Path $PSScriptRoot 'Build-Native.ps1')
if($LASTEXITCODE -ne 0){throw 'Native build failed.'}
[IO.Directory]::CreateDirectory($output)|Out-Null
foreach($item in Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File){
    $relative=$item.FullName.Substring((Join-Path $root 'src').Length+1)
    if($Distribution -and ($relative -like 'Native\*' -or $relative -like 'Launcher\*')){continue}
    Copy-ReleaseFile $item (Join-Path $output $relative)
}
if(Test-Path -LiteralPath (Join-Path $output 'PackagePreflight.ps1')){
    $checkerHash=(Get-FileHash -LiteralPath (Join-Path $output 'PackagePreflight.ps1')).Hash
    foreach($entry in @('Start-GHUBSwitcher.ps1','Install-GHUBSwitcher.ps1')){
        $entryPath=Join-Path $output $entry
        if(Test-Path -LiteralPath $entryPath){[IO.File]::WriteAllText($entryPath,[IO.File]::ReadAllText($entryPath).Replace('__GHUB_PACKAGE_CHECK_SHA256__',$checkerHash),[Text.UTF8Encoding]::new($true))}
    }
}
[IO.Directory]::CreateDirectory((Join-Path $output 'Native'))|Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GHubSwitcher.Native.dll') -Destination (Join-Path $output 'Native/GHubSwitcher.Native.dll') -Force
if($Distribution){
    & (Join-Path $PSScriptRoot 'Build-Launcher.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GHUBSwitcher.exe') -Destination (Join-Path $output 'GHUBSwitcher.exe')
    [IO.Directory]::CreateDirectory((Join-Path $output 'Installers'))|Out-Null
    try{
        $legacyHash=(Get-FileHash -LiteralPath $legacy.FullName).Hash
        $copiedLegacy=Join-Path $output 'Installers/lghub_installer_2021.3.exe'
        Copy-Item -LiteralPath $legacy.FullName -Destination $copiedLegacy
        if((Get-FileHash -LiteralPath $copiedLegacy).Hash -cne $legacyHash){throw 'Bundled installer hash mismatch.'}
        $null=Get-VerifiedLegacyInstaller $copiedLegacy
    }finally{$legacyGuard.Dispose()}
    Copy-Item -LiteralPath (Join-Path $root 'docs/分发使用说明.md') -Destination (Join-Path $output '使用说明.md')
}else{
foreach($dir in @('src','tests','docs','tools/Pester')){
    $base=Join-Path $root $dir
    foreach($file in Get-ChildItem -LiteralPath $base -File -Recurse -Force){
        $relative=$file.FullName.Substring($base.Length+1)
        Copy-ReleaseFile $file (Join-Path $output ('source/'+$dir+'/'+$relative))
    }
}
foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse -Filter '*.ps1'){
    Copy-ReleaseFile $file (Join-Path $output ('source/build/'+$file.FullName.Substring($PSScriptRoot.Length+1)))
}
foreach($file in Get-ChildItem -LiteralPath $root -File -Force){
    Copy-ReleaseFile $file (Join-Path $output ('source/'+$file.Name))
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GHubSwitcher.Native.dll') -Destination (Join-Path $output 'source/build/GHubSwitcher.Native.dll') -Force
foreach($file in Get-ChildItem -LiteralPath $verification -File -Recurse -Force){
    $dest=Join-Path $output ('verification/'+$file.FullName.Substring($verification.Length+1))
    [IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $dest
}
Copy-Item -LiteralPath (Join-Path $root 'docs/操作说明.md') -Destination (Join-Path $output '使用说明.md') -Force
Copy-Item -LiteralPath (Join-Path $root 'docs/acceptance.md') -Destination (Join-Path $output '验收与恢复手册.md') -Force
}
$launch='@echo off'+"`r`n"+'"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GHUBSwitcher.ps1"'+"`r`n"
[IO.File]::WriteAllText((Join-Path $output '启动切换器.cmd'),$launch,[Text.Encoding]::ASCII)
$inspect='@echo off'+"`r`n"+'"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GHUBSwitcher.ps1" -ReadOnly'+"`r`n"+'pause'+"`r`n"
[IO.File]::WriteAllText((Join-Path $output '只读检查.cmd'),$inspect,[Text.Encoding]::ASCII)
$files=@(Get-ChildItem -LiteralPath $output -File -Recurse -Force|Sort-Object FullName|ForEach-Object{[pscustomobject]@{Path=$_.FullName.Substring($output.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
[pscustomobject]@{SchemaVersion=1;BuiltUtc=[DateTime]::UtcNow.ToString('o');Runtime='Windows PowerShell 5.1 x64';Distribution=[bool]$Distribution;LiveValidated=$false;Files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $output 'release-manifest.json') -Encoding UTF8
Write-Output ([pscustomobject]@{Output=$output;Files=$files.Count;NativeLibrary=(Join-Path $output 'Native/GHubSwitcher.Native.dll')})
}finally{if($legacyGuard){$legacyGuard.Dispose()}}
