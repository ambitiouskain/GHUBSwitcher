Set-StrictMode -Version Latest
foreach($name in @('Core','Inventory','Lifecycle','Storage')){Import-Module (Join-Path $PSScriptRoot ($name+'.psm1')) -DisableNameChecking}

function Get-InstallerScopeDefinition {param($Context)
    $locations=Get-GHUBRegistryLocations $Context
    [pscustomobject]@{ScopeVersion=1;ProductRoots=$locations.ProductRoots;UninstallParents=$locations.UninstallParents;StartupRoots=$locations.StartupRoots;ScopeSelectors=@('GHubDependenciesV1');NotAudited=@('Registry outside G HUB product roots, recorded product roots, selected G HUB uninstall entries, and Run/RunOnce values.','Service dependencies, delayed auto-start settings, failure actions, and service triggers.','All runtime logs under System32/drivers/DriverData/LogFiles, including its complete subtree.','Arbitrary filesystem paths outside System32/drivers and shared Logitech/Logishrd directories.','Unmanaged device bindings and Driver Store package contents outside captured dependencies.','Runtime process/device state and ownership of concurrent changes by other software.')}
}
function Test-InstallerSelectedRoot {param([string]$Path,$Definition)
    foreach($root in $Definition.ProductRoots){if($Path -ieq $root -or $Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}}
    foreach($parent in $Definition.UninstallParents){
        if($Path.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -and $Path.Substring($parent.Length+1) -notmatch '[\\/]'){return $true}
    }
    return $false
}
function Get-InstallerSnapshot {param($Context)
    Assert-Administrator
    $items=[Collections.Generic.List[object]]::new();$errors=[Collections.Generic.List[string]]::new()
    $definition=Get-InstallerScopeDefinition $Context
    $roots=[Collections.Generic.List[string]]::new()
    foreach($path in $definition.ProductRoots){$roots.Add($path)}
    $registrationPath=Join-Path $Context.Root 'registration.json'
    try{
        if(Test-Path -LiteralPath $registrationPath -ErrorAction Stop){
            $registration=Read-AtomicJson $registrationPath
            foreach($path in @(Get-ObjectValue $registration RegistryRoots @())){
                if(-not(Test-InstallerSelectedRoot $path $definition)){throw ('Registry audit root is outside the declared product selectors: '+$path)}
                if($path -notin $roots){$roots.Add($path)}
            }
        }
    }catch{$errors.Add($_.Exception.Message)}
    foreach($parent in $definition.UninstallParents){
        $readErrors=@()
        if(Test-Path -LiteralPath $parent -ErrorAction SilentlyContinue -ErrorVariable +readErrors){
            Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue -ErrorVariable +readErrors | ForEach-Object {
                $key=$_
                try{
                    if([string]$key.GetValue('DisplayName',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -match '^(Logitech|Logicool) G HUB$'){
                        $path='Registry::'+$key.Name
                        if($path -notin $roots){$roots.Add($path)}
                    }
                }catch{$errors.Add($_.Exception.Message)}finally{if($null -ne $key){$key.Dispose()}}
            }
        }
        foreach($errorItem in $readErrors){$errors.Add([string]$errorItem)}
    }
    $captureKey={
        $key=$_
        try{
            $path='Registry::'+$key.Name
            $items.Add([pscustomobject]@{Kind='Registry';Key=$path+'|<key>';Path=$path;Hash='present'})
            foreach($name in $key.GetValueNames()){
                $value=@{Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
                $items.Add([pscustomobject]@{Kind='Registry';Key=$path+'|'+$name;Path=$path;Hash=(Get-TextHash ($value|ConvertTo-Json -Compress -Depth 20))})
            }
        }catch{$errors.Add($_.Exception.Message)}finally{
            if($null -ne $key){$key.Dispose()}
        }
    }
    foreach($root in $roots){
        $readErrors=@()
        if(Test-Path -LiteralPath $root -ErrorAction SilentlyContinue -ErrorVariable +readErrors){
            Get-Item -LiteralPath $root -ErrorAction SilentlyContinue -ErrorVariable +readErrors | ForEach-Object $captureKey
            Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue -ErrorVariable +readErrors | ForEach-Object $captureKey
        }
        foreach($errorItem in $readErrors){$errors.Add([string]$errorItem)}
    }
    foreach($root in $definition.StartupRoots){
        $readErrors=@()
        if(Test-Path -LiteralPath $root -ErrorAction SilentlyContinue -ErrorVariable +readErrors){
            Get-Item -LiteralPath $root -ErrorAction SilentlyContinue -ErrorVariable +readErrors | ForEach-Object {
                $key=$_
                try{
                    foreach($name in $key.GetValueNames()){
                        $value=[ordered]@{Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
                        $items.Add([pscustomobject]@{Kind='Startup';Key=$root+'|'+$name;Path=$root;Name=$name;Command=[string]$value.Value;Hash=(Get-TextHash ($value|ConvertTo-Json -Compress -Depth 20))})
                    }
                }catch{$errors.Add($_.Exception.Message)}finally{if($null -ne $key){$key.Dispose()}}
            }
        }
        foreach($errorItem in $readErrors){$errors.Add([string]$errorItem)}
    }
    foreach($service in Get-CimInstance Win32_Service -ErrorAction Stop){
        $value=[ordered]@{Path=$service.PathName;Account=$service.StartName;StartMode=$service.StartMode;Type=$service.ServiceType}
        $items.Add([pscustomobject]@{Kind='Service';Key=$service.Name;Path=$service.PathName;Hash=(Get-TextHash ($value|ConvertTo-Json -Compress))})
    }
    foreach($driver in Get-CimInstance Win32_SystemDriver -ErrorAction Stop){
        $path=$driver.PathName -replace '^\\SystemRoot',$env:WINDIR
        $value=[ordered]@{Path=$path;StartMode=$driver.StartMode;Type=$driver.ServiceType}
        $items.Add([pscustomobject]@{Kind='KernelService';Key=$driver.Name;Path=$path;Hash=(Get-TextHash ($value|ConvertTo-Json -Compress))})
    }
    foreach($filter in Get-ClassFilterInventory){$items.Add([pscustomobject]@{Kind='ClassFilter';Key=$filter.ClassGuid;Path=$filter.ClassGuid;Hash=(Get-TextHash ($filter|ConvertTo-Json -Compress))})}
    foreach($task in Get-ScheduledTask -ErrorAction Stop){
        $xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
        $structure=$null
        try{$structure=Get-InstallerTaskStructure $xml}catch{$errors.Add(('Task XML '+$task.TaskPath+$task.TaskName+': '+$_.Exception.Message))}
        $items.Add([pscustomobject]@{Kind='Task';Key=$task.TaskPath+$task.TaskName;Path=(@(Get-TaskExecutables $task) -join '|');Hash=(Get-TextHash $xml);Xml=$xml;StableXml=(Get-ObjectValue $structure StableXml '');StableHash=(Get-ObjectValue $structure StableHash '')})
    }
    $sharedRoots=@((Join-Path $env:WINDIR 'System32/drivers'),(Join-Path $env:CommonProgramFiles 'Logitech'),(Join-Path $env:CommonProgramFiles 'Logishrd'))
    $excludedLogs=Join-Path $env:WINDIR 'System32/drivers/DriverData/LogFiles'
    foreach($root in $sharedRoots){
        $readErrors=@()
        if(Test-Path -LiteralPath $root -ErrorAction SilentlyContinue -ErrorVariable +readErrors){
            $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($root)
            while($pending.Count -gt 0){
                $directory=$pending.Pop()
                Get-ChildItem -LiteralPath $directory -ErrorAction SilentlyContinue -ErrorVariable +readErrors | ForEach-Object {
                    $file=$_
                    if($file.FullName -ine $excludedLogs -and -not $file.FullName.StartsWith($excludedLogs+'\',[StringComparison]::OrdinalIgnoreCase)){
                        if($file.PSIsContainer){$pending.Push($file.FullName)}else{
                            try{$items.Add([pscustomobject]@{Kind='SharedFile';Key=$file.FullName;Path=$file.FullName;Hash=(Get-FileHash -LiteralPath $file.FullName -ErrorAction Stop).Hash.ToLowerInvariant()})}catch{$errors.Add($_.Exception.Message)}
                        }
                    }
                }
            }
        }
        foreach($errorItem in $readErrors){$errors.Add([string]$errorItem)}
    }
    [pscustomobject]@{SchemaVersion=1;ScopeVersion=$definition.ScopeVersion;ScopeSelectors=$definition.ScopeSelectors;RegistryRoots=$roots.ToArray();StartupRoots=$definition.StartupRoots;NotAudited=$definition.NotAudited;OwnerSid=$Context.OwnerSid;Items=$items.ToArray();Errors=$errors.ToArray();Coverage=@('Registry','Startup','Services','KernelServices','ClassFilters','SharedFiles','Tasks');CapturedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Test-InstallerStartupOwnership {param($Record,[object[]]$Entries)
    if($null -eq $Record){return $true}
    foreach($entry in $Entries){if($entry.Path -ieq $Record.Path -and $entry.Name -ieq $Record.Name -and [string]$entry.Value -ceq [string]$Record.Command){return $true}}
    return $false
}
function Test-InstallerKernelOwnership {param($Record,[object[]]$Entries,[object[]]$Files=@())
    if($null -eq $Record){return $true}
    foreach($entry in $Entries){
        if($entry.Name -ine $Record.Key){continue}
        if($entry.Name -ieq 'LGHUBTemperatureService' -or (Get-ObjectValue $entry AppLocal $false)){
            try{
                if($entry.Name -cne 'LGHUBTemperatureService' -or (Get-ObjectValue $entry AppLocal $false) -ne $true -or $entry.RelativePath -cne 'logi_core_temp.sys' -or $entry.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.SignatureThumbprint -notmatch '^[a-f0-9]{40,64}$' -or [int]$entry.Native.ServiceType -ne 1){continue}
                $expected=Join-Path $env:ProgramFiles 'LGHUB\logi_core_temp.sys'
                if((ConvertTo-KernelImagePath $Record.Path) -ine $expected -or (ConvertTo-KernelImagePath $entry.Path) -ine $expected -or (ConvertTo-KernelImagePath $entry.RawPath) -ine $expected){continue}
                $matching=@($Files|Where-Object {$_.Relative -ceq $entry.RelativePath -and $_.Sha256 -ceq $entry.Sha256 -and -not (Get-ObjectValue $_ IsDirectory $false)})
                if($matching.Count -eq 1){return $true}
            }catch{}
        }elseif($entry.Path -ieq $Record.Path){return $true}
    }
    return $false
}
function Test-InstallerServiceOwnership {param($Record,[object[]]$Entries)
    if($null -eq $Record){return $true}
    foreach($entry in $Entries){if($entry.Name -ieq $Record.Key -and $entry.ImagePath -ceq $Record.Path -and $entry.ImagePath -match '(?i)\\LGHUB\\'){return $true}}
    return $false
}
function Read-InstallerTaskXml {param([string]$Xml)
    $reader=$null
    try{
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($Xml),$settings)
        $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
        return ,$document
    }finally{if($null -ne $reader){$reader.Dispose()}}
}
function Get-InstallerTaskStructure {param([string]$Xml)
    $document=Read-InstallerTaskXml $Xml
    $namespace='http://schemas.microsoft.com/windows/2004/02/mit/task'
    if($document.DocumentElement.LocalName -cne 'Task' -or $document.DocumentElement.NamespaceURI -cne $namespace){throw 'Invalid task XML root.'}
    $manager=[Xml.XmlNamespaceManager]::new($document.NameTable);$manager.AddNamespace('t',$namespace)
    $times=@($document.DocumentElement.SelectNodes('t:Triggers/t:TimeTrigger/t:StartBoundary | t:Triggers/t:CalendarTrigger/t:StartBoundary',$manager))
    $values=[Collections.Generic.List[string]]::new()
    foreach($time in $times){
        if($time.Attributes.Count -ne 0 -or $time.ChildNodes.Count -ne 1 -or $time.FirstChild.NodeType -ne [Xml.XmlNodeType]::Text){throw 'Invalid task start boundary.'}
        $null=[Xml.XmlConvert]::ToDateTime($time.InnerText,[Xml.XmlDateTimeSerializationMode]::RoundtripKind)
        $values.Add($time.InnerText)
        $time.InnerText='__VERIFIED_START_BOUNDARY__'
    }
    $stable=$document.DocumentElement.OuterXml
    [pscustomobject]@{StableXml=$stable;StableHash=(Get-TextHash $stable);StartBoundaryCount=$times.Count;StartBoundaries=$values.ToArray()}
}
function Test-InstallerTaskScheduleTransition {param($Before,$After)
    try{
        if($null -eq $Before -or $null -eq $After -or $Before.Kind -cne 'Task' -or $After.Kind -cne 'Task' -or $Before.Key -cne $After.Key -or -not $Before.Key.StartsWith('\Microsoft\Windows\',[StringComparison]::Ordinal) -or $Before.Path -cne $After.Path){return $false}
        $structures=@()
        foreach($record in @($Before,$After)){
            $xml=[string](Get-ObjectValue $record Xml '')
            if(-not $xml -or (Get-TextHash $xml) -cne $record.Hash){return $false}
            $structure=Get-InstallerTaskStructure $xml
            foreach($field in @('StableXml','StableHash')){
                $saved=[string](Get-ObjectValue $record $field '')
                if($saved -and $saved -cne $structure.$field){return $false}
            }
            $structures+=@($structure)
        }
        return ($Before.Hash -cne $After.Hash -and $structures[0].StartBoundaryCount -gt 0 -and ($structures[0].StartBoundaries|ConvertTo-Json -Compress) -cne ($structures[1].StartBoundaries|ConvertTo-Json -Compress) -and $structures[0].StableXml -ceq $structures[1].StableXml)
    }catch{return $false}
}
function Test-InstallerTaskXml {param([string]$Xml)
    try{
        $document=Read-InstallerTaskXml $Xml
        $namespace='http://schemas.microsoft.com/windows/2004/02/mit/task'
        if($document.DocumentElement.LocalName -cne 'Task' -or $document.DocumentElement.NamespaceURI -cne $namespace){return $false}
        $manager=[Xml.XmlNamespaceManager]::new($document.NameTable);$manager.AddNamespace('t',$namespace)
        $groups=@($document.DocumentElement.SelectNodes('t:Actions',$manager))
        if($groups.Count -ne 1){return $false}
        $actions=@($groups[0].SelectNodes('*'))
        if($actions.Count -eq 0){return $false}
        $program=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'LGHUB')).TrimEnd('\')+'\'
        foreach($action in $actions){
            if($action.LocalName -cne 'Exec' -or $action.NamespaceURI -cne $namespace){return $false}
            $commands=@($action.SelectNodes('t:Command',$manager))
            if($commands.Count -ne 1 -or $commands[0].SelectNodes('*').Count -ne 0){return $false}
            $command=[Environment]::ExpandEnvironmentVariables($commands[0].InnerText).Trim()
            if($command.StartsWith('"') -and $command.EndsWith('"') -and $command.Length -gt 1){$command=$command.Substring(1,$command.Length-2)}
            if($command -notmatch '^[a-zA-Z]:[\\/]'){return $false}
            $executable=[IO.Path]::GetFullPath($command)
            if(-not $executable.StartsWith($program,[StringComparison]::OrdinalIgnoreCase) -or $executable.Length -le $program.Length -or $executable.EndsWith('\')){return $false}
        }
        return $true
    }catch{return $false}
}
function Test-InstallerTaskDisableTransition {param([string]$OriginalXml,[string]$CurrentXml)
    if(-not(Test-InstallerTaskXml $OriginalXml) -or -not(Test-InstallerTaskXml $CurrentXml)){return $false}
    try{
        $before=Read-InstallerTaskXml $OriginalXml;$after=Read-InstallerTaskXml $CurrentXml
        if($before.DocumentElement.OuterXml -ceq $after.DocumentElement.OuterXml){return $true}
        $manager=[Xml.XmlNamespaceManager]::new($after.NameTable);$manager.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
        $beforeSettings=@($before.DocumentElement.SelectNodes('t:Settings',$manager));$afterSettings=@($after.DocumentElement.SelectNodes('t:Settings',$manager))
        if($beforeSettings.Count -gt 1 -or $afterSettings.Count -ne 1){return $false}
        $disabled=@($afterSettings[0].SelectNodes('t:Enabled',$manager))
        if($disabled.Count -ne 1 -or $disabled[0].InnerText -cnotin @('false','0') -or $disabled[0].Attributes.Count -ne 0 -or $disabled[0].ChildNodes.Count -ne 1 -or $disabled[0].FirstChild.NodeType -ne [Xml.XmlNodeType]::Text){return $false}
        [void]$afterSettings[0].RemoveChild($disabled[0])
        if($beforeSettings.Count){
            $enabled=@($beforeSettings[0].SelectNodes('t:Enabled',$manager))
            if($enabled.Count -gt 1){return $false}
            if($enabled.Count){
                if($enabled[0].InnerText -cnotin @('true','false','1','0') -or $enabled[0].Attributes.Count -ne 0 -or $enabled[0].ChildNodes.Count -ne 1 -or $enabled[0].FirstChild.NodeType -ne [Xml.XmlNodeType]::Text){return $false}
                [void]$beforeSettings[0].RemoveChild($enabled[0])
            }
            foreach($settings in @($beforeSettings[0],$afterSettings[0])){if(-not $settings.HasChildNodes){$settings.IsEmpty=$true}}
        }else{
            if($afterSettings[0].HasChildNodes -or $afterSettings[0].HasAttributes){return $false}
            [void]$after.DocumentElement.RemoveChild($afterSettings[0])
        }
        return ($before.DocumentElement.OuterXml -ceq $after.DocumentElement.OuterXml)
    }catch{return $false}
}
function Get-InstallerAuditSource {param($Source,[object[]]$CurrentTasks)
    # This is an audit-only view: retain original service/restore configuration.
    $audit=$Source|ConvertTo-Json -Depth 60|ConvertFrom-Json
    $known=@{}
    foreach($task in @(Get-ObjectValue $audit Tasks @())){
        $identity=[string]$task.Path+[string]$task.Name
        if($known.ContainsKey($identity)){Throw-SwitchError UnclassifiedInstallerChange ('Duplicate source task identity: '+$identity)}
        $known[$identity]=$true
        $matches=@($CurrentTasks|Where-Object {([string](Get-ObjectValue $_ Path '')+[string](Get-ObjectValue $_ Name '')) -ieq $identity})
        if($matches.Count -gt 1){Throw-SwitchError UnclassifiedInstallerChange ('Duplicate current task identity: '+$identity)}
        if($matches.Count -eq 1){
            $xml=[string](Get-ObjectValue $matches[0] Xml '')
            if(-not(Test-InstallerTaskDisableTransition ([string]$task.Xml) $xml)){Throw-SwitchError UnclassifiedInstallerChange ('Source task changed beyond its managed disabled setting: '+$identity)}
            $task.Xml=$xml
        }
    }
    return $audit
}
function Test-InstallerTaskOwnership {param($Record,[object[]]$Entries)
    if($null -eq $Record){return $true}
    foreach($entry in $Entries){
        $name=[string](Get-ObjectValue $entry Name '');$path=[string](Get-ObjectValue $entry Path '');$xml=[string](Get-ObjectValue $entry Xml '')
        if($name -and $path -and $xml -and ($path+$name) -ieq $Record.Key -and (Get-TextHash $xml) -ceq $Record.Hash -and (Test-InstallerTaskXml $xml)){return $true}
    }
    return $false
}
function Compare-InstallerChanges {param($Context,$Before,$After,$Source,$Target,[string]$TransactionId)
    $unknown=[Collections.Generic.List[object]]::new();$changes=[Collections.Generic.List[object]]::new()
    $beforeScope=Get-ObjectValue $Before ScopeVersion 0;$afterScope=Get-ObjectValue $After ScopeVersion 0
    if($beforeScope -ne $afterScope -or $afterScope -notin @(0,1)){$unknown.Add('Installer audit scope version mismatch.')}
    if($beforeScope -eq 1 -and $afterScope -eq 1){
        foreach($field in @('ScopeSelectors','NotAudited')){
            $leftScope=@(Get-ObjectValue $Before $field @());$rightScope=@(Get-ObjectValue $After $field @())
            if(-not $leftScope.Count -or ($leftScope|ConvertTo-Json -Compress) -cne ($rightScope|ConvertTo-Json -Compress)){$unknown.Add('Installer audit scope mismatch: '+$field)}
        }
        foreach($snapshot in @($Before,$After)){
            if(-not @(Get-ObjectValue $snapshot RegistryRoots @()).Count){$unknown.Add('Missing registry scope declaration.')}
            foreach($scope in @('Startup','KernelServices')){if($scope -notin $snapshot.Coverage){$unknown.Add('Missing coverage: '+$scope)}}
        }
    }
    $registryRoots=@(@(Get-ObjectValue $Before RegistryRoots @())+@(Get-ObjectValue $After RegistryRoots @())|Sort-Object -Unique)
    foreach($snapshot in @($Before,$After)){
        foreach($errorItem in @(Get-ObjectValue $snapshot Errors @())){$unknown.Add($errorItem)}
        foreach($scope in @('Registry','Services','ClassFilters','SharedFiles','Tasks')){if($scope -notin @(Get-ObjectValue $snapshot Coverage @())){$unknown.Add('Missing coverage: '+$scope)}}
    }
    $left=@{};$right=@{}
    foreach($record in @(Get-ObjectValue $Before Items @())){$id=$record.Kind+'|'+$record.Key;if($left.ContainsKey($id)){$unknown.Add('Duplicate before record: '+$id)};$left[$id]=$record}
    foreach($record in @(Get-ObjectValue $After Items @())){$id=$record.Kind+'|'+$record.Key;if($right.ContainsKey($id)){$unknown.Add('Duplicate after record: '+$id)};$right[$id]=$record}
    $services=@(Get-ObjectValue $Source Services @())+@(Get-ObjectValue $Target Services @())
    $kernel=@(Get-ObjectValue $Source KernelServices @())+@(Get-ObjectValue $Target KernelServices @())
    $devices=@(Get-ObjectValue $Source Devices @())+@(Get-ObjectValue $Target Devices @())
    foreach($id in @(@($left.Keys)+@($right.Keys)|Sort-Object -Unique)){
        if($left.ContainsKey($id) -and $right.ContainsKey($id) -and $left[$id].Hash -ceq $right[$id].Hash){continue}
        $record=if($right.ContainsKey($id)){$right[$id]}else{$left[$id]};$owned=$false;$classification='CapturedGHubOwnership'
        switch($record.Kind){
            Registry {
                try{Test-GHUBRegistryPath $Context $record.Path;$owned=$true}catch{}
                if($beforeScope -eq 1 -and $afterScope -eq 1){foreach($root in $registryRoots){if($record.Path -ieq $root -or $record.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){$owned=$true}}}
                foreach($service in @($services)+@($kernel)){
                    $root='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\'+$service.Name
                    if($record.Path -ieq $root -or $record.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){$owned=$true}
                }
                foreach($device in $devices){
                    $root='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\'+$device.InstanceId
                    if($record.Path -ieq $root -or $record.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){$owned=$true}
                }
            }
            Service {$owned=(Test-InstallerServiceOwnership $left[$id] @(Get-ObjectValue $Source Services @())) -and (Test-InstallerServiceOwnership $right[$id] @(Get-ObjectValue $Target Services @()))}
            Startup {$owned=(Test-InstallerStartupOwnership $left[$id] @(Get-ObjectValue $Source Startup @())) -and (Test-InstallerStartupOwnership $right[$id] @(Get-ObjectValue $Target Startup @()))}
            KernelService {$owned=(Test-InstallerKernelOwnership $left[$id] @(Get-ObjectValue $Source KernelServices @()) @(Get-ObjectValue $Source Files @())) -and (Test-InstallerKernelOwnership $right[$id] @(Get-ObjectValue $Target KernelServices @()) @(Get-ObjectValue $Target Files @()))}
            SharedFile {$owned=@($kernel|Where-Object {$_.Path -ieq $record.Path -and $_.Sha256 -ceq $record.Hash -and $_.Name -match '^logi_joy_|^logi_lamparray$|^lghub'}).Count -gt 0}
            Task {
                $owned=(Test-InstallerTaskOwnership $left[$id] @(Get-ObjectValue $Source Tasks @())) -and (Test-InstallerTaskOwnership $right[$id] @(Get-ObjectValue $Target Tasks @()))
                if(-not $owned -and (Test-InstallerTaskScheduleTransition $left[$id] $right[$id])){$owned=$true;$classification='WindowsTaskScheduleTime'}
            }
            ClassFilter {$owned=$false}
        }
        if(-not $owned){$classification='Unclassified'}
        $changes.Add([pscustomobject]@{Kind=$record.Kind;Key=$record.Key;Before=$left[$id];After=$right[$id];Classified=$owned;Classification=$classification})
        if(-not $owned){$unknown.Add($id)}
    }
    [pscustomobject]@{SchemaVersion=1;TransactionId=$TransactionId;ScopeVersion=$afterScope;ScopeSelectors=@(Get-ObjectValue $After ScopeSelectors @());RegistryRoots=$registryRoots;NotAudited=@(Get-ObjectValue $After NotAudited @());OwnerSid=$Context.OwnerSid;ProductVersion=$Target.ProductVersion;Passed=($unknown.Count -eq 0);Unknown=$unknown.ToArray();Changes=$changes.ToArray();Coverage=$After.Coverage;CapturedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Confirm-InstallerChanges {param($Context,$Before,$After,$Source,$Target,[string]$TransactionId)
    $report=Compare-InstallerChanges $Context $Before $After $Source $Target $TransactionId
    $path=Join-Path $Context.Root "Transactions/$TransactionId-installer-report.json"
    Write-AtomicJson $path $report
    if(-not $report.Passed){Throw-SwitchError UnclassifiedInstallerChange "Installer changes require inspection. Report: $path"}
    [pscustomobject]@{Passed=$true;Path=$path;ProductVersion=$Target.ProductVersion;Sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
}
function Read-InstallerEvidenceArtifact {param($Context,[string]$Path)
    $full=Assert-NoReparsePoint $Path
    $directory=(Assert-NoReparsePoint (Join-Path $Context.Root 'Transactions'))+'\'
    if(-not $full.StartsWith($directory,[StringComparison]::OrdinalIgnoreCase)){Throw-SwitchError InstallerReviewInvalid 'Installer evidence must remain in this transaction directory.'}
    $bytes=[IO.File]::ReadAllBytes($full)
    [pscustomobject]@{Path=$full;Sha256=(Get-Sha256 $bytes);Value=(ConvertFrom-Envelope ([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)))}
}
function Get-InstallerReviewInputs {param($Context,[string]$TransactionId,[string]$TargetManifestPath,[switch]$IncludeSource)
    Assert-SafeIdentifier $TransactionId
    $artifacts=[ordered]@{}
    foreach($name in @('before','after','report')){
        $artifacts[$name]=Read-InstallerEvidenceArtifact $Context (Join-Path $Context.Root "Transactions/$TransactionId-installer-$name.json")
    }
    $artifacts.target=Read-InstallerEvidenceArtifact $Context $TargetManifestPath
    if($IncludeSource){$artifacts.source=Read-InstallerEvidenceArtifact $Context (Join-Path $Context.Root "Transactions/$TransactionId-installer-reviewed-source.json")}
    foreach($artifact in $artifacts.Values){
        if((Get-ObjectValue $artifact.Value OwnerSid '') -cne $Context.OwnerSid){Throw-SwitchError InstallerReviewInvalid 'Installer evidence owner mismatch.'}
    }
    if($artifacts.report.Value.Passed -isnot [bool] -or $artifacts.report.Value.Passed){Throw-SwitchError InstallerReviewInvalid 'Manual review requires the original failed report.'}
    if((Get-ObjectValue $artifacts.report.Value TransactionId $TransactionId) -cne $TransactionId -or $artifacts.report.Value.ProductVersion -cne $artifacts.target.Value.ProductVersion){Throw-SwitchError InstallerReviewInvalid 'Original report transaction or product mismatch.'}
    $bindings=[ordered]@{}
    foreach($name in $artifacts.Keys){$bindings[$name]=[pscustomobject]@{Path=$artifacts[$name].Path;Sha256=$artifacts[$name].Sha256}}
    [pscustomobject]@{Artifacts=$artifacts;Bindings=$bindings}
}
function Assert-InstallerManualReviewChanges {param($Inputs,[object[]]$Changes)
    if(-not $Changes.Count){Throw-SwitchError InstallerReviewInvalid 'No precise task changes were reviewed.'}
    $seen=@{}
    foreach($change in $Changes){
        $kind=[string](Get-ObjectValue $change Kind '');$key=[string](Get-ObjectValue $change Key '')
        $beforeHash=[string](Get-ObjectValue $change BeforeHash '');$afterHash=[string](Get-ObjectValue $change AfterHash '')
        if($kind -cne 'Task' -or -not $key.StartsWith('\Microsoft\Windows\',[StringComparison]::Ordinal) -or $key -match '[*?]' -or $seen.ContainsKey($key) -or $beforeHash -cnotmatch '^[a-f0-9]{64}$' -or $afterHash -cnotmatch '^[a-f0-9]{64}$' -or $beforeHash -ceq $afterHash){Throw-SwitchError InstallerReviewInvalid 'Only unique exact Windows task changes can receive manual review.'}
        $seen[$key]=$true
        $records=@()
        foreach($side in @('before','after')){
            $matches=@($Inputs.Artifacts[$side].Value.Items|Where-Object {$_.Kind -ceq $kind -and $_.Key -ceq $key})
            if($matches.Count -ne 1){Throw-SwitchError InstallerReviewInvalid 'Reviewed task is missing or duplicated in a snapshot.'}
            $records+=@($matches[0])
        }
        if($records[0].Hash -cne $beforeHash -or $records[1].Hash -cne $afterHash -or $records[0].Path -cne $records[1].Path -or (Get-ObjectValue $records[0] Xml '') -or (Get-ObjectValue $records[1] Xml '')){Throw-SwitchError InstallerReviewInvalid 'Review does not match the historical task evidence gap.'}
        $reported=@($Inputs.Artifacts.report.Value.Changes|Where-Object {$_.Kind -ceq $kind -and $_.Key -ceq $key})
        if($reported.Count -ne 1 -or $reported[0].Classified -ne $false -or $reported[0].Before.Hash -cne $beforeHash -or $reported[0].After.Hash -cne $afterHash -or $reported[0].Before.Path -cne $records[0].Path -or $reported[0].After.Path -cne $records[1].Path -or ('Task|'+$key) -cnotin $Inputs.Artifacts.report.Value.Unknown){Throw-SwitchError InstallerReviewInvalid 'Review does not match an original unclassified change.'}
    }
}
function New-InstallerManualReview {param($Context,[string]$TransactionId,[string]$TargetManifestPath,[object[]]$ReviewedChanges,[string]$Reviewer,[string]$Reason,[Parameter(Mandatory=$true)]$Source)
    try{
        $inputs=Get-InstallerReviewInputs $Context $TransactionId $TargetManifestPath
        Assert-InstallerManualReviewChanges $inputs $ReviewedChanges
        if([string]::IsNullOrWhiteSpace($Reviewer) -or [string]::IsNullOrWhiteSpace($Reason)){throw 'Reviewer and review rationale are required.'}
        if((Get-ObjectValue $Source OwnerSid '') -cne $Context.OwnerSid){throw 'Reviewed source owner mismatch.'}
        $path=Join-Path $Context.Root "Transactions/$TransactionId-installer-manual-review.json"
        $sourcePath=Join-Path $Context.Root "Transactions/$TransactionId-installer-reviewed-source.json"
        if((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $sourcePath)){throw 'A manual review or fixed source already exists for this transaction.'}
        $entries=@($ReviewedChanges|ForEach-Object {[pscustomobject][ordered]@{Kind=$_.Kind;Key=$_.Key;BeforeHash=$_.BeforeHash;AfterHash=$_.AfterHash}})
        Write-AtomicJson $sourcePath $Source
        $sourceArtifact=Read-InstallerEvidenceArtifact $Context $sourcePath
        $inputs.Bindings.source=[pscustomobject]@{Path=$sourceArtifact.Path;Sha256=$sourceArtifact.Sha256}
        $review=[pscustomobject]@{SchemaVersion=1;ValidationMode='ManualReview';TransactionId=$TransactionId;OwnerSid=$Context.OwnerSid;OriginalPassed=$false;Bindings=$inputs.Bindings;Changes=$entries;Reviewer=$Reviewer;Reason=$Reason;ReviewedUtc=[DateTime]::UtcNow.ToString('o')}
        Write-AtomicJson $path $review
        $artifact=Read-InstallerEvidenceArtifact $Context $path
        [pscustomobject]@{Path=$artifact.Path;Sha256=$artifact.Sha256;ValidationMode='ManualReview';TransactionId=$TransactionId}
    }catch{Throw-SwitchError InstallerReviewInvalid $_.Exception.Message}
}
function Resolve-InstallerManualReview {param($Context,[string]$TransactionId,[string]$TargetManifestPath,[string]$ReviewPath)
    try{
        $inputs=Get-InstallerReviewInputs $Context $TransactionId $TargetManifestPath -IncludeSource
        $artifact=Read-InstallerEvidenceArtifact $Context $ReviewPath;$review=$artifact.Value
        $expected=[IO.Path]::GetFullPath((Join-Path $Context.Root "Transactions/$TransactionId-installer-manual-review.json"))
        if($artifact.Path -ine $expected -or $review.SchemaVersion -ne 1 -or $review.ValidationMode -cne 'ManualReview' -or $review.TransactionId -cne $TransactionId -or $review.OwnerSid -cne $Context.OwnerSid -or $review.OriginalPassed -isnot [bool] -or $review.OriginalPassed -or [string]::IsNullOrWhiteSpace($review.Reviewer) -or [string]::IsNullOrWhiteSpace($review.Reason)){throw 'Manual review identity mismatch.'}
        foreach($name in $inputs.Bindings.Keys){
            $binding=Get-ObjectValue $review.Bindings $name $null
            if($null -eq $binding -or $binding.Path -cne $inputs.Bindings[$name].Path -or $binding.Sha256 -cne $inputs.Bindings[$name].Sha256){throw ('Changed installer review artifact: '+$name)}
        }
        Assert-InstallerManualReviewChanges $inputs @($review.Changes)
        [pscustomobject]@{Inputs=$inputs;Review=$artifact}
    }catch{Throw-SwitchError InstallerReviewInvalid $_.Exception.Message}
}
function Get-ReviewedInstallerReport {param($Context,$Source,$Resolved,[string]$TransactionId)
    if((Get-ObjectValue $Source OwnerSid '') -cne $Context.OwnerSid){Throw-SwitchError InstallerReviewInvalid 'Reviewed source owner mismatch.'}
    $fixedSource=$Resolved.Inputs.Artifacts.source.Value
    if((Get-InstallerContentIdentity $Source) -cne (Get-InstallerContentIdentity $fixedSource)){Throw-SwitchError InstallerReviewInvalid 'Source differs from the manifest bound when the manual review was created.'}
    $report=Compare-InstallerChanges $Context $Resolved.Inputs.Artifacts.before.Value $Resolved.Inputs.Artifacts.after.Value $fixedSource $Resolved.Inputs.Artifacts.target.Value $TransactionId
    $automaticallyPassed=$report.Passed;$accepted=[Collections.Generic.List[string]]::new()
    foreach($approval in $Resolved.Review.Value.Changes){
        $matches=@($report.Changes|Where-Object {$_.Kind -ceq $approval.Kind -and $_.Key -ceq $approval.Key})
        if($matches.Count -ne 1 -or $matches[0].Classified -or $matches[0].Before.Hash -cne $approval.BeforeHash -or $matches[0].After.Hash -cne $approval.AfterHash){Throw-SwitchError InstallerReviewInvalid 'Manual approval does not match a remaining unclassified change.'}
        $matches[0].Classified=$true;$matches[0].Classification='ManualAcceptedExternalChange'
        $accepted.Add($approval.Kind+'|'+$approval.Key)
    }
    $report.Unknown=@($report.Unknown|Where-Object {$_ -cnotin $accepted})
    $report.Passed=($report.Unknown.Count -eq 0)
    $report|Add-Member -NotePropertyName ValidationMode -NotePropertyValue 'ManualReview'
    $report|Add-Member -NotePropertyName AutomaticallyPassed -NotePropertyValue $automaticallyPassed
    $report|Add-Member -NotePropertyName ManualAcceptedExternalChanges -NotePropertyValue $accepted.ToArray()
    $report
}
function ConvertTo-InstallerCanonicalValue {param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [Collections.IDictionary]){
        $result=[ordered]@{};foreach($key in @($Value.Keys|Sort-Object)){$result[$key]=ConvertTo-InstallerCanonicalValue $Value[$key]};return $result
    }
    if($Value -is [pscustomobject]){
        $result=[ordered]@{};foreach($property in @($Value.PSObject.Properties|Sort-Object Name)){$result[$property.Name]=ConvertTo-InstallerCanonicalValue $property.Value};return $result
    }
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@($Value|ForEach-Object {ConvertTo-InstallerCanonicalValue $_})}
    return $Value
}
function Get-InstallerManifestIdentity {param($Manifest)
    $copy=$Manifest|ConvertTo-Json -Depth 80|ConvertFrom-Json
    foreach($name in @('InstallerEvidence','Qualification')){$copy.PSObject.Properties.Remove($name)}
    Get-TextHash ((ConvertTo-InstallerCanonicalValue $copy)|ConvertTo-Json -Depth 80 -Compress)
}
function Get-InstallerContentIdentity {param($Value)
    $copy=$Value|ConvertTo-Json -Depth 80|ConvertFrom-Json
    Get-TextHash ((ConvertTo-InstallerCanonicalValue $copy)|ConvertTo-Json -Depth 80 -Compress)
}
function Confirm-ReviewedInstallerChanges {param($Context,$Source,[string]$TargetManifestPath,[string]$TransactionId,[string]$ReviewPath)
    $resolved=Resolve-InstallerManualReview $Context $TransactionId $TargetManifestPath $ReviewPath
    $report=Get-ReviewedInstallerReport $Context $Source $resolved $TransactionId
    if(-not $report.Passed){Throw-SwitchError UnclassifiedInstallerChange ('Unreviewed installer evidence remains: '+($report.Unknown -join '; '))}
    $path=Join-Path $Context.Root "Transactions/$TransactionId-installer-reviewed-report.json"
    if(Test-Path -LiteralPath $path){Throw-SwitchError InstallerReviewInvalid 'Reviewed evidence already exists for this transaction.'}
    $sourceArtifact=$resolved.Inputs.Artifacts.source
    $report|Add-Member -NotePropertyName Bindings -NotePropertyValue $resolved.Inputs.Bindings
    $report|Add-Member -NotePropertyName Review -NotePropertyValue ([pscustomobject]@{Path=$resolved.Review.Path;Sha256=$resolved.Review.Sha256})
    $report|Add-Member -NotePropertyName Source -NotePropertyValue ([pscustomobject]@{Path=$sourceArtifact.Path;Sha256=$sourceArtifact.Sha256})
    $report|Add-Member -NotePropertyName TargetManifestIdentity -NotePropertyValue (Get-InstallerManifestIdentity $resolved.Inputs.Artifacts.target.Value)
    Write-AtomicJson $path $report
    $artifact=Read-InstallerEvidenceArtifact $Context $path
    [pscustomobject]@{Passed=$true;ValidationMode='ManualReview';Path=$artifact.Path;Sha256=$artifact.Sha256;ProductVersion=$report.ProductVersion;TransactionId=$TransactionId;ReviewPath=$resolved.Review.Path;ReviewSha256=$resolved.Review.Sha256}
}
function Test-ReviewedInstallerEvidence {param($Context,$Evidence,$Manifest)
    try{
        if($Evidence.Passed -isnot [bool] -or -not $Evidence.Passed -or $Evidence.ValidationMode -cne 'ManualReview' -or $Evidence.ProductVersion -cne $Manifest.ProductVersion){return $false}
        $id=[string]$Evidence.TransactionId;Assert-SafeIdentifier $id
        $artifact=Read-InstallerEvidenceArtifact $Context $Evidence.Path;$report=$artifact.Value
        if($artifact.Path -ine [IO.Path]::GetFullPath((Join-Path $Context.Root "Transactions/$id-installer-reviewed-report.json")) -or $artifact.Sha256 -cne $Evidence.Sha256 -or $report.TransactionId -cne $id -or $report.OwnerSid -cne $Context.OwnerSid -or $report.ValidationMode -cne 'ManualReview' -or -not $report.Passed -or $report.AutomaticallyPassed){return $false}
        $resolved=Resolve-InstallerManualReview $Context $id $report.Bindings.target.Path $report.Review.Path
        if($report.Review.Sha256 -cne $resolved.Review.Sha256 -or $Evidence.ReviewPath -cne $resolved.Review.Path -or $Evidence.ReviewSha256 -cne $resolved.Review.Sha256){return $false}
        foreach($name in $resolved.Inputs.Bindings.Keys){
            $actual=Get-ObjectValue $report.Bindings $name $null;$expected=$resolved.Inputs.Bindings[$name]
            if($actual.Path -cne $expected.Path -or $actual.Sha256 -cne $expected.Sha256){return $false}
        }
        $source=Read-InstallerEvidenceArtifact $Context $report.Source.Path
        if($source.Path -ine [IO.Path]::GetFullPath((Join-Path $Context.Root "Transactions/$id-installer-reviewed-source.json")) -or $source.Sha256 -cne $report.Source.Sha256){return $false}
        $identity=Get-InstallerManifestIdentity $resolved.Inputs.Artifacts.target.Value
        if($identity -cne $report.TargetManifestIdentity -or $identity -cne (Get-InstallerManifestIdentity $Manifest)){return $false}
        $recomputed=Get-ReviewedInstallerReport $Context $source.Value $resolved $id
        $recomputed.CapturedUtc=$report.CapturedUtc
        foreach($name in @('Bindings','Review','Source','TargetManifestIdentity')){$report.PSObject.Properties.Remove($name)}
        $expectedJson=(ConvertTo-InstallerCanonicalValue $recomputed)|ConvertTo-Json -Depth 80 -Compress
        $actualJson=(ConvertTo-InstallerCanonicalValue $report)|ConvertTo-Json -Depth 80 -Compress
        return ($recomputed.Passed -and $actualJson -ceq $expectedJson)
    }catch{return $false}
}
Export-ModuleMember -Function *-*
