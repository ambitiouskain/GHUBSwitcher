BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/Inventory.psm1" -Force -DisableNameChecking
    Initialize-NativeLibrary
}
Describe 'SCM authoritative app-local kernel inventory' {
    BeforeEach {
        InModuleScope Inventory {
            $script:scmKernelPath=Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys'
            $script:scmKernel=[pscustomobject]@{
                Name='LGHUBTemperatureService';ImagePath=('\??\'+$script:scmKernelPath)
                ServiceType=1;StartType=2;ErrorControl=1;Account='';DisplayName='LGHUBTemperatureService'
                LoadOrderGroup='';TagId=0;Dependencies=@();CurrentState=1;ControlsAccepted=0
                FailureActions=@();TriggerCount=0;DelayedAutoStart=$false
            }
            Mock Get-CimInstance { @() }
            Mock Get-AppLocalKernelNativeRecord { $script:scmKernel }
            Mock Test-Path { $true }
            Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::Normal} }
            Mock Get-FileHash { [pscustomobject]@{Hash=('a'*64)} }
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=@{Subject='CN=Logitech Inc, O=Logitech Inc, C=US';Thumbprint=('b'*40)}} }
        }
    }
    It 'rejects an SCM-only missing binary in state <State> with start type <StartType>' -TestCases @(
        @{State=1;StartType=2},
        @{State=1;StartType=3},
        @{State=4;StartType=4},
        @{State=2;StartType=4}
    ) {
        param($State,$StartType)
        InModuleScope Inventory -Parameters @{State=$State;StartType=$StartType} {
            param($State,$StartType)
            $script:scmKernel.CurrentState=$State;$script:scmKernel.StartType=$StartType
            Mock Test-Path { $false }
            { Get-AppLocalKernelInventory } | Should -Throw '*AppLocalKernelMissing*'
        }
    }
    It 'omits an SCM-only missing binary only when stopped and disabled' {
        InModuleScope Inventory {
            $script:scmKernel.CurrentState=1;$script:scmKernel.StartType=4
            Mock Test-Path { $false }
            @(Get-AppLocalKernelInventory).Count | Should -Be 0
        }
    }
    It 'captures an SCM-only signed binary as <ExpectedState> and <ExpectedStartMode>' -TestCases @(
        @{State=4;StartType=2;ExpectedState='Running';ExpectedStartMode='Auto'},
        @{State=1;StartType=3;ExpectedState='Stopped';ExpectedStartMode='Manual'},
        @{State=1;StartType=4;ExpectedState='Stopped';ExpectedStartMode='Disabled'}
    ) {
        param($State,$StartType,$ExpectedState,$ExpectedStartMode)
        InModuleScope Inventory -Parameters @{State=$State;StartType=$StartType;ExpectedState=$ExpectedState;ExpectedStartMode=$ExpectedStartMode} {
            param($State,$StartType,$ExpectedState,$ExpectedStartMode)
            $script:scmKernel.CurrentState=$State;$script:scmKernel.StartType=$StartType
            $records=@(Get-AppLocalKernelInventory)
            $records.Count | Should -Be 1
            $record=$records[0]
            $record.Name | Should -Be 'LGHUBTemperatureService'
            $record.Path | Should -Be $script:scmKernelPath
            $record.RawPath | Should -Be ('\??\'+$script:scmKernelPath)
            $record.State | Should -Be $ExpectedState
            $record.StartMode | Should -Be $ExpectedStartMode
            $record.StartType | Should -Be $StartType
            $record.AppLocal | Should -BeTrue
            $record.Sha256 | Should -Be ('a'*64)
            $record.SignatureThumbprint | Should -Be ('b'*40)
            $record.RelativePath | Should -Be 'logi_core_temp.sys'
            $record.FileEvidence.Signer | Should -Be 'CN=Logitech Inc, O=Logitech Inc, C=US'
            $record.Native.ServiceType | Should -Be 1
        }
    }
    It 'returns no component when neither SCM nor WMI has the service' {
        InModuleScope Inventory {
            Mock Get-AppLocalKernelNativeRecord { $null }
            @(Get-AppLocalKernelInventory).Count | Should -Be 0
        }
    }
    It 'rejects WMI evidence when the service is absent from SCM' {
        InModuleScope Inventory {
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureService';PathName=$script:scmKernelPath} }
            Mock Get-AppLocalKernelNativeRecord { $null }
            { Get-AppLocalKernelInventory } | Should -Throw '*AppLocalKernelMissing*'
        }
    }
    It 'preserves WMI raw path when the normalized WMI and SCM paths agree' {
        InModuleScope Inventory {
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureService';PathName=$script:scmKernelPath} }
            $record=@(Get-AppLocalKernelInventory)[0]
            $record.RawPath | Should -Be $script:scmKernelPath
            $record.Native.ImagePath | Should -Be ('\??\'+$script:scmKernelPath)
        }
    }
    It 'rejects conflicting WMI and SCM image paths even for an inactive missing binary' {
        InModuleScope Inventory {
            $script:scmKernel.CurrentState=1;$script:scmKernel.StartType=4
            Mock Test-Path { $false }
            Mock Get-CimInstance { [pscustomobject]@{Name='LGHUBTemperatureService';PathName='C:\Other\logi_core_temp.sys'} }
            { Get-AppLocalKernelInventory } | Should -Throw '*UnownedAppLocalKernel*'
        }
    }
    It 'rejects ambiguous matching WMI records' {
        InModuleScope Inventory {
            Mock Get-CimInstance { @([pscustomobject]@{Name='LGHUBTemperatureService';PathName=$script:scmKernelPath},[pscustomobject]@{Name='LGHUBTemperatureService';PathName=$script:scmKernelPath}) }
            { Get-AppLocalKernelInventory } | Should -Throw '*UnownedAppLocalKernel*'
        }
    }
    It 'validates the SCM-only fixed path before omitting an inactive missing binary' {
        InModuleScope Inventory {
            $script:scmKernel.CurrentState=1;$script:scmKernel.StartType=4
            $script:scmKernel.ImagePath='C:\Other\logi_core_temp.sys'
            Mock Test-Path { $false }
            { Get-AppLocalKernelInventory } | Should -Throw '*Unowned app-local kernel path*'
        }
    }
    It 'rejects unsupported SCM-only native configuration' {
        InModuleScope Inventory {
            $script:scmKernel.StartType=0
            { Get-AppLocalKernelInventory } | Should -Throw '*Unsupported app-local kernel configuration*'
        }
    }
    It 'requires a valid Logitech signature for an SCM-only binary' {
        InModuleScope Inventory {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
            { Get-AppLocalKernelInventory } | Should -Throw '*UnownedAppLocalKernel*'
        }
    }
    It 'rejects reparse points for an SCM-only binary' {
        InModuleScope Inventory {
            Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint} }
            { Get-AppLocalKernelInventory } | Should -Throw '*UnsafePath*'
        }
    }
    It 'rejects an SCM-only service changing state with a present binary' {
        InModuleScope Inventory {
            $script:scmKernel.CurrentState=2
            { Get-AppLocalKernelInventory } | Should -Throw '*Busy*'
        }
    }
    It 'does not treat a failed WMI query as an empty result' {
        InModuleScope Inventory {
            Mock Get-CimInstance { throw 'fixture WMI access denied' }
            { Get-AppLocalKernelInventory } | Should -Throw '*fixture WMI access denied*'
        }
    }
    It 'does not treat a failed SCM query as absence' {
        InModuleScope Inventory {
            Mock Get-AppLocalKernelNativeRecord { throw 'fixture SCM access denied' }
            { Get-AppLocalKernelInventory } | Should -Throw '*fixture SCM access denied*'
        }
    }
}
