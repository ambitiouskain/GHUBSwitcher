# This verifier is hashed into the two entry scripts during packaging.
# It uses only Windows/.NET operations and never loads package modules.
function Get-VerifiedPackageBootstrap {param([string]$Directory,[switch]$InstalledRuntime)
    $base=[IO.Path]::GetFullPath($Directory).TrimEnd('\','/')
    $manifest=Join-Path $base 'release-manifest.json'
    $release=Get-Content -Raw -LiteralPath $manifest -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
    if($release.SchemaVersion -ne 1 -or @($release.Files).Count -eq 0){throw 'Invalid release manifest.'}
    $required=@('GHUBSwitcher.exe','Start-GHUBSwitcher.ps1','Install-GHUBSwitcher.ps1','Invoke-GHUBWorker.ps1','Start-GHUBUserSession.ps1','PackagePreflight.ps1','Native/GHubSwitcher.Native.dll')
    foreach($module in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator','Bootstrap','InstallerAudit','ExternalRecovery','Release')){$required+=('Modules/'+$module+'.psm1')}
    if(-not $InstalledRuntime){$required+='Installers/lghub_installer_2021.3.exe'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $release.Files){
        $relative=[string]$file.Path
        $hash=[string]$file.Sha256
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $hash -cnotmatch '^[a-f0-9]{64}$' -or -not $seen.Add($relative.Replace('\','/'))){throw 'Invalid release file entry.'}
        $path=[IO.Path]::GetFullPath((Join-Path $base $relative))
        if(-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid release file path.'}
        $ancestor=$path
        while($ancestor){
            if([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)){
                if(([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Invalid release path: reparse point.'}
            }
            $parent=[IO.Directory]::GetParent($ancestor)
            if($null -eq $parent){break};$ancestor=$parent.FullName
        }
        if((Get-FileHash -LiteralPath $path -ErrorAction Stop).Hash.ToLowerInvariant() -cne $hash){throw ('Release file hash mismatch: '+$relative)}
    }
    foreach($path in $required){if(-not $seen.Contains($path)){throw ('Missing required release file: '+$path)}}
    $release
}
