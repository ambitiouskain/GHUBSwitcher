BeforeAll {
    foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator','InstallerAudit','Bootstrap')) {
        Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking
    }
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
    function Get-FixtureInventory {param($Context)
        $dirs=Get-ActiveDirectories $Context
        $version=[IO.File]::ReadAllText((Join-Path $dirs.Program 'version.txt'))
        $processes=@()
        if(Test-Path -LiteralPath (Join-Path $Context.Root 'launched')){$processes=@([pscustomobject]@{Name='lghub_agent.exe';OwnerSid=$Context.OwnerSid;Path=(Join-Path $dirs.Program 'lghub_agent.exe')})}
        [pscustomobject]@{ProductVersion=$version;CapturedAt='fixture';Directories=$dirs;Services=@();Startup=@();Tasks=@();Devices=@();AllDevices=@();Processes=$processes;KernelServices=@();ClassFilters=@()}
    }
    function Get-FixtureHashes {param($Root)
        @((Get-TreeFiles $Root | Where-Object {-not $_.IsDirectory} | Sort-Object Relative | ForEach-Object {$_.Relative+'='+$_.Sha256})) -join "`n"
    }
}
Describe 'Menu operations use complete file capture and transaction flows' {
    BeforeEach {
        $script:menuContext=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $ctx=$script:menuContext
        $park=Join-Path $ctx.Root 'Environments/legacy'
        if(-not ([IO.Path]::GetFullPath($park)).StartsWith(([IO.Path]::GetFullPath($TestDrive))+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
        Remove-Item -LiteralPath $park -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/Program/version.txt'),'2026.before')
        $config=@{Applications=@('desktop','game');Profiles=@(@{Name='自定义';Dpi=@(400,800,1600);Assignments=@{Button4='macro1'};Macros=@{macro1=@(10,20,30)};Lua='function OnEvent(event,arg) OutputLogMessage("saved") end'});PersistentProfile='自定义'} | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/settings.json'),$config)
        [IO.File]::WriteAllBytes((Join-Path $ctx.Root 'active/RoamingData/macro.bin'),[byte[]]@(0,128,255,7))
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') @{OwnerSid=$ctx.OwnerSid;RegistryRoots=@()}
        Write-SwitchState $ctx (New-SwitchState $ctx modern fixture)
        foreach($module in @('Bootstrap','Coordinator','Lifecycle')) {
            Mock Assert-Administrator -ModuleName $module {}
            Mock Get-GHUBInventory -ModuleName $module {param($Context) Get-FixtureInventory $Context}
        }
        foreach($module in @('Bootstrap','Coordinator')) {
            Mock Stop-GHUBEnvironment -ModuleName $module {param($Context) $p=Join-Path $Context.Root 'launched';if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p};New-OperationResult}
            Mock Start-GHUBUserSession -ModuleName $module {param($Context,$Manifest) [IO.File]::WriteAllText((Join-Path $Context.Root 'launched'),$Manifest.Slot);New-OperationResult}
            Mock Apply-EnvironmentServices -ModuleName $module {New-OperationResult}
            Mock Get-BootId -ModuleName $module {$script:menuBoot}
            Mock Invoke-DriverPlan -ModuleName $module {New-OperationResult}
        }
        $script:menuBoot='fixture'
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle {@{Roots=@();Values=@()}}
        Mock Get-GHUBRegistryValues -ModuleName Coordinator {@{Roots=@();Values=@()}}
        Mock Get-OwnedRegistryValues -ModuleName Bootstrap {@{Roots=@();Values=@()}}
        Mock Export-ManagedDrivers -ModuleName Bootstrap {@()}
        Mock Install-StartupControl -ModuleName Bootstrap {New-OperationResult}
        Mock Assert-GHUBDriverPlanSource -ModuleName Coordinator {}
        Mock Resume-GHUBVirtualChildren -ModuleName Coordinator {New-OperationResult}
        Mock Test-DriverState -ModuleName Coordinator {@{Checks=@()}}
        Mock Get-AuthenticodeSignature -ModuleName Bootstrap {@{Status='Valid';SignerCertificate=@{Subject='O=Logitech Inc'}}}
        Mock Get-Item -ModuleName Bootstrap {@{FullName='C:\fixture\legacy.exe';VersionInfo=@{FileVersion='2021.3.5164'}}} -ParameterFilter {$LiteralPath -eq 'C:\fixture\legacy.exe'}
        Mock Get-InstallerSnapshot -ModuleName Bootstrap {@{Items=@();Errors=@();Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}}
        Mock Read-Host -ModuleName Bootstrap {
            param($Prompt)
            if($Prompt -like '*UPDATED-AUTO-OFF*'){
                [IO.File]::WriteAllText((Join-Path $script:menuContext.Root 'active/Program/version.txt'),'2026.after')
                return 'UPDATED-AUTO-OFF'
            }
            if($Prompt -like '*UNINSTALLED*'){return 'UNINSTALLED'}
            if($Prompt -like '*AUTO-OFF*'){return 'AUTO-OFF'}
            if($Prompt -like '*INSTALL*'){return 'INSTALL'}
            throw "Unexpected prompt: $Prompt"
        }
        Mock Start-Process -ModuleName Bootstrap {
            param($FilePath)
            if($FilePath -ne 'C:\fixture\legacy.exe'){throw 'Unexpected executable'}
            $process=[pscustomobject]@{Root=$script:menuContext.Root}
            $process|Add-Member ScriptMethod WaitForExit {
                [IO.File]::WriteAllText((Join-Path $this.Root 'active/Program/version.txt'),'2021.3.5164')
                [IO.File]::WriteAllText((Join-Path $this.Root 'active/LocalData/settings.json'),'{"profiles":["legacy"]}')
            }
            $process|Add-Member ScriptMethod Dispose {}
            $process
        }
    }
    It 'prepares modern, captures legacy, returns modern, and preserves later configuration through repeated switches' {
        (Initialize-GHUBSwitcher $ctx 'C:\fixture\legacy.exe' -AutomaticUpdatesObservedOff).Status | Should -Be Ok
        $original=Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')
        $modern=Read-EnvironmentManifest $ctx modern
        (Test-EnvironmentBackup $ctx @{Path=$modern.BackupPath}) | Should -BeTrue
        $capture=Capture-LegacyEnvironment $ctx 'C:\fixture\legacy.exe'
        $capture.Status | Should -Be Ok -Because ($capture|ConvertTo-Json -Depth 10)
        (Read-SwitchState $ctx).Active | Should -Be modern
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $original
        (Read-EnvironmentManifest $ctx legacy).ProductVersion | Should -Be '2021.3.5164'
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/new-macro.lua'),'function OnEvent(event,arg) OutputLogMessage("latest") end')
        $latest=Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')
        foreach($i in 1..2){
            (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be Ok
            Get-FixtureHashes (Join-Path $ctx.Root 'Environments/modern/LocalData') | Should -BeExactly $latest
            (Invoke-GHUBSwitch $ctx modern).Status | Should -Be Ok
            Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $latest
        }
    }
    It 'registers changed modern files after maintenance and retains both configurations after restart and switching' {
        (Initialize-GHUBSwitcher $ctx 'C:\fixture\legacy.exe' -AutomaticUpdatesObservedOff).Status | Should -Be Ok
        $capture=Capture-LegacyEnvironment $ctx 'C:\fixture\legacy.exe'
        $capture.Status | Should -Be Ok -Because ($capture|ConvertTo-Json -Depth 10)
        $before=Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')
        $legacy=Get-FixtureHashes (Join-Path $ctx.Root 'Environments/legacy/LocalData')
        (Maintain-ModernEnvironment $ctx).Status | Should -Be PendingReboot
        (Read-EnvironmentManifest $ctx modern).ProductVersion | Should -Be '2026.after'
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $before
        $script:menuBoot='after-restart'
        (Resume-GHUBTransaction $ctx).Status | Should -Be Ok
        (Read-SwitchState $ctx).Health | Should -Be TechnicalPassed
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be Ok
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $legacy
        (Invoke-GHUBSwitch $ctx modern).Status | Should -Be Ok
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/Program/version.txt')) | Should -Be '2026.after'
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $before
    }
    It 'recovers the stopped pre-update file snapshot while preserving failed updater output in rescue' {
        (Initialize-GHUBSwitcher $ctx 'C:\fixture\legacy.exe' -AutomaticUpdatesObservedOff).Status | Should -Be Ok
        $before=Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')
        Mock Confirm-InstallerChanges -ModuleName Bootstrap {throw 'fixture unclassified vendor change'}
        (Maintain-ModernEnvironment $ctx).Status | Should -Be RecoveryRequired
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'active/LocalData/failed-update.lua'),'preserve failed output')
        $id=(Read-SwitchState $ctx).TransactionId
        (Restore-ModernBackup $ctx).Status | Should -Be Ok
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/Program/version.txt')) | Should -Be '2026.before'
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData') | Should -BeExactly $before
        Get-Content -LiteralPath (Join-Path $ctx.Root "Rescue/$id/LocalData/failed-update.lua") | Should -Be 'preserve failed output'
    }
    It 'updates and switches both configurations in the same boot when driver verification is disabled' {
        $registration=Read-AtomicJson (Join-Path $ctx.Root 'registration.json')
        $registration|Add-Member ValidationMode InstallationAndConfiguration
        Write-AtomicJson (Join-Path $ctx.Root 'registration.json') $registration
        (Initialize-GHUBSwitcher $ctx 'C:\fixture\legacy.exe' -AutomaticUpdatesObservedOff).Status|Should -Be Ok
        (Capture-LegacyEnvironment $ctx 'C:\fixture\legacy.exe').Status|Should -Be Ok
        $before=Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')
        $legacy=Get-FixtureHashes (Join-Path $ctx.Root 'Environments/legacy/LocalData')
        (Maintain-ModernEnvironment $ctx).Status|Should -Be Ok
        (Read-SwitchState $ctx).Health|Should -Be InstallationAndConfigurationPassed
        (Invoke-GHUBSwitch $ctx legacy).Status|Should -Be Ok
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')|Should -BeExactly $legacy
        (Invoke-GHUBSwitch $ctx modern).Status|Should -Be Ok
        [IO.File]::ReadAllText((Join-Path $ctx.Root 'active/Program/version.txt'))|Should -Be '2026.after'
        Get-FixtureHashes (Join-Path $ctx.Root 'active/LocalData')|Should -BeExactly $before
    }
}
