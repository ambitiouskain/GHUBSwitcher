Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('Core','Storage')){Import-Module (Join-Path $PSScriptRoot ($name+'.psm1')) -DisableNameChecking}

function Get-VerifiedRelease {param([string]$Directory)
    . (Join-Path $PSScriptRoot '../PackagePreflight.ps1')
    return (Get-VerifiedPackageBootstrap $Directory)
}

function Get-VerifiedLegacyInstaller {param([string]$Path)
    if(-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Missing legacy installer: the complete package is required.'}
    $null=Assert-NoReparsePoint $Path
    $file=Get-Item -LiteralPath $Path
    $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Logitech Inc' -or $file.VersionInfo.FileVersion -notmatch '^2021\.3\.') {throw 'Invalid legacy installer: Logitech signature and version 2021.3 are required.'}
    $file
}
Export-ModuleMember -Function Get-VerifiedRelease,Get-VerifiedLegacyInstaller
