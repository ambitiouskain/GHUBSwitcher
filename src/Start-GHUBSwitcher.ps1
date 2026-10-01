param([switch]$LoadFunctionsOnly,[switch]$ReadOnly)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Desktop'){
    Import-Module (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
}
$expectedCheckerHash='__GHUB_PACKAGE_CHECK_SHA256__'
$packaged=$expectedCheckerHash -match '^[A-Fa-f0-9]{64}$'
if($packaged -or (-not $LoadFunctionsOnly -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'release-manifest.json')))){
    $checker=Join-Path $PSScriptRoot 'PackagePreflight.ps1'
    if((Get-FileHash -LiteralPath $checker).Hash -cne $expectedCheckerHash){throw 'Release verifier hash mismatch.'}
    . $checker
    $installed=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $installed=[bool]$installed.InstalledRuntime
    $null=Get-VerifiedPackageBootstrap $PSScriptRoot -InstalledRuntime:$installed
}
Import-Module (Join-Path $PSScriptRoot 'Modules/Core.psm1') -DisableNameChecking

function Format-HealthMessage {param($State)
    switch($State.Phase){
        PendingReboot {return '需要重启 Windows，目标环境尚未放行。'}
        AwaitingLogon {return '等待原用户登录后启动。'}
        RecoveryRequired {return '需要恢复；请查看错误详情或选择恢复新版。'}
        Idle {if($State.Health -eq 'InstallationAndConfigurationPassed'){return '程序安装完整，配置已还原，所选 G HUB 已启动。'};if($State.Health -eq 'TechnicalPassed'){return '技术检查通过，所选 G HUB 环境已启动。'};return '环境已登记，仍需核验。'}
        NotPrepared {return '尚未准备两套环境。'}
        Detached {return '已退出切换器管理；请正常启动新版 G HUB。'}
        Detaching {return '退出管理尚未完成，请选择 8 续接。'}
        default {return '操作进行中，请勿重复启动或手动打开另一版本。'}
    }
}
function Get-MenuActions {param($State,[bool]$LegacyReady)
    $idle=$State.Phase -eq 'Idle'
    @(
        [pscustomobject]@{Key='1';Label='启动新版';Action='Switch';Target='modern';Enabled=$idle},
        [pscustomobject]@{Key='2';Label='启动 2021.3';Action='Switch';Target='legacy';Enabled=($idle -and $LegacyReady)},
        [pscustomobject]@{Key='3';Label='恢复新版 / 续接重启';Action='RestoreModern';Target='modern';Enabled=($State.Phase -notin @('NotPrepared','Detached','Detaching'))},
        [pscustomobject]@{Key='4';Label='查看诊断';Action='Diagnostics';Target='';Enabled=$true},
        [pscustomobject]@{Key='5';Label='准备新版备份';Action='Initialize';Target='modern';Enabled=($State.Phase -eq 'NotPrepared')},
        [pscustomobject]@{Key='6';Label='首次安装并捕获旧版（交互向导）';Action='PrepareLegacy';Target='legacy';Enabled=($idle -and (Get-ObjectValue $State Active '') -eq 'modern' -and -not $LegacyReady)},
        [pscustomobject]@{Key='7';Label='维护更新新版';Action='MaintainModern';Target='modern';Enabled=($idle -and (Get-ObjectValue $State Active '') -eq 'modern')},
        [pscustomobject]@{Key='8';Label='退出切换器管理，保留新版';Action='RemoveControl';Target='modern';Enabled=(($idle -or $State.Phase -eq 'Detaching') -and (Get-ObjectValue $State Active '') -eq 'modern')}
    )
}
function Format-MenuAction {param($Item)
    $Item.Key+'. '+$Item.Label
}
if($LoadFunctionsOnly){return}
$root=Get-SwitcherRoot $PSScriptRoot
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if(-not (Test-Path -LiteralPath (Join-Path $root 'registration.json'))){
    if($ReadOnly){Write-Output '尚未安装切换器。';return}
    Write-Host 'G HUB 双版本切换器：正在初始化便携目录，请允许 Windows 管理员授权。'
    Write-Host '安装后按向导准备本机的新版与旧版环境。'
    $installer=Join-Path $PSScriptRoot 'Install-GHUBSwitcher.ps1'
    $shell="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $args='-NoProfile -ExecutionPolicy Bypass -File "'+$installer+'" -OwnerSid "'+$sid+'" -PauseOnFailure'
    try{Start-Process -FilePath $shell -ArgumentList $args -Verb RunAs -WindowStyle Normal -Wait}catch{Write-Host ('安装未完成：'+$_.Exception.Message)}
    if(-not (Test-Path -LiteralPath (Join-Path $root 'registration.json'))){Read-Host '安装未完成，按 Enter 关闭窗口'|Out-Null;return}
}
$registration=Read-AtomicJson (Join-Path $root 'registration.json')
if($registration.OwnerSid -ne $sid){throw 'OwnerMismatch: 请使用最初登记的 Windows 用户。'}
do{
    $state=[pscustomobject]@{Phase='NotPrepared';Health='Unverified';Active='';Target=$null;LastError=$null}
    $statusPath=Join-Path $root 'Status/status.json'
    if(Test-Path -LiteralPath $statusPath){$state=Read-AtomicJson $statusPath}
    $registration=Read-AtomicJson (Join-Path $root 'registration.json')
    if(Get-ObjectValue $registration Detached $false){$state.Phase='Detached'}
    $readyPath=Join-Path $root 'Status/environments.json'
    $legacyReady=$false;if(Test-Path -LiteralPath $readyPath){$legacyReady=(Read-AtomicJson $readyPath).LegacyReady}
    Write-Host "`nG HUB 双版本切换器"
    Write-Host ('数据目录：'+$root)
    Write-Host ('新版备份：'+(Join-Path $root 'Backups'))
    Write-Host ('状态：'+(Format-HealthMessage $state))
    Write-Host ('活动槽：'+$state.Active+'；目标槽：'+$state.Target)
    if($state.LastError){$label=if($state.Phase -eq 'Idle' -and $state.Health -eq 'TechnicalPassed'){'上次操作记录（当前环境已恢复）：'}else{'详情：'};Write-Host ($label+$state.LastError)}
    if($state.Phase -eq 'NotPrepared'){Write-Host '下一步：输入 5，准备新版备份。'}
    elseif($state.Phase -eq 'Idle' -and -not $legacyReady){Write-Host '下一步：新版准备完成；需要安装旧版时输入 6。'}
    if($ReadOnly){break}
    $actions=@(Get-MenuActions $state $legacyReady)
    foreach($item in $actions){Write-Host (Format-MenuAction $item)}
    Write-Host '0. 关闭菜单（不停止已启动的 G HUB）'
    $choice=Read-Host '选择'
    if($choice -eq '0'){break}
    $selected=@($actions|Where-Object Key -EQ $choice)
    if($selected.Count -ne 1 -or -not $selected[0].Enabled){continue}
    $item=$selected[0]
    if($item.Action -eq 'Diagnostics'){
        Write-Host ('诊断目录：'+(Join-Path $root 'Status'))
        Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList ('"'+(Join-Path $root 'Status')+'"')
        continue
    }
    if($item.Action -eq 'RemoveControl' -and (Read-Host '输入 REMOVE 退出管理（保留备份与 G HUB）') -cne 'REMOVE'){continue}
    $worker=Join-Path $root 'App/Invoke-GHUBWorker.ps1'
    $args='-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'" -Action '+$item.Action
    if($item.Target){$args+=' -TargetSlot '+$item.Target}
    $window=if($item.Action -in @('Initialize','PrepareLegacy','MaintainModern')){'Normal'}else{'Hidden'}
    try{Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -WindowStyle $window -Wait}catch{Write-Host ('操作未完成：'+$_.Exception.Message)}
}while($true)
