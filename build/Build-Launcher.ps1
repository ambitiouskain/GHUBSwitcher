$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:exe /platform:x64 "/out:$PSScriptRoot/GHUBSwitcher.exe" (Join-Path $root 'src/Launcher/Program.cs')
if($LASTEXITCODE -ne 0){throw 'LauncherBuildFailed'}
