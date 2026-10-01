BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
Describe 'Portable runtime data location' {
    It 'uses Data inside an extracted folder, including spaces and non-ASCII paths' {
        $folder=Join-Path $TestDrive '便携 工具'
        [IO.Directory]::CreateDirectory($folder)|Out-Null
        (Get-SwitcherRoot $folder)|Should -BeExactly (Join-Path $folder 'Data')
    }
    It 'resolves an initialized runtime App back to its containing data root' {
        $root=Join-Path $TestDrive 'portable/Data'
        [IO.Directory]::CreateDirectory((Join-Path $root 'App'))|Out-Null
        @{SchemaVersion=1;InstalledRuntime=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'App/release-manifest.json') -Encoding UTF8
        (Get-SwitcherRoot (Join-Path $root 'App'))|Should -BeExactly $root
    }
    It 'accepts a registered portable live root and rejects mismatched registration' {
        $root=Join-Path $TestDrive 'portable-live/Data'
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $registration=@{Portable=$true;Root=$root;OwnerSid=$sid;ProfileRoot=$TestDrive}
        Write-AtomicJson (Join-Path $root 'registration.json') $registration
        (New-SwitchContext $root $sid $TestDrive -Mode Live).Root|Should -BeExactly $root
        $registration.Root=Join-Path $TestDrive 'another/Data'
        Write-AtomicJson (Join-Path $root 'registration.json') $registration
        {New-SwitchContext $root $sid $TestDrive -Mode Live}|Should -Throw '*PortableRootMismatch*'
    }
    It 'does not accept an arbitrary unregistered live directory' {
        {New-SwitchContext (Join-Path $TestDrive 'arbitrary') $sid $TestDrive -Mode Live}|Should -Throw
    }
    It 'rejects a registered Data directory replaced by a junction before reading its state' {
        $root=Join-Path $TestDrive 'junction-package/Data'
        $target=Join-Path $TestDrive 'relocated-data'
        [IO.Directory]::CreateDirectory((Split-Path $root -Parent))|Out-Null
        [IO.Directory]::CreateDirectory($target)|Out-Null
        Write-AtomicJson (Join-Path $target 'registration.json') @{Portable=$true;Root=$root;OwnerSid=$sid;ProfileRoot=$TestDrive}
        New-Item -ItemType Junction -Path $root -Value $target|Out-Null
        try{
            {New-SwitchContext $root $sid $TestDrive -Mode Live}|Should -Throw '*UnsafePath*'
            Test-Path -LiteralPath (Join-Path $target 'State')|Should -BeFalse
        }finally{[IO.Directory]::Delete($root,$false)}
    }
    It 'serializes two portable folders that manage the same installed G HUB' {
        $roots=@((Join-Path $TestDrive 'one/Data'),(Join-Path $TestDrive 'two/Data'))
        $contexts=@(foreach($root in $roots){
            [IO.Directory]::CreateDirectory($root)|Out-Null
            Write-AtomicJson (Join-Path $root 'registration.json') @{Portable=$true;Root=$root;OwnerSid=$sid;ProfileRoot=$TestDrive}
            New-SwitchContext $root $sid $TestDrive -Mode Live
        })
        $lease=Enter-SwitchLock $contexts[0]
        try{{Enter-SwitchLock $contexts[1]}|Should -Throw '*Busy*'}finally{$lease.Dispose()}
        $next=Enter-SwitchLock $contexts[1];$next.Dispose()
    }
}
