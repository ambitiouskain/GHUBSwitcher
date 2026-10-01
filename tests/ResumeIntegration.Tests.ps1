BeforeAll {
    foreach($name in @('Core','Inventory','Storage','Drivers','Lifecycle','Coordinator')){Import-Module "$PSScriptRoot/../src/Modules/$name.psm1" -Force -DisableNameChecking}
    Import-Module "$PSScriptRoot/TestSupport.psm1" -Force -DisableNameChecking
}
Describe 'Boot through owner login with real ticket and health gates' {
    BeforeEach {
        $script:ctx=New-TestContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state=Read-SwitchState $ctx;$state.TransactionId=$null;Write-SwitchState $ctx $state
        foreach($slot in @('modern','legacy')){
            $inventory=[pscustomobject]@{ProductVersion=$slot;CapturedAt='fixture';Directories=(Get-ActiveDirectories $ctx);Services=@();Startup=@();Tasks=@();Devices=@();KernelServices=@();ClassFilters=@()}
            $manifest=New-EnvironmentManifest $ctx $slot $inventory;$manifest.Qualification='Prepared'
            $manifest.UpdatePolicy=@{Verified=$true;ProductVersion=$slot;Method='ObservedUI';Evidence=@('fixture')}
            Write-AtomicJson (Join-Path $ctx.Root "Manifests/$slot.json") $manifest
        }
        foreach($module in @('Coordinator','Lifecycle','Drivers')){Mock Assert-Administrator -ModuleName $module {}}
        Mock Get-BootId -ModuleName Coordinator {'boot-a'}
        Mock Get-GHUBInventory -ModuleName Coordinator {
            param($Context)
            $version=Get-Content -LiteralPath (Join-Path $Context.Root 'active/Program/slot.txt')
            $processes=@();if(Test-Path (Join-Path $Context.Root 'launched')){$processes=@(@{Name='lghub_agent.exe';OwnerSid=$Context.OwnerSid;Path=(Join-Path $Context.Root 'active/Program/lghub_agent.exe')})}
            [pscustomobject]@{ProductVersion=$version;Processes=$processes;Devices=@();AllDevices=@();Services=@();KernelServices=@();Startup=@();Tasks=@();CapturedAt='fixture';Directories=(Get-ActiveDirectories $Context);ClassFilters=@()}
        }
        Mock Stop-GHUBEnvironment -ModuleName Coordinator {param($Context) if(Test-Path (Join-Path $Context.Root 'launched')){Remove-Item -LiteralPath (Join-Path $Context.Root 'launched')};New-OperationResult}
        Mock Get-GHUBInventory -ModuleName Lifecycle {
            param($Context)
            $processes=@();if(Test-Path (Join-Path $Context.Root 'launched')){$processes=@(@{Name='lghub_agent.exe'})}
            [pscustomobject]@{Processes=$processes}
        }
        Mock Get-GHUBRegistryValues -ModuleName Lifecycle { [pscustomobject]@{Roots=@();Values=@()} }
        Mock Get-NativeDevices -ModuleName Drivers {@()}
        Mock Get-KernelInventory -ModuleName Drivers {@()}
        Mock Get-ClassFilterInventory -ModuleName Drivers {@()}
        Mock Get-CimInstance -ModuleName Lifecycle {if(Test-Path (Join-Path $script:ctx.Root 'online')){(New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]123})}}
        Mock Invoke-CimMethod -ModuleName Lifecycle {@{Sid=$script:ctx.OwnerSid}}
        Mock Start-ScheduledTask -ModuleName Lifecycle {
            $ticket=Read-AtomicJson (Join-Path $script:ctx.Root 'Status/launch.json')
            $status=Read-AtomicJson (Join-Path $script:ctx.Root 'Status/status.json')
            if(-not (Test-LaunchTicket $ticket $script:ctx.OwnerSid) -or $ticket.Slot -ne $status.Target){throw ('Invalid user launch authorization: '+(@{Ticket=$ticket;Status=$status;Owner=$script:ctx.OwnerSid}|ConvertTo-Json -Compress))}
            [IO.File]::WriteAllText((Join-Path $script:ctx.Root 'launched'),$ticket.Slot)
        }
    }
    It 'waits with no enabled ticket before login and verifies the target after login' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {New-OperationResult PendingReboot RebootRequired 'restart'}
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be PendingReboot
        Mock Get-BootId -ModuleName Coordinator {'boot-b'}
        (Resume-GHUBTransaction $ctx).Status | Should -Be AwaitingLogon
        (Read-AtomicJson (Join-Path $ctx.Root 'Status/launch.json')).Enabled | Should -BeFalse
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'online'),'owner')
        $result=Resume-GHUBTransaction $ctx
        $result.Status | Should -Be Ok -Because ($result|ConvertTo-Json -Compress -Depth 12)
        (Read-SwitchState $ctx).Active | Should -Be legacy
        (Read-SwitchState $ctx).Health | Should -Be TechnicalPassed
        Get-Content (Join-Path $ctx.Root 'launched') | Should -Be legacy
    }
    It 'finishes boot when the owner is already logged in' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {New-OperationResult PendingReboot RebootRequired 'restart'}
        $null=Invoke-GHUBSwitch $ctx legacy
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'online'),'owner')
        Mock Get-BootId -ModuleName Coordinator {'boot-b'}
        $result=Resume-GHUBTransaction $ctx
        $result.Status | Should -Be Ok -Because ($result|ConvertTo-Json -Compress -Depth 12)
        (Read-SwitchState $ctx).Phase | Should -Be Idle
        Get-Content (Join-Path $ctx.Root 'launched') | Should -Be legacy
    }
    It 'retains the original failure when rollback also waits for reboot and login' {
        Mock Invoke-DriverPlan -ModuleName Coordinator {
            param($Context,$Plan)
            $state=Read-SwitchState $Context
            if($state.Phase -eq 'Binding'){
                Add-JournalEntry $Context $state.TransactionId Intent driver-fault $null $null
                throw 'original bind failure'
            }
            New-OperationResult PendingReboot RebootRequired 'rollback restart'
        }
        (Invoke-GHUBSwitch $ctx legacy).Status | Should -Be PendingReboot
        Mock Get-BootId -ModuleName Coordinator {'boot-b'}
        (Resume-GHUBTransaction $ctx).Status | Should -Be AwaitingLogon
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'online'),'owner')
        $result=Resume-GHUBTransaction $ctx
        $result.Status | Should -Be Blocked -Because ($result|ConvertTo-Json -Compress -Depth 12)
        $result.Code | Should -Be SwitchFailedRecovered
        $result.Evidence.RequestedTarget | Should -Be legacy
        $result.Evidence.RestoredSlot | Should -Be modern
        (Read-SwitchState $ctx).LastError | Should -Be 'original bind failure'
        (Read-SwitchState $ctx).Health | Should -Be TechnicalPassed
    }

}
