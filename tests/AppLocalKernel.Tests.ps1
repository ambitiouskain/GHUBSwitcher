BeforeAll {
    foreach($name in @('Core','Inventory','Lifecycle')){Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Initialize-NativeLibrary
}
Describe 'App-local kernel identity and capture' {
    BeforeEach {
        InModuleScope Inventory {
            $script:tempPath=Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys'
            $script:tempNative=[pscustomobject]@{Name='LGHUBTemperatureService';ImagePath=('\??\'+$script:tempPath);ServiceType=1;StartType=2;ErrorControl=1;Account='';DisplayName='LGHUBTemperatureService';LoadOrderGroup='';TagId=0;Dependencies=@();CurrentState=4}
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureService';PathName=('\??\'+$script:tempPath);State='Running';StartMode='Auto';ServiceType='Kernel Driver'} }
            Mock Get-AppLocalKernelNativeRecord { $script:tempNative }
            Mock Test-Path { $true }
            Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::Normal} }
            Mock Get-FileHash { [pscustomobject]@{Hash=('a'*64)} }
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=@{Subject='CN=Logitech Inc, O=Logitech Inc, C=US';Thumbprint=('b'*40)}} }
        }
    }
    It 'normalizes only supported absolute kernel path forms' {
        (ConvertTo-KernelImagePath '\??\C:\Program Files\LGHUB\logi_core_temp.sys') | Should -Be 'C:\Program Files\LGHUB\logi_core_temp.sys'
        (ConvertTo-KernelImagePath '\SystemRoot\System32\drivers\fixture.sys') | Should -Be (Join-Path $env:WINDIR 'System32\drivers\fixture.sys')
        foreach($path in @('\??\UNC\server\share\driver.sys','\Device\HarddiskVolume1\driver.sys','C:driver.sys','..\driver.sys')){{ConvertTo-KernelImagePath $path} | Should -Throw '*UnsafePath*'}
    }
    It 'captures the one known signed service with native kernel configuration and file evidence' {
        InModuleScope Inventory {
            $record=@(Get-AppLocalKernelInventory)[0]
            $record.Name | Should -Be LGHUBTemperatureService
            $record.Path | Should -Be $script:tempPath
            $record.RawPath | Should -Be ('\??\'+$script:tempPath)
            $record.AppLocal | Should -BeTrue
            $record.Native.ServiceType | Should -Be 1
            $record.Native.StartType | Should -Be 2
            $record.Sha256 | Should -Be ('a'*64)
            $record.FileEvidence.Relative | Should -Be logi_core_temp.sys
        }
    }
    It 'rejects a wrong executable directory signature or reparse point' {
        InModuleScope Inventory {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=@{Subject='CN=Another Publisher, O=Another Publisher';Thumbprint=('b'*40)}} }
            {Get-AppLocalKernelInventory} | Should -Throw '*UnownedAppLocalKernel*'
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
            {Get-AppLocalKernelInventory} | Should -Throw '*UnownedAppLocalKernel*'
            Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint} }
            {Get-AppLocalKernelInventory} | Should -Throw '*UnsafePath*'
        }
    }
    It 'allows a missing inactive legacy binary only when the exact service is stopped and disabled' {
        InModuleScope Inventory {
            Mock Test-Path { $false }
            $script:tempNative.StartType=4;$script:tempNative.CurrentState=1
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureService';PathName=('\??\'+$script:tempPath);State='Stopped';StartMode='Disabled';ServiceType='Kernel Driver'} }
            @(Get-AppLocalKernelInventory).Count | Should -Be 0
            $script:tempNative.CurrentState=4
            {Get-AppLocalKernelInventory} | Should -Throw '*AppLocalKernelMissing*'
        }
    }
    It 'does not extend the exception to another service with an LGHUB-looking name' {
        InModuleScope Inventory {
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureServiceOther';PathName=('\??\'+$script:tempPath);State='Running';StartMode='Auto';ServiceType='Kernel Driver'} }
            Mock Get-AppLocalKernelNativeRecord { $null }
            @(Get-AppLocalKernelInventory).Count | Should -Be 0
            Should -Invoke Get-AppLocalKernelNativeRecord -Times 1 -Exactly
        }
    }
    It 'does not hide a file permission or hashing failure' {
        InModuleScope Inventory {
            Mock Get-FileHash {throw 'fixture binary access denied'}
            {Get-AppLocalKernelInventory} | Should -Throw '*fixture binary access denied*'
        }
    }
}
Describe 'App-local kernel lifecycle boundaries' {
    BeforeEach {
        InModuleScope Lifecycle {
            $script:kernelContext=@{Root='C:\fixture';Mode='Simulation';OwnerSid='fixture'}
            $native=[pscustomobject]@{Name='LGHUBTemperatureService';ImagePath='\??\C:\Program Files\LGHUB\logi_core_temp.sys';ServiceType=1;StartType=2;ErrorControl=1;Account='';DisplayName='LGHUBTemperatureService';LoadOrderGroup='';TagId=0;Dependencies=@();CurrentState=4}
            $script:kernelEntry=[pscustomobject]@{Name='LGHUBTemperatureService';AppLocal=$true;Path='C:\Program Files\LGHUB\logi_core_temp.sys';RawPath=$native.ImagePath;RelativePath='logi_core_temp.sys';Sha256=('a'*64);SignatureThumbprint=('b'*40);Native=$native;State='Running';StartType=2;FileEvidence=@{Relative='logi_core_temp.sys';Sha256=('a'*64)}}
            $script:kernelManifest=[pscustomobject]@{KernelServices=@($script:kernelEntry);Files=@(@{Relative='logi_core_temp.sys';Sha256=('a'*64)})}
            Mock Assert-Administrator {}
            Mock Read-SwitchState { @{TransactionId='fixture'} }
            Mock Add-JournalEntry {}
            Mock Get-AppLocalKernelNativeRecord { $script:kernelEntry.Native }
            Mock Assert-AppLocalKernelFile { @{Relative='logi_core_temp.sys';Sha256=('a'*64);SignatureThumbprint=('b'*40)} }
            Mock Invoke-AppLocalKernelStop { [pscustomobject]@{Stopped=$true;State=1} }
            Mock Invoke-AppLocalKernelRestore {}
        }
    }
    It 'does not touch SCM when neither manifest contains the component' {
        InModuleScope Lifecycle {
            Stop-EnvironmentAppLocalKernel $script:kernelContext @{KernelServices=@()} @{KernelServices=@()}
            Restore-EnvironmentAppLocalKernel $script:kernelContext @{KernelServices=@()}
            Should -Invoke Get-AppLocalKernelNativeRecord -Times 0
            Should -Invoke Invoke-AppLocalKernelStop -Times 0
            Should -Invoke Invoke-AppLocalKernelRestore -Times 0
        }
    }
    It 'journals and stops the captured source before directory exchange may proceed' {
        InModuleScope Lifecycle {
            Stop-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest @{KernelServices=@()}
            Should -Invoke Invoke-AppLocalKernelStop -Times 1
            Should -Invoke Add-JournalEntry -Times 1 -ParameterFilter {$Kind -eq 'Intent' -and $StepId -eq 'app-local-kernel-stop'}
            Should -Invoke Add-JournalEntry -Times 1 -ParameterFilter {$Kind -eq 'Done' -and $StepId -eq 'app-local-kernel-stop'}
        }
    }
    It 'blocks the exchange when the kernel refuses or fails to unload' {
        InModuleScope Lifecycle {
            Mock Invoke-AppLocalKernelStop { throw 'The requested control is not valid for this service.' }
            {Stop-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest @{KernelServices=@()}} | Should -Throw '*AppLocalKernelRestartRequired*'
            Should -Invoke Invoke-AppLocalKernelRestore -Times 0
        }
    }
    It 'does not stop an image that differs from its manifest evidence' {
        InModuleScope Lifecycle {
            $script:kernelManifest.Files[0].Sha256='wrong'
            {Stop-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest @{KernelServices=@()}} | Should -Throw '*UnownedAppLocalKernel*'
            Should -Invoke Invoke-AppLocalKernelStop -Times 0
        }
    }
    It 'restores the target native configuration and only starts it at the launch boundary' {
        InModuleScope Lifecycle {
            Restore-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest
            Restore-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest -ForLaunch
            Should -Invoke Invoke-AppLocalKernelRestore -Times 1 -ParameterFilter {-not $Start}
            Should -Invoke Invoke-AppLocalKernelRestore -Times 1 -ParameterFilter {$Start}
        }
    }
    It 'does not adopt a kernel that lacks captured native metadata' {
        InModuleScope Lifecycle {
            $script:kernelEntry.Native=$null
            {Restore-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest} | Should -Throw '*UnownedAppLocalKernel*'
            Should -Invoke Invoke-AppLocalKernelRestore -Times 0
        }
    }
    It 'accepts a dormant target-only service without touching an absent active binary' {
        InModuleScope Lifecycle {
            $script:dormantNative=$script:kernelEntry.Native|ConvertTo-Json -Depth 8|ConvertFrom-Json
            $script:dormantNative.CurrentState=1;$script:dormantNative.StartType=4
            Mock Get-AppLocalKernelNativeRecord { $script:dormantNative }
            Stop-EnvironmentAppLocalKernel $script:kernelContext @{KernelServices=@()} $script:kernelManifest
            Should -Invoke Assert-AppLocalKernelFile -Times 0
            Should -Invoke Invoke-AppLocalKernelStop -Times 0
        }
    }
    It 'blocks an active driver that is outside the captured source' {
        InModuleScope Lifecycle {
            {Stop-EnvironmentAppLocalKernel $script:kernelContext @{KernelServices=@()} $script:kernelManifest} | Should -Throw '*UnownedAppLocalKernel*'
            Should -Invoke Invoke-AppLocalKernelStop -Times 0
        }
    }
    It 'requires explicit SCM stopped confirmation even when the control call returned' {
        InModuleScope Lifecycle {
            Mock Invoke-AppLocalKernelStop { [pscustomobject]@{Stopped=$false;State=3} }
            {Stop-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest} | Should -Throw '*AppLocalKernelRestartRequired*'
            Should -Invoke Add-JournalEntry -Times 0 -ParameterFilter {$Kind -eq 'Done'}
        }
    }
    It 'validates a fresh inventory manifest using its embedded file evidence before rollback' {
        InModuleScope Lifecycle {
            $script:kernelManifest.Files=@()
            Stop-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest
            Should -Invoke Assert-AppLocalKernelFile -Times 1
            Should -Invoke Invoke-AppLocalKernelStop -Times 1
        }
    }
    It 'refuses partially recorded native configuration instead of filling fields with defaults' {
        InModuleScope Lifecycle {
            $script:kernelEntry.Native.PSObject.Properties.Remove('ErrorControl')
            {Restore-EnvironmentAppLocalKernel $script:kernelContext $script:kernelManifest} | Should -Throw '*Missing native kernel configuration*'
            Should -Invoke Invoke-AppLocalKernelRestore -Times 0
        }
    }
}
Describe 'Native kernel-specific policy' {
    It 'accepts only a kernel record for the fixed signed-file location and never a Win32 service' {
        Initialize-NativeLibrary
        $record=[GHubSwitcher.ServiceRecord]::new();$record.Name='LGHUBTemperatureService';$record.ImagePath='\??\'+(Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys');$record.ServiceType=1;$record.StartType=2;$record.ErrorControl=1
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Not -Throw
        $record.ServiceType=16
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Throw '*kernel*'
        $record.ServiceType=1;$record.ImagePath='C:\Other\logi_core_temp.sys'
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Throw '*kernel*'
    }
    It 'rejects unsupported load-order account and dependency settings rather than dropping them' {
        $record=[GHubSwitcher.ServiceRecord]::new();$record.Name='LGHUBTemperatureService';$record.ImagePath='\??\'+(Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys');$record.ServiceType=1;$record.StartType=2;$record.ErrorControl=1
        $record.Account='LocalSystem'
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Throw '*Unsupported*'
        $record.Account='';$record.Dependencies=@('foreign')
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Throw '*Unsupported*'
        $record.Dependencies=@();$record.TagId=1
        {[GHubSwitcher.ServiceApi]::ValidateAppLocalKernelRecord($record)} | Should -Throw '*Unsupported*'
    }
    It 'never rewrites a loaded kernel and only reuses an identical running target during launch' {
        $record=[GHubSwitcher.ServiceRecord]::new();$record.Name='LGHUBTemperatureService';$record.ImagePath='\??\'+(Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys');$record.ServiceType=1;$record.StartType=2;$record.ErrorControl=1;$record.CurrentState=4
        [GHubSwitcher.ServiceApi]::KeepRunningAppLocalKernel($record,$record,$true) | Should -BeTrue
        {[GHubSwitcher.ServiceApi]::KeepRunningAppLocalKernel($record,$record,$false)} | Should -Throw '*must be stopped*'
        $record.CurrentState=2
        {[GHubSwitcher.ServiceApi]::KeepRunningAppLocalKernel($record,$record,$true)} | Should -Throw '*must be stopped*'
        $record.CurrentState=1
        [GHubSwitcher.ServiceApi]::KeepRunningAppLocalKernel($record,$record,$true) | Should -BeFalse
    }
}
