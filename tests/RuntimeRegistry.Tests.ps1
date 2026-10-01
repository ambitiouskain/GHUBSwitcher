BeforeAll {
    foreach($module in @('Core','Inventory','Lifecycle')){Import-Module (Join-Path $PSScriptRoot "../src/Modules/$module.psm1") -Force -DisableNameChecking}
}

Describe 'Quiesced runtime configuration registry capture' {
    BeforeEach {
        InModuleScope Lifecycle {
            $script:runtimeContext=@{Root=$TestDrive;OwnerSid='S-1-5-21-1-2-3-1001'}
            $script:dataPath='Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Logitech\LGHUB\Data'
            $script:identityPath='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{fixture}'
            $script:runtimeManifest=[pscustomobject]@{Slot='modern';RegistryValues=@(
                [pscustomobject]@{Path=$script:identityPath;Name='DisplayVersion';Exists=$true;Kind='String';Value='2026.6'},
                [pscustomobject]@{Path=$script:dataPath;Name='old-random-name';Exists=$true;Kind='Binary';Value=@(1,2,3)}
            )}
            $script:currentRegistry=@(
                [pscustomobject]@{Path=$script:identityPath;Name='DisplayVersion';Exists=$true;Kind='String';Value='2026.6'},
                [pscustomobject]@{Path=($script:dataPath+'\new-subkey');Name='new-random-name';Exists=$true;Kind='Binary';Value=@(4,5,6)}
            )
            Mock Get-GHUBInventory { [pscustomobject]@{Processes=@()} }
            Mock Get-GHUBRegistryValues { [pscustomobject]@{Roots=@();Values=$script:currentRegistry} }
        }
    }
    It 'captures added and deleted app settings while preserving installation identity' {
        InModuleScope Lifecycle {
            $actual=Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest
            @($actual.RegistryValues | Where-Object Name -eq 'old-random-name').Count | Should -Be 0
            @($actual.RegistryValues | Where-Object Name -eq 'new-random-name').Count | Should -Be 1
            ($actual.RegistryValues | Where-Object Name -eq 'DisplayVersion').Value | Should -Be '2026.6'
            @($script:runtimeManifest.RegistryValues | Where-Object Name -eq 'old-random-name').Count | Should -Be 1
            $actual.RuntimeRegistryCapturedAt | Should -Not -BeNullOrEmpty
        }
    }
    It 'keeps registry capture blocked while a G HUB process is still running' {
        InModuleScope Lifecycle {
            Mock Get-GHUBInventory { [pscustomobject]@{Processes=@(@{Name='lghub_agent.exe'})} }
            { Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest } | Should -Throw '*Busy*'
        }
    }
    It 'does not absorb an external installation version change as user configuration' {
        InModuleScope Lifecycle {
            $script:currentRegistry[0].Value='unknown-version'
            { Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest } | Should -Throw '*ExternalChange*'
        }
    }
    It 'rejects newly introduced nonconfiguration product registry values' {
        InModuleScope Lifecycle {
            $script:currentRegistry+=@{Path='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\LGHUB';Name='InstallPath';Exists=$true;Kind='String';Value='C:\Unknown'}
            { Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest } | Should -Throw '*ExternalChange*'
        }
    }
    It 'does not treat another users Data tree or a Data-prefixed key as runtime settings' {
        InModuleScope Lifecycle {
            $script:currentRegistry+=@{Path=($script:dataPath+'External');Name='setting';Exists=$true;Kind='String';Value='other'}
            { Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest } | Should -Throw '*ExternalChange*'
            $script:currentRegistry=$script:currentRegistry[0..1]
            $script:currentRegistry+=@{Path=($script:dataPath -replace '1001','1002');Name='setting';Exists=$true;Kind='String';Value='other'}
            { Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest } | Should -Throw '*ExternalChange*'
        }
    }
    It 'rejects a newly added setting after capture before making any registry writes' {
        InModuleScope Lifecycle {
            $captured=Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest
            $script:currentRegistry+=@{Path=$script:dataPath;Name='late-arrival';Exists=$true;Kind='String';Value='outside-change'}
            Mock Assert-Administrator {}
            Mock Read-SwitchState { @{TransactionId='fixture'} }
            Mock Write-RegistryValue { throw 'Unexpected registry write after drift.' }
            { Apply-EnvironmentRegistry $script:runtimeContext $captured $captured } | Should -Throw '*ExternalChange*'
        }
    }
    It 'checks both installation identities whose composite keys are culture-equivalent' {
        InModuleScope Lifecycle {
            $root='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\LGHUB\profile'
            $script:runtimeManifest.RegistryValues=@(
                [pscustomobject]@{Path=$root;Name='\branch\setting';Exists=$true;Kind='String';Value='first-identity'},
                [pscustomobject]@{Path=($root+'\branch');Name='\setting';Exists=$true;Kind='String';Value='second-identity'}
            )
            foreach($changedIndex in @(0,1)){
                $script:currentRegistry=$script:runtimeManifest.RegistryValues|ConvertTo-Json -Depth 10|ConvertFrom-Json
                $script:currentRegistry[$changedIndex].Value='unapproved-installation-change'
                {Update-EnvironmentRuntimeRegistry $script:runtimeContext $script:runtimeManifest} | Should -Throw '*ExternalChange*'
            }
        }
    }
}
