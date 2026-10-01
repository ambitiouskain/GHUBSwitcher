BeforeAll {
    foreach($module in @('Core','Inventory','Lifecycle','Coordinator')){Import-Module (Join-Path $PSScriptRoot "../src/Modules/$module.psm1") -Force -DisableNameChecking}
    Import-Module (Join-Path $PSScriptRoot 'TestSupport.psm1') -Force
}
Describe 'Registry application and rollback with real disposable user keys' {
    BeforeEach {
        $subkey='Software\GHUBSwitcherTests\'+[guid]::NewGuid().ToString('N')
        $registryPath='Registry::HKEY_CURRENT_USER\'+$subkey
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subkey)
        try {$key.SetValue('text','old');$key.SetValue('remove','old')} finally {$key.Dispose()}
        $ctx=New-TestContext -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Mock Assert-Administrator -ModuleName Lifecycle {}
        Mock Test-GHUBRegistryPath -ModuleName Lifecycle {}
        Mock Test-GHUBRegistryPath -ModuleName Coordinator {}
    }
    AfterEach {
        if($subkey -match '^Software\\GHUBSwitcherTests\\[a-f0-9]{32}$'){
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subkey,$false)
        }
    }
    It 'writes persisted registry types and removes absent target values' {
        $source=@{RegistryValues=@(
            @{Path=$registryPath;Name='text';Exists=$true;Kind='String';Value='old'},
            @{Path=$registryPath;Name='remove';Exists=$true;Kind='String';Value='old'}
        )}
        $records=@(
            @{Path=$registryPath;Name='text';Exists=$true;Kind='ExpandString';Value='%TEMP%\fixture'},
            @{Path=$registryPath;Name='binary';Exists=$true;Kind='Binary';Value=@(0,128,255)},
            @{Path=$registryPath;Name='multi';Exists=$true;Kind='MultiString';Value=@('one','two')},
            @{Path=$registryPath;Name='dword';Exists=$true;Kind='DWord';Value=7},
            @{Path=$registryPath;Name='qword';Exists=$true;Kind='QWord';Value=4294967296},
            @{Path=$registryPath;Name='';Exists=$true;Kind='String';Value='default'}
        )
        $target=(@{RegistryValues=$records}|ConvertTo-Json -Depth 6|ConvertFrom-Json)
        $null=Apply-EnvironmentRegistry $ctx $source $target
        (Read-RegistryValue $registryPath 'text').Kind | Should -Be 'ExpandString'
        (Read-RegistryValue $registryPath 'text').Value | Should -Be '%TEMP%\fixture'
        [Convert]::ToBase64String((Read-RegistryValue $registryPath 'binary').Value) | Should -Be 'AID/'
        ((Read-RegistryValue $registryPath 'multi').Value -join ',') | Should -Be 'one,two'
        (Read-RegistryValue $registryPath 'dword').Value | Should -Be 7
        (Read-RegistryValue $registryPath 'qword').Value | Should -Be 4294967296
        (Read-RegistryValue $registryPath '').Value | Should -Be 'default'
        (Read-RegistryValue $registryPath 'remove').Exists | Should -BeFalse
    }
    It 'restores a changed value and removes a newly created value from the journal' {
        $before=@{Path=$registryPath;Name='text';Record=@{Exists=$true;Kind='String';Value='old'}}
        $after=@{Exists=$true;Kind='String';Value='new'}
        Add-JournalEntry $ctx fixture Intent registry-text $before $after
        Add-JournalEntry $ctx fixture Intent registry-added @{Path=$registryPath;Name='added';Record=@{Exists=$false;Kind='';Value=$null}} $after
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
        try {$key.SetValue('text','new');$key.SetValue('added','new')} finally {$key.Dispose()}
        Undo-RegistryJournal $ctx fixture
        (Read-RegistryValue $registryPath 'text').Value | Should -Be 'old'
        (Read-RegistryValue $registryPath 'added').Exists | Should -BeFalse
    }
}
