BeforeAll {
    $path="$PSScriptRoot/../src/Start-GHUBSwitcher.ps1"
    if(Test-Path $path){. $path -LoadFunctionsOnly}
}
Describe 'User-facing state reporting' {
    It 'does not present pending reboot as completion' {
        Format-HealthMessage @{Phase='PendingReboot';Health='Unverified';Active='modern';Target='legacy'} | Should -Match '重启'
    }
    It 'separates technical checks from mouse function acceptance' {
        Format-HealthMessage @{Phase='Idle';Health='TechnicalPassed';Active='modern';Target=$null} | Should -Not -Match '功能已验收|全部功能通过'
    }
    It 'disables ordinary switching during a transaction' {
        $actions=@(Get-MenuActions @{Phase='Swapping'} $true)
        @($actions|Where-Object {$_.Action -eq 'Switch' -and $_.Enabled}).Count | Should -Be 0
    }
    It 'does not advertise legacy as ready before capture' {
        $actions=@(Get-MenuActions @{Phase='Idle'} $false)
        @($actions|Where-Object {$_.Target -eq 'legacy' -and $_.Action -eq 'Switch' -and $_.Enabled}).Count | Should -Be 0
    }
    It 'keeps menu labels plain even when preparation is already complete' {
        $actions=@(Get-MenuActions @{Phase='Idle';Active='modern'} $true)
        foreach($key in @('5','6')) {
            $item=$actions | Where-Object Key -EQ $key
            $item.Enabled | Should -BeFalse
            Format-MenuAction $item | Should -BeExactly ($item.Key+'. '+$item.Label)
        }
    }
    It 'keeps all eight options and plain labels in every supported menu state' {
        foreach($phase in @('NotPrepared','Idle','PendingReboot','RecoveryRequired','Swapping','Maintenance','Detaching','Detached')) {
            foreach($slot in @('modern','legacy')) {
                foreach($ready in @($true,$false)) {
                    $actions=@(Get-MenuActions @{Phase=$phase;Active=$slot} $ready)
                    $actions.Count | Should -Be 8
                    foreach($item in $actions) {
                        Format-MenuAction $item | Should -BeExactly ($item.Key+'. '+$item.Label)
                    }
                }
            }
        }
    }
    It 'starts first preparation only from the correct modern state' {
        (Get-MenuActions @{Phase='NotPrepared';Active=''} $false | Where-Object Key -EQ 5).Enabled | Should -BeTrue
        (Get-MenuActions @{Phase='Idle';Active='modern'} $false | Where-Object Key -EQ 6).Enabled | Should -BeTrue
        (Get-MenuActions @{Phase='Idle';Active='legacy'} $false | Where-Object Key -EQ 6).Enabled | Should -BeFalse
    }
    It 'offers only diagnostics after control is detached' {
        $actions=@(Get-MenuActions @{Phase='Detached';Active='modern'} $true)
        @($actions | Where-Object Enabled).Key | Should -Be '4'
        Format-HealthMessage @{Phase='Detached'} | Should -Match '已退出'
    }
    It 'allows interrupted detachment to resume without starting a switch' {
        @((Get-MenuActions @{Phase='Detaching';Active='modern'} $true)|Where-Object Enabled).Key -join ',' | Should -Be '4,8'
    }
}
