$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'MissingCompiler: .NET Framework x64 csc.exe required.' }
$sources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src/Native') -Filter '*.cs' | ForEach-Object FullName)
if ($sources.Count -eq 0) { throw 'Native sources not implemented yet.' }
& $compiler /nologo /target:library /platform:x64 "/out:$PSScriptRoot/GHubSwitcher.Native.dll" $sources
if ($LASTEXITCODE -ne 0) { throw 'NativeBuildFailed' }
