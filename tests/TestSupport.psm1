function New-TestContext {
    param([string]$Root)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ctx=New-SwitchContext -Root $Root -OwnerSid $sid -ProfileRoot $Root -Mode Simulation
    foreach ($role in @('Program','LocalData','RoamingData','MachineData')) {
        foreach ($pair in @(@{Path="active/$role";Slot='modern'},@{Path="Environments/legacy/$role";Slot='legacy'})) {
            $dir=Join-Path $Root $pair.Path; [IO.Directory]::CreateDirectory($dir) | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'slot.txt'),$pair.Slot)
        }
    }
    $state=New-SwitchState $ctx modern boot-a
    $state.TransactionId='fixture'; Write-SwitchState $ctx $state
    return $ctx
}
Export-ModuleMember -Function New-TestContext
