BeforeAll {
    Import-Module "$PSScriptRoot/../src/Modules/InstallerAudit.psm1" -Force -DisableNameChecking
}
Describe 'Installer source task audit view' {
    BeforeEach {
        InModuleScope InstallerAudit {
            $script:sourceTaskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><Enabled>true</Enabled></Settings><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command><Arguments>--background</Arguments></Exec></Actions></Task>'
            $script:disabledTaskXml=$script:sourceTaskXml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')
            $script:taskAuditSource=[pscustomobject]@{Services=@(@{Name='GHubService';Native=@{StartType=2}});Tasks=@([pscustomobject]@{Name='GHubTask';Path='\';Xml=$script:sourceTaskXml})}
            $script:currentAuditTasks=@([pscustomobject]@{Name='GHubTask';Path='\';Xml=$script:disabledTaskXml})
        }
    }
    It 'accepts only the known disabled state without modifying the recovery manifest or native services' {
        InModuleScope InstallerAudit {
            $audit=Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks
            $audit.Tasks[0].Xml | Should -BeExactly $script:disabledTaskXml
            $script:taskAuditSource.Tasks[0].Xml | Should -BeExactly $script:sourceTaskXml
            $audit.Services[0].Native.StartType | Should -Be 2
            $record=@{Key='\GHubTask';Hash=(Get-TextHash $script:disabledTaskXml)}
            Test-InstallerTaskOwnership $record $audit.Tasks | Should -BeTrue
            Test-InstallerTaskOwnership $record $script:taskAuditSource.Tasks | Should -BeFalse
        }
    }
    It 'rejects unrelated XML edits even when the task remains an owned Exec and is disabled' {
        InModuleScope InstallerAudit {
            foreach($xml in @($script:disabledTaskXml.Replace('--background','--other'),$script:disabledTaskXml.Replace('IgnoreNew','Parallel'),$script:disabledTaskXml.Replace('<Settings>','<Triggers /><Settings>'))){
                $script:currentAuditTasks[0].Xml=$xml
                {Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks} | Should -Throw '*UnclassifiedInstallerChange*'
            }
        }
    }
    It 'rejects task re-enablement external commands and non-Exec actions' {
        InModuleScope InstallerAudit {
            $script:taskAuditSource.Tasks[0].Xml=$script:disabledTaskXml
            $script:currentAuditTasks[0].Xml=$script:sourceTaskXml
            {Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks} | Should -Throw '*UnclassifiedInstallerChange*'
            foreach($xml in @($script:disabledTaskXml.Replace('C:\Program Files\LGHUB\lghub.exe','C:\Other.exe'),$script:disabledTaskXml.Replace('</Actions>','<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler></Actions>'))){
                $script:currentAuditTasks[0].Xml=$xml
                {Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks} | Should -Throw '*UnclassifiedInstallerChange*'
            }
        }
    }
    It 'accepts explicit disabling when Enabled originally used its default value' {
        InModuleScope InstallerAudit {
            $script:taskAuditSource.Tasks[0].Xml=$script:sourceTaskXml.Replace('<Enabled>true</Enabled>','')
            (Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks).Tasks[0].Xml | Should -BeExactly $script:disabledTaskXml
            $script:taskAuditSource.Tasks[0].Xml=$script:sourceTaskXml.Replace('<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><Enabled>true</Enabled></Settings>','')
            $script:currentAuditTasks[0].Xml=$script:disabledTaskXml.Replace('<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>','')
            (Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks).Tasks[0].Xml | Should -BeExactly $script:currentAuditTasks[0].Xml
        }
    }
    It 'preserves unchanged known tasks and never imports a new task identity into source ownership' {
        InModuleScope InstallerAudit {
            $script:currentAuditTasks[0].Xml=$script:sourceTaskXml
            $script:currentAuditTasks+=@([pscustomobject]@{Name='ForeignTask';Path='\';Xml=$script:sourceTaskXml})
            $audit=Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks
            $audit.Tasks.Count | Should -Be 1
            $audit.Tasks[0].Name | Should -Be GHubTask
            $audit.Tasks[0].Xml | Should -BeExactly $script:sourceTaskXml
        }
    }
    It 'rejects duplicate task identities instead of choosing an arbitrary current XML' {
        InModuleScope InstallerAudit {
            $script:currentAuditTasks+=@([pscustomobject]@{Name='GHubTask';Path='\';Xml=$script:sourceTaskXml})
            {Get-InstallerAuditSource $script:taskAuditSource $script:currentAuditTasks} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
}
Describe 'Installer registry snapshot streaming' {
    BeforeEach {
        InModuleScope InstallerAudit {
            function script:New-AuditFixtureKey {param([string]$Name,[hashtable]$Values=@{})
                $key=[pscustomobject]@{Name=$Name;Values=$Values;Disposed=$false;ReadFailure=$false}
                $key|Add-Member ScriptMethod GetValueNames { @($this.Values.Keys) }
                $key|Add-Member ScriptMethod GetValueKind {param($Name) [Microsoft.Win32.RegistryValueKind]::String}
                $key|Add-Member ScriptMethod GetValue {
                    param($Name,$Default,$Options)
                    if($this.Disposed){throw 'fixture key was already disposed'}
                    if($this.ReadFailure){throw 'fixture value denied'}
                    $this.Values[$Name]
                }
                $key|Add-Member ScriptMethod Dispose { $this.Disposed=$true }
                $key
            }
            $script:auditContext=@{Root='C:\fixture';OwnerSid='S-1-5-21-1-2-3-1001'}
            $script:auditRoots=@{}
            foreach($path in @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB','Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Logitech\LGHUB','Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE\Logitech\LGHUB')){
                $script:auditRoots[$path]=New-AuditFixtureKey ($path.Replace('Registry::',''))
            }
            $script:auditProductRoot='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB'
            $script:auditUninstallParent='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $script:auditUninstallEntries=@()
            $script:auditChildren=@((New-AuditFixtureKey 'HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB\FixtureA' @{value='alpha'}),(New-AuditFixtureKey 'HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB\FixtureB' @{value='beta'}))
            Mock Assert-Administrator {}
            Mock Get-Item {param($LiteralPath) $script:auditRoots[$LiteralPath]}
            Mock Get-ChildItem {
                param($LiteralPath,[switch]$Recurse)
                if($LiteralPath -in @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE','Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet','Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\SOFTWARE')){throw 'broad registry enumeration forbidden'}
                if($LiteralPath -eq $script:auditUninstallParent){if($Recurse){throw 'uninstall parent must only enumerate one level'};$script:auditUninstallEntries}
                elseif($LiteralPath -eq $script:auditProductRoot){$script:auditChildren}
            }
            Mock Get-CimInstance {}
            Mock Get-ClassFilterInventory {}
            Mock Get-ScheduledTask {}
            Mock Test-Path {param([string[]]$LiteralPath) $path=$LiteralPath[0];$script:auditRoots.ContainsKey($path) -or ($path -eq $script:auditUninstallParent -and $script:auditUninstallEntries.Count -gt 0)}
        }
    }
    It 'captures and disposes each key before requesting the next key' {
        InModuleScope InstallerAudit {
            Mock Get-ChildItem {
                param($LiteralPath)
                if($LiteralPath -eq $script:auditProductRoot){
                    if(-not $script:auditRoots[$LiteralPath].Disposed){throw 'root was buffered instead of captured'}
                    $script:auditChildren[0]
                    if(-not $script:auditChildren[0].Disposed){throw 'child was buffered instead of captured'}
                    $script:auditChildren[1]
                }
            }
            $snapshot=Get-InstallerSnapshot $script:auditContext
            $snapshot.Items.Count | Should -Be 7
            $snapshot.Errors.Count | Should -Be 0
            @($snapshot.Items|Where-Object {$_.Key -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB\FixtureA|value'}).Count | Should -Be 1
            @($script:auditRoots.Values|Where-Object {-not $_.Disposed}).Count | Should -Be 0
            @($script:auditChildren|Where-Object {-not $_.Disposed}).Count | Should -Be 0
        }
    }
    It 'retains value read failures and still disposes their keys' {
        InModuleScope InstallerAudit {
            $script:auditChildren[0].ReadFailure=$true
            $snapshot=Get-InstallerSnapshot $script:auditContext
            ($snapshot.Errors -join ' ') | Should -Match 'fixture value denied'
            $script:auditChildren[0].Disposed | Should -BeTrue
            @($snapshot.Items|Where-Object {$_.Key -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB\FixtureB|value'}).Count | Should -Be 1
        }
    }
    It 'retains enumeration errors instead of reporting complete readable coverage' {
        InModuleScope InstallerAudit {
            Mock Get-ChildItem {param($LiteralPath) Write-Error 'fixture enumeration denied' -Category PermissionDenied -TargetObject $LiteralPath}
            $snapshot=Get-InstallerSnapshot $script:auditContext
            ($snapshot.Errors -join ' ') | Should -Match 'fixture enumeration denied'
            @($script:auditRoots.Values|Where-Object {-not $_.Disposed}).Count | Should -Be 0
        }
    }
    It 'declares bounded coverage and finds a new G HUB uninstall GUID without recursing other products' {
        InModuleScope InstallerAudit {
            $newPath=$script:auditUninstallParent+'\{NEW-GHUB}'
            $script:auditUninstallEntries=@((New-AuditFixtureKey ($newPath.Replace('Registry::','')) @{DisplayName='Logitech G HUB'}),(New-AuditFixtureKey ($script:auditUninstallParent.Replace('Registry::','')+'\Other') @{DisplayName='Other Product'}))
            $script:auditRoots[$newPath]=New-AuditFixtureKey ($newPath.Replace('Registry::','')) @{DisplayName='Logitech G HUB';DisplayVersion='2021.3'}
            $snapshot=Get-InstallerSnapshot $script:auditContext
            $snapshot.ScopeVersion | Should -Be 1
            $snapshot.RegistryRoots | Should -Contain $newPath
            $snapshot.NotAudited.Count | Should -BeGreaterThan 0
            @($snapshot.Items|Where-Object {$_.Path -eq ($script:auditUninstallParent+'\Other')}).Count | Should -Be 0
            @($snapshot.Items|Where-Object {$_.Key -eq ($newPath+'|DisplayVersion')}).Count | Should -Be 1
        }
    }
    It 'captures startup values individually and global kernel configuration without runtime state' {
        InModuleScope InstallerAudit {
            $run='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $script:auditRoots[$run]=New-AuditFixtureKey ($run.Replace('Registry::','')) @{Other='C:\other.exe'}
            Mock Get-CimInstance {param($ClassName) if($ClassName -eq 'Win32_SystemDriver'){[pscustomobject]@{Name='new_driver';PathName='C:\Windows\System32\drivers\new.sys';StartMode='Manual';ServiceType='Kernel Driver';State='Stopped'}}}
            $snapshot=Get-InstallerSnapshot $script:auditContext
            $startup=@($snapshot.Items|Where-Object Kind -EQ Startup)
            $startup.Count | Should -Be 1
            $startup[0].Name | Should -Be Other
            $startup[0].Command | Should -Be 'C:\other.exe'
            @($snapshot.Items|Where-Object Kind -EQ KernelService).Count | Should -Be 1
            @($snapshot.Items|Where-Object {$_.Kind -eq 'Registry' -and $_.Path -eq $run}).Count | Should -Be 0
        }
    }
    It 'retains raw task XML and a stable structure alongside the verified raw hash' {
        InModuleScope InstallerAudit {
            $script:snapshotTaskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><TimeTrigger><StartBoundary>2026-09-26T12:00:00Z</StartBoundary></TimeTrigger></Triggers><Actions><Exec><Command>C:\Windows\System32\fixture.exe</Command></Exec></Actions></Task>'
            Mock Get-ScheduledTask { [pscustomobject]@{TaskName='Fixture';TaskPath='\Microsoft\Windows\Fixture\'} }
            Mock Export-ScheduledTask { $script:snapshotTaskXml }
            Mock Get-TaskExecutables { 'C:\Windows\System32\fixture.exe' }
            $snapshot=Get-InstallerSnapshot $script:auditContext
            $task=@($snapshot.Items|Where-Object Kind -EQ Task)[0]
            $task.Xml | Should -BeExactly $script:snapshotTaskXml
            $task.Hash | Should -BeExactly (Get-TextHash $task.Xml)
            $task.StableXml | Should -Not -Match '2026-09-26T12:00:00Z'
            $task.StableHash | Should -BeExactly (Get-TextHash $task.StableXml)
        }
    }
    It 'does not enumerate or hash the excluded driver runtime log subtree' {
        InModuleScope InstallerAudit {
            $script:auditDriverRoot=Join-Path $env:WINDIR 'System32/drivers'
            $script:auditDriverData=Join-Path $script:auditDriverRoot 'DriverData'
            $script:auditLogRoot=Join-Path $script:auditDriverData 'LogFiles'
            $script:auditBinary=Join-Path $script:auditDriverRoot 'fixture.sys'
            Mock Test-Path {param([string[]]$LiteralPath) $LiteralPath[0] -eq $script:auditDriverRoot}
            Mock Get-ChildItem {
                param($LiteralPath,[switch]$Recurse)
                if($LiteralPath -eq $script:auditDriverRoot){
                    [pscustomobject]@{FullName=$script:auditBinary;PSIsContainer=$false}
                    if($Recurse){[pscustomobject]@{FullName=(Join-Path $script:auditLogRoot 'WMI\busy.etl');PSIsContainer=$false}}
                    else{[pscustomobject]@{FullName=$script:auditDriverData;PSIsContainer=$true}}
                }elseif($LiteralPath -eq $script:auditDriverData){
                    [pscustomobject]@{FullName=$script:auditLogRoot;PSIsContainer=$true}
                }elseif($LiteralPath.StartsWith($script:auditLogRoot,[StringComparison]::OrdinalIgnoreCase)){
                    Write-Error 'excluded runtime log subtree cannot be enumerated'
                }
            }
            Mock Get-FileHash {
                param($LiteralPath)
                if($LiteralPath -eq $script:auditBinary){[pscustomobject]@{Hash=('a'*64)}}else{throw 'runtime log is locked'}
            }
            $snapshot=Get-InstallerSnapshot $script:auditContext
            $snapshot.Errors.Count | Should -Be 0
            $files=@($snapshot.Items|Where-Object Kind -EQ SharedFile)
            $files.Count | Should -Be 1
            $files[0].Path | Should -Be $script:auditBinary
            ($snapshot.NotAudited -join ' ') | Should -Match 'DriverData.*LogFiles'
            Should -Invoke Get-ChildItem -Times 0 -ParameterFilter {$LiteralPath -eq $script:auditLogRoot}
            Should -Invoke Get-FileHash -Times 0 -ParameterFilter {$LiteralPath -ne $script:auditBinary}
        }
    }
    It 'still records driver binary read errors outside the excluded runtime logs' {
        InModuleScope InstallerAudit {
            $script:auditDriverRoot=Join-Path $env:WINDIR 'System32/drivers'
            $script:auditBinary=Join-Path $script:auditDriverRoot 'fixture.sys'
            Mock Test-Path {param([string[]]$LiteralPath) $LiteralPath[0] -eq $script:auditDriverRoot}
            Mock Get-ChildItem {param($LiteralPath) if($LiteralPath -eq $script:auditDriverRoot){[pscustomobject]@{FullName=$script:auditBinary;PSIsContainer=$false}}}
            Mock Get-FileHash {throw 'fixture driver binary access denied'}
            $snapshot=Get-InstallerSnapshot $script:auditContext
            ($snapshot.Errors -join ' ') | Should -Match 'fixture driver binary access denied'
            @($snapshot.Items|Where-Object Kind -EQ SharedFile).Count | Should -Be 0
        }
    }
    It 'retains enumeration failures in a similarly named directory outside the excluded logs' {
        InModuleScope InstallerAudit {
            $script:auditDriverRoot=Join-Path $env:WINDIR 'System32/drivers'
            $script:auditDriverData=Join-Path $script:auditDriverRoot 'DriverData'
            $script:auditSimilarLogRoot=Join-Path $script:auditDriverData 'LogFilesArchive'
            Mock Test-Path {param([string[]]$LiteralPath) $LiteralPath[0] -eq $script:auditDriverRoot}
            Mock Get-ChildItem {
                param($LiteralPath)
                if($LiteralPath -eq $script:auditDriverRoot){[pscustomobject]@{FullName=$script:auditDriverData;PSIsContainer=$true}}
                elseif($LiteralPath -eq $script:auditDriverData){[pscustomobject]@{FullName=$script:auditSimilarLogRoot;PSIsContainer=$true}}
                elseif($LiteralPath -eq $script:auditSimilarLogRoot){Write-Error 'fixture driver directory access denied'}
            }
            $snapshot=Get-InstallerSnapshot $script:auditContext
            ($snapshot.Errors -join ' ') | Should -Match 'fixture driver directory access denied'
            Should -Invoke Get-ChildItem -Times 1 -ParameterFilter {$LiteralPath -eq $script:auditSimilarLogRoot}
        }
    }
}
Describe 'Verified Windows task schedule differences' {
    BeforeEach {
        InModuleScope InstallerAudit {
            $script:timeXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><SecurityDescriptor>D:P(A;;FA;;;SY)</SecurityDescriptor></RegistrationInfo><Triggers><TimeTrigger><StartBoundary>2026-09-26T12:00:00Z</StartBoundary><Enabled>true</Enabled></TimeTrigger><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers><Principals><Principal id="System"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions Context="System"><Exec><Command>C:\Windows\System32\fixture.exe</Command><Arguments>--scheduled</Arguments></Exec></Actions></Task>'
            $script:timeBefore=@{Kind='Task';Key='\Microsoft\Windows\Fixture\Task';Path='C:\Windows\System32\fixture.exe';Xml=$script:timeXml;Hash=(Get-TextHash $script:timeXml)}
            $script:timeAfter=$script:timeBefore.Clone();$script:timeAfter.Xml=$script:timeXml.Replace('2026-09-26T12:00:00Z','2026-09-27T12:00:00Z');$script:timeAfter.Hash=Get-TextHash $script:timeAfter.Xml
        }
    }
    It 'accepts an exact start-time-only transition with verified XML on both sides' {
        InModuleScope InstallerAudit { Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeTrue }
    }
    It 'accepts a calendar start boundary while retaining all calendar recurrence rules' {
        InModuleScope InstallerAudit {
            foreach($record in @($script:timeBefore,$script:timeAfter)){
                $record.Xml=$record.Xml.Replace('TimeTrigger','CalendarTrigger').Replace('</CalendarTrigger>','<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>')
                $record.Hash=Get-TextHash $record.Xml
            }
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeTrue
            $script:timeAfter.Xml=$script:timeAfter.Xml.Replace('<DaysInterval>1','<DaysInterval>2');$script:timeAfter.Hash=Get-TextHash $script:timeAfter.Xml
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeFalse
        }
    }
    It 'does not label formatting-only changes as a verified schedule change' {
        InModuleScope InstallerAudit {
            $script:timeAfter.Xml=$script:timeBefore.Xml.Replace('<Triggers>',([string][char]10+'<Triggers>'))
            $script:timeAfter.Hash=Get-TextHash $script:timeAfter.Xml
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeFalse
        }
    }
    It 'rejects forged stable structures and XML entity declarations' {
        InModuleScope InstallerAudit {
            $script:timeAfter.StableHash='f'*64
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeFalse
            $script:timeAfter.Remove('StableHash')
            $script:timeAfter.Xml='<!DOCTYPE Task [<!ENTITY fixture "anything">]>'+$script:timeAfter.Xml
            $script:timeAfter.Hash=Get-TextHash $script:timeAfter.Xml
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeFalse
        }
    }
    It 'rejects <Change> even when a start time also changes' -TestCases @(
        @{Change='Action';Old='--scheduled';New='--other'},
        @{Change='Principal';Old='S-1-5-18';New='S-1-5-19'},
        @{Change='Security';Old='D:P(A;;FA;;;SY)';New='D:P(A;;FA;;;WD)'},
        @{Change='OtherTrigger';Old='<LogonTrigger><Enabled>true</Enabled>';New='<LogonTrigger><Enabled>false</Enabled>'},
        @{Change='Settings';Old='<Settings><Enabled>true</Enabled>';New='<Settings><Enabled>false</Enabled>'},
        @{Change='TriggerShape';Old='</TimeTrigger>';New='<EndBoundary>2027-01-01T00:00:00Z</EndBoundary></TimeTrigger>'},
        @{Change='InvalidTime';Old='2026-09-27T12:00:00Z';New='not-a-date'}
    ) {
        param($Change,$Old,$New)
        InModuleScope InstallerAudit -Parameters @{Old=$Old;New=$New} {
            param($Old,$New)
            $script:timeAfter.Xml=$script:timeAfter.Xml.Replace($Old,$New);$script:timeAfter.Hash=Get-TextHash $script:timeAfter.Xml
            Test-InstallerTaskScheduleTransition $script:timeBefore $script:timeAfter | Should -BeFalse
        }
    }
    It 'rejects missing XML forged hashes additions and a Windows-looking task outside the Windows namespace' {
        InModuleScope InstallerAudit {
            $after=$script:timeAfter.Clone();$after.Remove('Xml')
            Test-InstallerTaskScheduleTransition $script:timeBefore $after | Should -BeFalse
            $after=$script:timeAfter.Clone();$after.Hash='f'*64
            Test-InstallerTaskScheduleTransition $script:timeBefore $after | Should -BeFalse
            Test-InstallerTaskScheduleTransition $null $script:timeAfter | Should -BeFalse
            $before=$script:timeBefore.Clone();$after=$script:timeAfter.Clone();$before.Key='\FakeWindows\Task';$after.Key=$before.Key
            Test-InstallerTaskScheduleTransition $before $after | Should -BeFalse
        }
    }
    It 'reports the precise schedule classification without requiring G HUB ownership' {
        InModuleScope InstallerAudit {
            Mock Write-AtomicJson {param($Path,$Value) $script:scheduleReport=$Value}
            Mock Get-FileHash { @{Hash=('a'*64)} }
            $before=@{Items=@($script:timeBefore);Errors=@();Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}
            $after=$before.Clone();$after.Items=@($script:timeAfter)
            $manifest=@{ProductVersion='fixture'}
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $manifest $manifest fixture).Passed | Should -BeTrue
            $script:scheduleReport.Changes[0].Classification | Should -Be WindowsTaskScheduleTime
        }
    }
}
Describe 'Installer manual review evidence chain' {
    BeforeEach {
        InModuleScope InstallerAudit -Parameters @{TestRoot=$TestDrive} {
            param($TestRoot)
            $script:reviewContext=@{Root=(Join-Path $TestRoot ([guid]::NewGuid().ToString('N')));OwnerSid='fixture-owner'}
            $script:reviewTx='fixture-review'
            $script:reviewTask='\Microsoft\Windows\Fixture\Task'
            $script:reviewBefore=@{OwnerSid=$script:reviewContext.OwnerSid;Items=@(@{Kind='Task';Key=$script:reviewTask;Path='C:\Windows\System32\fixture.exe';Hash=('a'*64)});Errors=@();Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}
            $script:reviewAfter=$script:reviewBefore|ConvertTo-Json -Depth 20|ConvertFrom-Json;$script:reviewAfter.Items[0].Hash='b'*64
            $script:reviewSource=@{OwnerSid=$script:reviewContext.OwnerSid;ProductVersion='modern';Services=@();Tasks=@();KernelServices=@();Files=@()}
            $script:reviewTarget=@{OwnerSid=$script:reviewContext.OwnerSid;ProductVersion='2021.3';Slot='legacy';Services=@();Tasks=@();KernelServices=@();Files=@();Qualification='Unverified'}
            $script:reviewTargetPath=Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-target.json"
            Write-AtomicJson (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-before.json") $script:reviewBefore
            Write-AtomicJson (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-after.json") $script:reviewAfter
            Write-AtomicJson $script:reviewTargetPath $script:reviewTarget
            {Confirm-InstallerChanges $script:reviewContext $script:reviewBefore $script:reviewAfter $script:reviewSource $script:reviewTarget $script:reviewTx} | Should -Throw '*UnclassifiedInstallerChange*'
            $script:reviewReportPath=Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-report.json"
            $script:reviewOriginalHash=(Get-FileHash -LiteralPath $script:reviewReportPath).Hash
            $script:reviewChanges=@(@{Kind='Task';Key=$script:reviewTask;BeforeHash=('a'*64);AfterHash=('b'*64)})
        }
    }
    It 'preserves the failed report and verifies the complete independently marked manual chain' {
        InModuleScope InstallerAudit {
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges 'fixture-reviewer' 'Verified current Windows task evidence; historical XML was not captured.' -Source $script:reviewSource
            (Read-AtomicJson $review.Path).Bindings.source.Sha256 | Should -BeExactly ((Get-FileHash -LiteralPath (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-reviewed-source.json")).Hash.ToLowerInvariant())
            $evidence=Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path
            (Get-FileHash -LiteralPath $script:reviewReportPath).Hash | Should -BeExactly $script:reviewOriginalHash
            (Read-AtomicJson $script:reviewReportPath).Passed | Should -BeFalse
            $derived=Read-AtomicJson $evidence.Path
            $derived.Passed | Should -BeTrue
            $derived.AutomaticallyPassed | Should -BeFalse
            $derived.ValidationMode | Should -Be ManualReview
            $derived.Changes[0].Classification | Should -Be ManualAcceptedExternalChange
            $manifest=$script:reviewTarget|ConvertTo-Json -Depth 20|ConvertFrom-Json
            $manifest.Qualification='Prepared';$manifest|Add-Member InstallerEvidence $evidence
            Test-ReviewedInstallerEvidence $script:reviewContext $evidence $manifest | Should -BeTrue
        }
    }
    It 'rejects a review changed after the derived evidence was issued' {
        InModuleScope InstallerAudit {
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            $evidence=Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path
            $changed=Read-AtomicJson $review.Path;$changed.Reason='changed';Write-AtomicJson $review.Path $changed
            Test-ReviewedInstallerEvidence $script:reviewContext $evidence $script:reviewTarget | Should -BeFalse
        }
    }
    It 'rejects expanded source ownership supplied after the task review was created' {
        InModuleScope InstallerAudit {
            $script:reviewBefore.Items+=@(@{Kind='KernelService';Key='lghub_foreign';Path='C:\Windows\System32\drivers\foreign.sys';Hash=('c'*64)})
            Write-AtomicJson (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-before.json") $script:reviewBefore
            {Confirm-InstallerChanges $script:reviewContext $script:reviewBefore $script:reviewAfter $script:reviewSource $script:reviewTarget $script:reviewTx} | Should -Throw '*UnclassifiedInstallerChange*'
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            $expanded=$script:reviewSource|ConvertTo-Json -Depth 20|ConvertFrom-Json
            $expanded.KernelServices=@(@{Name='lghub_foreign';Path='C:\Windows\System32\drivers\foreign.sys'})
            {Confirm-ReviewedInstallerChanges $script:reviewContext $expanded $script:reviewTargetPath $script:reviewTx $review.Path} | Should -Throw '*InstallerReviewInvalid*'
        }
    }
    It 'rejects changes to any bound <Artifact> before deriving a report' -TestCases @(
        @{Artifact='before'},@{Artifact='after'},@{Artifact='report'},@{Artifact='target'},@{Artifact='source'}
    ) {
        param($Artifact)
        InModuleScope InstallerAudit -Parameters @{Artifact=$Artifact} {
            param($Artifact)
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            $path=if($Artifact -eq 'target'){$script:reviewTargetPath}elseif($Artifact -eq 'source'){Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-reviewed-source.json"}else{Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-$Artifact.json"}
            $changed=Read-AtomicJson $path;$changed|Add-Member Unexpected changed;Write-AtomicJson $path $changed
            {Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path} | Should -Throw '*InstallerReviewInvalid*'
        }
    }
    It 'rejects wrong change hashes duplicate approvals and attempts to review drivers' {
        InModuleScope InstallerAudit {
            foreach($changes in @(
                @(@{Kind='Task';Key=$script:reviewTask;BeforeHash=('c'*64);AfterHash=('b'*64)}),
                @($script:reviewChanges[0],$script:reviewChanges[0]),
                @(@{Kind='KernelService';Key='LGHUBTemperatureService';BeforeHash=('a'*64);AfterHash=('b'*64)})
            )){
                {New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $changes reviewer reason -Source $script:reviewSource} | Should -Throw '*InstallerReviewInvalid*'
            }
        }
    }
    It 'blocks every other unknown change and unreadable coverage even with an exact task review' {
        InModuleScope InstallerAudit {
            foreach($failure in @('KernelService','ReadError')){
                if($failure -eq 'KernelService'){$script:reviewAfter.Items+=@([pscustomobject]@{Kind='KernelService';Key='unknown-driver';Path='C:\unknown.sys';Hash=('c'*64)})}else{$script:reviewAfter.Errors=@('fixture access denied')}
                Write-AtomicJson (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-after.json") $script:reviewAfter
                {Confirm-InstallerChanges $script:reviewContext $script:reviewBefore $script:reviewAfter $script:reviewSource $script:reviewTarget $script:reviewTx} | Should -Throw '*UnclassifiedInstallerChange*'
                $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
                {Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path} | Should -Throw '*UnclassifiedInstallerChange*'
                Remove-Item -LiteralPath $review.Path
                Remove-Item -LiteralPath (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-reviewed-source.json")
                $script:reviewAfter.Items=@($script:reviewAfter.Items|Where-Object Kind -EQ Task)
            }
        }
    }
    It 'rejects a different transaction target or active manifest and cannot overwrite a prior review' {
        InModuleScope InstallerAudit {
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            {New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource} | Should -Throw '*InstallerReviewInvalid*'
            {Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath 'another-transaction' $review.Path} | Should -Throw '*InstallerReviewInvalid*'
            $evidence=Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path
            $script:reviewTarget.ProductVersion='other'
            Test-ReviewedInstallerEvidence $script:reviewContext $evidence $script:reviewTarget | Should -BeFalse
        }
    }
    It 'reclassifies newly captured kernel ownership automatically instead of manually approving it' {
        InModuleScope InstallerAudit {
            $script:reviewAfter.Items+=@([pscustomobject]@{Kind='KernelService';Key='lghub_captured';Path='C:\Windows\System32\drivers\captured.sys';Hash=('c'*64)})
            Write-AtomicJson (Join-Path $script:reviewContext.Root "Transactions/$script:reviewTx-installer-after.json") $script:reviewAfter
            {Confirm-InstallerChanges $script:reviewContext $script:reviewBefore $script:reviewAfter $script:reviewSource $script:reviewTarget $script:reviewTx} | Should -Throw '*UnclassifiedInstallerChange*'
            $script:reviewTarget.KernelServices=@(@{Name='lghub_captured';Path='C:\Windows\System32\drivers\captured.sys'})
            Write-AtomicJson $script:reviewTargetPath $script:reviewTarget
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            $evidence=Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path
            $kernel=@((Read-AtomicJson $evidence.Path).Changes|Where-Object Kind -EQ KernelService)[0]
            $kernel.Classified | Should -BeTrue
            $kernel.Classification | Should -Be CapturedGHubOwnership
        }
    }
    It 'detects a changed reviewed source or derived classification even with a rewritten envelope' {
        InModuleScope InstallerAudit {
            $review=New-InstallerManualReview $script:reviewContext $script:reviewTx $script:reviewTargetPath $script:reviewChanges reviewer reason -Source $script:reviewSource
            $evidence=Confirm-ReviewedInstallerChanges $script:reviewContext $script:reviewSource $script:reviewTargetPath $script:reviewTx $review.Path
            $report=Read-AtomicJson $evidence.Path
            $report.Changes[0].Classification='CapturedGHubOwnership';Write-AtomicJson $evidence.Path $report
            $evidence.Sha256=(Get-FileHash -LiteralPath $evidence.Path).Hash.ToLowerInvariant()
            Test-ReviewedInstallerEvidence $script:reviewContext $evidence $script:reviewTarget | Should -BeFalse
            $report.Changes[0].Classification='ManualAcceptedExternalChange';Write-AtomicJson $evidence.Path $report
            $evidence.Sha256=(Get-FileHash -LiteralPath $evidence.Path).Hash.ToLowerInvariant()
            $source=Read-AtomicJson $report.Source.Path;$source.ProductVersion='changed';Write-AtomicJson $report.Source.Path $source
            Test-ReviewedInstallerEvidence $script:reviewContext $evidence $script:reviewTarget | Should -BeFalse
        }
    }
}
Describe 'Installer difference report collection' {
    BeforeEach {
        InModuleScope InstallerAudit {
            $script:auditReport=@{Value=$null}
            Mock Write-AtomicJson {param($Path,$Value) $script:auditReport.Value=$Value}
            Mock Get-FileHash { [pscustomobject]@{Hash=('a'*64)} }
            Mock Test-GHUBRegistryPath {throw 'Unowned fixture path'}
            $script:boundedSnapshot=@{ScopeVersion=1;RegistryRoots=@('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Logitech\GHUB');ScopeSelectors=@('GHubDependenciesV1');NotAudited=@('Outside declared scope');Items=@();Errors=@();Coverage=@('Registry','Startup','Services','KernelServices','ClassFilters','SharedFiles','Tasks')}
            $script:emptyManifest=@{Services=@();KernelServices=@();Devices=@();Startup=@();ProductVersion='fixture'}
        }
    }
    It 'preserves every unknown difference in a large comparison' {
        InModuleScope InstallerAudit {
            $beforeItems=[Collections.Generic.List[object]]::new();$afterItems=[Collections.Generic.List[object]]::new()
            for($i=0;$i -lt 500;$i++){
                $beforeItems.Add([pscustomobject]@{Kind='SharedFile';Key=('changed-'+$i);Path=('C:\fixture\changed-'+$i);Hash='old'})
                $afterItems.Add([pscustomobject]@{Kind='SharedFile';Key=('changed-'+$i);Path=('C:\fixture\changed-'+$i);Hash='new'})
                $beforeItems.Add([pscustomobject]@{Kind='SharedFile';Key=('removed-'+$i);Path=('C:\fixture\removed-'+$i);Hash='old'})
                $afterItems.Add([pscustomobject]@{Kind='SharedFile';Key=('added-'+$i);Path=('C:\fixture\added-'+$i);Hash='new'})
            }
            $coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')
            $before=@{Items=$beforeItems.ToArray();Errors=@();Coverage=$coverage}
            $after=@{Items=$afterItems.ToArray();Errors=@();Coverage=$coverage}
            $manifest=@{Services=@();KernelServices=@();Devices=@();ProductVersion='fixture'}
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $manifest $manifest fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $script:auditReport.Value.Changes.Count | Should -Be 1500
            $script:auditReport.Value.Unknown.Count | Should -Be 1500
            $script:auditReport.Value.Passed | Should -BeFalse
        }
    }
    It 'still rejects pre-existing unreadable coverage on both sides' {
        InModuleScope InstallerAudit {
            $snapshot=@{Items=@();Errors=@('fixture access denied');Coverage=@('Registry','Services','ClassFilters','SharedFiles','Tasks')}
            $manifest=@{Services=@();KernelServices=@();Devices=@();ProductVersion='fixture'}
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $snapshot $snapshot $manifest $manifest fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $script:auditReport.Value.Unknown.Count | Should -Be 2
            $script:auditReport.Value.Passed | Should -BeFalse
        }
    }
    It 'requires exact startup path name and command on both sides of a replacement' {
        InModuleScope InstallerAudit {
            $run='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $command='"C:\Program Files\LGHUB\lghub.exe" --background'
            $target=$script:emptyManifest.Clone();$target.Startup=@(@{Path=$run;Name='G HUB';Value=$command})
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $after.Items=@(@{Kind='Startup';Key=$run+'|G HUB';Path=$run;Name='G HUB';Command=$command;Hash='new'})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture).Passed | Should -BeTrue
            $before.Items=@(@{Kind='Startup';Key=$run+'|G HUB';Path=$run;Name='G HUB';Command='C:\another.exe';Hash='old'})
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $before.Items=@();$after.Items[0].Name='SomeoneElse';$after.Items[0].Key=$run+'|SomeoneElse'
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'permits a newly selected G HUB uninstall key within the same selector scope' {
        InModuleScope InstallerAudit {
            $newPath='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{NEW-GHUB}'
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $after.RegistryRoots=@($after.RegistryRoots)+@($newPath)
            $after.Items=@(@{Kind='Registry';Key=$newPath+'|DisplayName';Path=$newPath;Hash='new'})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $script:emptyManifest fixture).Passed | Should -BeTrue
            $script:auditReport.Value.RegistryRoots | Should -Contain $newPath
            $script:auditReport.Value.NotAudited.Count | Should -BeGreaterThan 0
        }
    }
    It 'rejects mismatched scope versions even when there are no differences' {
        InModuleScope InstallerAudit {
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone();$after.ScopeVersion=2
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $script:emptyManifest fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'allows only exact captured kernel ownership and still blocks unknown services drivers and class filters' {
        InModuleScope InstallerAudit {
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $target=$script:emptyManifest.Clone();$target.KernelServices=@(@{Name='lghub_owned';Path='C:\Windows\System32\drivers\owned.sys'})
            $after.Items=@(@{Kind='KernelService';Key='lghub_owned';Path='C:\Windows\System32\drivers\owned.sys';Hash='new'})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture).Passed | Should -BeTrue
            foreach($kind in @('Service','KernelService','ClassFilter')){
                $after.Items=@(@{Kind=$kind;Key='unknown';Path='C:\unknown.sys';Hash='new'})
                {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            }
        }
    }
    It 'requires complete matching app-local temperature-driver capture before classification' {
        InModuleScope InstallerAudit {
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $driver=Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys'
            $after.Items=@(@{Kind='KernelService';Key='LGHUBTemperatureService';Path=('\??\'+$driver);Hash=('c'*64)})
            $entry=@{Name='LGHUBTemperatureService';AppLocal=$true;RawPath=('\??\'+$driver);Path=$driver;RelativePath='logi_core_temp.sys';Sha256=('a'*64);SignatureThumbprint=('b'*40);Native=@{ServiceType=1}}
            $target=$script:emptyManifest.Clone();$target.KernelServices=@($entry);$target.Files=@(@{Relative='logi_core_temp.sys';Sha256=('a'*64);IsDirectory=$false})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture).Passed | Should -BeTrue
            foreach($field in @('Sha256','SignatureThumbprint','RelativePath','AppLocal')){
                $saved=$entry[$field];$entry[$field]=$null
                {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
                $entry[$field]=$saved
            }
            $target.Files[0].Sha256='d'*64
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'does not classify a foreign service takeover as a G HUB service addition' {
        InModuleScope InstallerAudit {
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $target=$script:emptyManifest.Clone();$target.Services=@(@{Name='GHubService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe"'})
            $after.Items=@(@{Kind='Service';Key='GHubService';Path='"C:\Program Files\LGHUB\lghub_updater.exe"';Hash='new'})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture).Passed | Should -BeTrue
            $before.Items=@(@{Kind='Service';Key='GHubService';Path='C:\Other.exe';Hash='old'})
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'matches both service images for replacement and source ownership for removal' {
        InModuleScope InstallerAudit {
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $source=$script:emptyManifest.Clone();$target=$script:emptyManifest.Clone()
            $source.Services=@(@{Name='GHubService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe" --old'})
            $target.Services=@(@{Name='GHubService';ImagePath='"C:\Program Files\LGHUB\lghub_updater.exe" --new'})
            $before.Items=@(@{Kind='Service';Key='GHubService';Path=$source.Services[0].ImagePath;Hash='old'})
            $after.Items=@(@{Kind='Service';Key='GHubService';Path=$target.Services[0].ImagePath;Hash='new'})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $target fixture).Passed | Should -BeTrue
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $source fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $after.Items=@()
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $script:emptyManifest fixture).Passed | Should -BeTrue
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $source fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'requires the original task to belong to the source before replacing it' {
        InModuleScope InstallerAudit {
            $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command></Exec></Actions></Task>'
            $target=$script:emptyManifest.Clone();$target.Tasks=@(@{Name='GHubTask';Path='\';Xml=$xml})
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $after.Items=@(@{Kind='Task';Key='\GHubTask';Path='C:\Program Files\LGHUB\lghub.exe';Hash=(Get-TextHash $xml)})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture).Passed | Should -BeTrue
            $before.Items=@(@{Kind='Task';Key='\GHubTask';Path='C:\Other.exe';Hash='foreign-xml'})
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'rejects mixed external task actions non-Exec actions and XML mismatches' {
        InModuleScope InstallerAudit {
            $good='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command></Exec></Actions></Task>'
            $mixed=$good.Replace('</Actions>','<Exec><Command>C:\Other.exe</Command></Exec></Actions>')
            $handler=$good.Replace('</Actions>','<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler></Actions>')
            foreach($xml in @($mixed,$handler,$good)){
                $target=$script:emptyManifest.Clone();$target.Tasks=@(@{Name='GHubTask';Path='\';Xml=$xml})
                $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
                $hash=if($xml -eq $good){'different-xml'}else{Get-TextHash $xml}
                $after.Items=@(@{Kind='Task';Key='\GHubTask';Path='C:\Program Files\LGHUB\lghub.exe|C:\Other.exe';Hash=$hash})
                {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            }
        }
    }
    It 'matches both task XML documents for replacement and source ownership for removal' {
        InModuleScope InstallerAudit {
            $oldXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command><Arguments>--old</Arguments></Exec></Actions></Task>'
            $newXml=$oldXml.Replace('--old','--new')
            $source=$script:emptyManifest.Clone();$source.Tasks=@(@{Name='GHubTask';Path='\';Xml=$oldXml})
            $target=$script:emptyManifest.Clone();$target.Tasks=@(@{Name='GHubTask';Path='\';Xml=$newXml})
            $before=$script:boundedSnapshot.Clone();$after=$script:boundedSnapshot.Clone()
            $before.Items=@(@{Kind='Task';Key='\GHubTask';Path='C:\Program Files\LGHUB\lghub.exe';Hash=(Get-TextHash $oldXml)})
            $after.Items=@(@{Kind='Task';Key='\GHubTask';Path='C:\Program Files\LGHUB\lghub.exe';Hash=(Get-TextHash $newXml)})
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $target fixture).Passed | Should -BeTrue
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $source fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $after.Items=@()
            (Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $script:emptyManifest fixture).Passed | Should -BeTrue
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $script:emptyManifest $source fixture} | Should -Throw '*UnclassifiedInstallerChange*'
            $before.Items=@();$after.Items=@(@{Kind='Task';Key='\AnotherTask';Path='C:\Program Files\LGHUB\lghub.exe';Hash=(Get-TextHash $newXml)})
            {Confirm-InstallerChanges @{Root='C:\fixture';OwnerSid='fixture'} $before $after $source $target fixture} | Should -Throw '*UnclassifiedInstallerChange*'
        }
    }
    It 'normalizes task executable paths and rejects commands outside the active directory' {
        InModuleScope InstallerAudit {
            $template='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>{0}</Command></Exec></Actions></Task>'
            foreach($command in @('%ProgramFiles%\LGHUB\lghub.exe','"%ProgramFiles%\LGHUB\lghub.exe"','%ProgramFiles%\LGHUB\sub\..\lghub.exe')){
                Test-InstallerTaskXml ($template -f $command) | Should -BeTrue
            }
            foreach($command in @('C:\Other\LGHUB\lghub.exe','%ProgramFiles%\LGHUB2\lghub.exe','%ProgramFiles%\LGHUB\..\Other.exe','lghub.exe','C:lghub.exe','%ProgramFiles%\LGHUB\','')){
                Test-InstallerTaskXml ($template -f $command) | Should -BeFalse
            }
        }
    }
    It 'rejects malformed task XML empty actions repeated commands and DTDs' {
        InModuleScope InstallerAudit {
            $good='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command></Exec></Actions></Task>'
            foreach($xml in @('<Task>',$good.Replace('<Exec><Command>C:\Program Files\LGHUB\lghub.exe</Command></Exec>',''),$good.Replace('</Command>','</Command><Command>C:\Program Files\LGHUB\lghub_agent.exe</Command>'),'<!DOCTYPE Task [<!ENTITY fixture "C:\Program Files\LGHUB\lghub.exe">]>'+$good.Replace('C:\Program Files\LGHUB\lghub.exe','&fixture;'))){
                Test-InstallerTaskXml $xml | Should -BeFalse
            }
        }
    }
}
