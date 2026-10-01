BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Core.psm1" -Force -DisableNameChecking
    Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
    $path="$PSScriptRoot/../src/Modules/Lifecycle.psm1"
    if (Test-Path $path) { Import-Module $path -Force -DisableNameChecking }
}
Describe 'Lifecycle preconditions' {
    It 'does not terminate another user session' {
        $process=@{Name='lghub_agent.exe';OwnerSid='another';Path='C:\Program Files\LGHUB\lghub_agent.exe'}
        { Assert-GHUBProcessOwnership @($process) 'owner' } | Should -Throw '*OtherSessionActive*'
    }
    It 'does not forcibly stop an update in progress' {
        $process=@{Name='lghub_software_manager.exe';OwnerSid='owner';Path='C:\Program Files\LGHUB\lghub_software_manager.exe'}
        { Assert-GHUBProcessOwnership @($process) 'owner' } | Should -Throw '*UpdateInProgress*'
    }
    It 'treats unverified update control as a blocking condition' {
        (Test-UpdatePolicy $null @{UpdatePolicy=@{Verified=$false}}).Code | Should -Be UpdatePolicyUnverified
    }
    It 'rejects a confirmation that applies to another product version' {
        $manifest=@{ProductVersion='2021.3';UpdatePolicy=@{Verified=$true;ProductVersion='2026.6';Method='ObservedUI';Evidence=@('record')}}
        (Test-UpdatePolicy $null $manifest).Status | Should -Be Blocked
    }
    It 'does not overwrite a registry value changed by something else' {
        $source=@{Exists=$true;Kind='String';Value='source'}
        $actual=@{Exists=$true;Kind='String';Value='outside-change'}
        { Assert-RegistryBefore $source $actual } | Should -Throw '*ExternalChange*'
    }
    It 'differentiates an absent value from an empty string' {
        { Assert-RegistryBefore @{Exists=$false;Kind='String';Value=$null} @{Exists=$true;Kind='String';Value=''} } | Should -Throw '*ExternalChange*'
    }
    It 'captures actual service dependencies and restart actions without mutation' {
        Initialize-NativeLibrary
        $s=[GHubSwitcher.ServiceApi]::Capture('LGHUBUpdaterService')
        $s.ImagePath | Should -Match 'lghub_updater\.exe'
        $s.Account | Should -Be 'LocalSystem'
        $expectedStart=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LGHUBUpdaterService').Start
        $s.StartType | Should -Be $expectedStart
    }
}
Describe 'Native service restoration policy' {
    It 'requests SERVICE_START when restoring restart failure actions' {
        Initialize-NativeLibrary
        $record=[GHubSwitcher.ServiceRecord]::new(); $record.StartType=2
        $record.FailureActions=@([GHubSwitcher.FailureAction]@{Type=1;Delay=60000})
        $policy=[GHubSwitcher.ServiceApi]::GetRestorePolicy($record,$false,$false)
        ($policy.AccessMask -band 0x10) | Should -Be 0x10
        $policy.FailureActions.Count | Should -Be 1
    }
    It 'disables managed services throughout mutation then allows controlled launch' {
        Initialize-NativeLibrary
        $record=[GHubSwitcher.ServiceRecord]::new(); $record.StartType=2
        $record.FailureActions=@([GHubSwitcher.FailureAction]@{Type=1;Delay=60000})
        $stopped=[GHubSwitcher.ServiceApi]::GetRestorePolicy($record,$true,$true)
        $stopped.StartType | Should -Be 4
        $stopped.FailureActions.Count | Should -Be 0
        $launch=[GHubSwitcher.ServiceApi]::GetRestorePolicy($record,$true,$false)
        $launch.StartType | Should -Be 3
        $launch.FailureActions.Count | Should -Be 0
    }
}
Describe 'Noninteractive process quiescence' {
    BeforeEach {
        InModuleScope Lifecycle {
            $script:quiescenceProcesses=[Collections.ArrayList]@([pscustomobject]@{Id=7260;Name='lghub_system_tray.exe';Path='C:\Program Files\LGHUB\lghub_system_tray.exe';OwnerSid='S-1-5-21-1-2-3-1001';SessionId=1})
            Mock Assert-Administrator {}
            Mock Get-GHUBInventory { [pscustomobject]@{Processes=@($script:quiescenceProcesses)} }
            Mock Get-ActiveDirectories { @{Program='C:\Program Files\LGHUB'} }
            Mock Get-Process {}
            Mock Start-Sleep {}
            # SYSTEM stopping an owner's process prompts unless Force is supplied.
            # Model that OS boundary without stopping any real process or service.
            Mock Stop-Process {
                param($Id,[switch]$Force)
                if(-not $Force){throw 'Windows PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.'}
                foreach($process in @($script:quiescenceProcesses | Where-Object {$_.Id -in $Id})){$script:quiescenceProcesses.Remove($process)}
            }
        }
    }
    It 'quiesces the registered user tray from a noninteractive worker without prompting' {
        InModuleScope Lifecycle {
            $ctx=@{OwnerSid='S-1-5-21-1-2-3-1001'}
            (Stop-GHUBEnvironment $ctx @{Services=@()}).Status | Should -Be Ok
            $script:quiescenceProcesses.Count | Should -Be 0
        }
    }
    It 'still refuses to terminate a different user session' {
        InModuleScope Lifecycle {
            $script:quiescenceProcesses[0].OwnerSid='S-1-5-21-1-2-3-1002'
            { Stop-GHUBEnvironment @{OwnerSid='S-1-5-21-1-2-3-1001'} @{Services=@()} } | Should -Throw '*OtherSessionActive*'
            $script:quiescenceProcesses.Count | Should -Be 1
        }
    }
    It 'still refuses to terminate a process outside the recorded installation' {
        InModuleScope Lifecycle {
            $script:quiescenceProcesses[0].Path='C:\Elsewhere\lghub_system_tray.exe'
            { Stop-GHUBEnvironment @{OwnerSid='S-1-5-21-1-2-3-1001'} @{Services=@()} } | Should -Throw '*UnsafePath*'
            $script:quiescenceProcesses.Count | Should -Be 1
        }
    }
}
Describe 'Privileged owner-login continuation' {
    It 'registers owner login and startup on the privileged worker and queues overlapping triggers' {
        InModuleScope Lifecycle {
            Mock Assert-Administrator {}
            $script:registered=@{}
            Mock Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings) $script:registered[$TaskName]=@{Action=$Action;Trigger=@($Trigger);Principal=$Principal;Settings=$Settings}}
            $ctx=@{Root='C:\fixture';OwnerSid='S-1-5-21-1-2-3-1001'}
            $null=Install-StartupControl $ctx @{Startup=@();Tasks=@()}
            $boot=$script:registered['GHUBSwitcher-RecoverAtBoot']
            $boot.Principal.UserId | Should -Be SYSTEM
            @($boot.Trigger | Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.UserId -eq $ctx.OwnerSid}).Count | Should -Be 1
            $boot.Settings.MultipleInstances | Should -Be 1
            $boot.Settings.RestartCount | Should -BeGreaterThan 0
            $user=$script:registered['GHUBSwitcher-UserSession']
            $user.Principal.UserId | Should -Be $ctx.OwnerSid
            $user.Principal.RunLevel | Should -Be 0
            @($user.Trigger | Where-Object {$_}).Count | Should -Be 0
        }
    }
}
