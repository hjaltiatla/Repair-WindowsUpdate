BeforeAll {
# Load function definitions via AST; never dot-source the production entry point.
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Repair-WindowsUpdate.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
foreach ($definition in $functions) { . ([scriptblock]::Create($definition.Extent.Text)) }
# Execute the real entry-point statements under mocks; replace exit with return so
# the test runner survives. Function bodies above remain exactly as shipped.
$body = ($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } |
    ForEach-Object { $_.Extent.Text }) -join "`n"
$body = $body -replace '\bexit ([012])', 'return $1'
. ([scriptblock]::Create("function Invoke-TestWorkflow { [CmdletBinding(SupportsShouldProcess = `$true, ConfirmImpact = 'High')] $($ast.ParamBlock.Extent.Text)`n$body }"))

}

Describe 'Repair safeguards (no live repair operations)' {
    BeforeEach {
        $script:ErrorCount = 0
        $script:Warnings = 0
        $script:NeedsReview = $false
        $script:LogFile = $null
        $script:stamp = 'test'
        $LogDir = $TestDrive
        $WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $AuPolicyKey = "$WuPolicyKey\AU"
        $idKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
        $RemoveWsusConfiguration = $false
        $ResetWsusClientIdentity = $false
        $ClearBitsQueue = $false
        Mock Invoke-Native { throw 'Unexpected native execution' }
        Mock Remove-ItemProperty {}
        Mock Rename-Item {}
        Mock Remove-Item {}
        Mock Start-Service {}
        Mock Stop-Service {}
        Mock Wait-ServiceState {}
        Mock Write-Information {}
        Mock Export-Clixml {}
        Mock New-Object { throw 'Unexpected COM/object creation' } -ParameterFilter { $ComObject }
    }

    It 'rejects a failed registry export before any deletion' {
        Mock Get-WsusValue { [pscustomobject]@{ Path=$WuPolicyKey; Name='WUServer'; Value='http://wsus' } }
        Mock Test-Path { $false }
        Mock Invoke-Native { 1 }
        { Remove-WsusValue } | Should -Throw
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly
    }
    It 'rejects a missing export even when reg returns zero' {
        Mock Get-WsusValue { [pscustomobject]@{ Path=$WuPolicyKey; Name='WUServer'; Value='http://wsus' } }
        Mock Test-Path { $false }
        Mock Invoke-Native { 0 }
        { Remove-WsusValue } | Should -Throw
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly
    }
    It 'rejects an empty export' {
        Mock Invoke-Native { 0 }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $PathType -eq 'Leaf' }
        Mock Get-Item { [pscustomobject]@{ Length=0 } }
        { Backup-Registry $WuPolicyKey 'policy' } | Should -Throw
    }
    It 'preserves unrelated policies and explicit public-source selections' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            [pscustomobject]@{ WUServer='http://wsus'; SetPolicyDrivenUpdateSourceForQualityUpdates=1;
                SetPolicyDrivenUpdateSourceForDriverUpdates=0; PauseFeatureUpdates=1; DeferQualityUpdatesPeriodInDays=7;
                NoAutoRebootWithLoggedOnUsers=1; ScheduledInstallDay=4 }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ UseWUServer=1; AUOptions=4; ScheduledInstallTime=3 } } -ParameterFilter { $LiteralPath -eq $AuPolicyKey }
        Mock Backup-Registry {}
        Remove-WsusValue
        Assert-MockCalled Backup-Registry -Times 1 -Exactly
        Assert-MockCalled Remove-ItemProperty -Times 3 -Exactly
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly -ParameterFilter { $Name -notin @('WUServer','UseWUServer','SetPolicyDrivenUpdateSourceForQualityUpdates') }
    }
    It 'does not infer WSUS from an unrelated policy key' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ PauseFeatureUpdates=1; AUOptions=4 } }
        @(Get-WsusValue).Count | Should -Be 0
    }
    It 'requires an identity export before deleting identity values' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ SusClientId='old' } }
        Mock Backup-Registry { throw 'backup failed' }
        { Reset-ClientIdentity } | Should -Throw
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly
    }
    It 'preserves policies, identity and BITS queues by default' {
        Mock Get-ServiceSnapshot { [pscustomobject]@{ Name='bits'; Status='Running' } }
        Mock Stop-RepairService {}
        Mock Restore-ServiceSnapshot {}
        Mock Rename-UpdateCache {}
        Mock Remove-WsusValue {}
        Mock Reset-ClientIdentity {}
        Mock Clear-LegacyBitsQueue {}
        Invoke-CacheRepair
        Assert-MockCalled Remove-WsusValue -Times 0 -Exactly
        Assert-MockCalled Reset-ClientIdentity -Times 0 -Exactly
        Assert-MockCalled Clear-LegacyBitsQueue -Times 0 -Exactly
        Assert-MockCalled Rename-UpdateCache -Times 1 -Exactly
        Assert-MockCalled Restore-ServiceSnapshot -Times 1 -Exactly
    }
    It 'blocks all dependent mutations when shutdown fails and still recovers' {
        $RemoveWsusConfiguration = $true
        $ResetWsusClientIdentity = $true
        $ClearBitsQueue = $true
        Mock Get-ServiceSnapshot { [pscustomobject]@{ Name='bits'; Status='Running' } }
        Mock Stop-RepairService { throw 'access denied' }
        Mock Restore-ServiceSnapshot {}
        Mock Rename-UpdateCache {}
        Mock Remove-WsusValue {}
        Mock Reset-ClientIdentity {}
        Mock Clear-LegacyBitsQueue {}
        { Invoke-CacheRepair } | Should -Throw
        Assert-MockCalled Rename-UpdateCache -Times 0 -Exactly
        Assert-MockCalled Remove-WsusValue -Times 0 -Exactly
        Assert-MockCalled Reset-ClientIdentity -Times 0 -Exactly
        Assert-MockCalled Clear-LegacyBitsQueue -Times 0 -Exactly
        Assert-MockCalled Restore-ServiceSnapshot -Times 1 -Exactly
    }
    It 'blocks renames when a service restarts unexpectedly' {
        Mock Get-Service { [pscustomobject]@{ Status='Running' } }
        { Rename-UpdateCache @([pscustomobject]@{ Name='bits' }) } | Should -Throw
        Assert-MockCalled Rename-Item -Times 0 -Exactly
    }
    It 'continues recovery after a failed restart and leaves stopped services stopped' {
        Mock Start-Service { throw 'restart failed' } -ParameterFilter { $Name -eq 'first' }
        Restore-ServiceSnapshot @(
            [pscustomobject]@{ Name='first'; Status='Running' },
            [pscustomobject]@{ Name='second'; Status='Running' },
            [pscustomobject]@{ Name='third'; Status='Stopped' })
        Assert-MockCalled Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'second' }
        Assert-MockCalled Start-Service -Times 0 -Exactly -ParameterFilter { $Name -eq 'third' }
        Assert-MockCalled Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'third' }
        $script:ErrorCount | Should -Be 1
    }
    It 'captures recursive dependents before Force can affect them' {
        Mock Get-Service { [pscustomobject]@{ Name='parent'; Status='Running'; DependentServices=@([pscustomobject]@{Name='child'}) } } -ParameterFilter { $Name -eq 'parent' }
        Mock Get-Service { [pscustomobject]@{ Name='child'; Status='Running'; DependentServices=@([pscustomobject]@{Name='grandchild'}) } } -ParameterFilter { $Name -eq 'child' }
        Mock Get-Service { [pscustomobject]@{ Name='grandchild'; Status='Stopped'; DependentServices=@() } } -ParameterFilter { $Name -eq 'grandchild' }
        $snapshot = @(Get-ServiceSnapshot @('parent'))
        $snapshot.Count | Should -Be 3
        $snapshot[2].Name | Should -Be 'grandchild'
        $snapshot[2].Status | Should -Be 'Stopped'
    }
    It 'WhatIf prevents all mutations, native commands, logging files and scans' {
        Mock Assert-Requirement {}
        Mock New-Item { throw 'must not create preview logs' }
        Mock Add-Content { throw 'must not write preview logs' }
        Mock Invoke-CacheRepair { throw 'must not repair' }
        Mock Invoke-DeepRepair { throw 'must not service' }
        Mock Invoke-UpdateSearch { throw 'must not scan' }
        $result = Invoke-TestWorkflow -WhatIf -RemoveWsusConfiguration -ResetWsusClientIdentity -ClearBitsQueue -ResetWinsock
        $result | Should -Be 0
        Assert-MockCalled Invoke-CacheRepair -Times 0 -Exactly
        Assert-MockCalled Invoke-DeepRepair -Times 0 -Exactly
        Assert-MockCalled Invoke-UpdateSearch -Times 0 -Exactly
        Assert-MockCalled Invoke-Native -Times 0 -Exactly
        Assert-MockCalled New-Item -Times 0 -Exactly
        Assert-MockCalled Add-Content -Times 0 -Exactly
        Assert-MockCalled Stop-Service -Times 0 -Exactly
        Assert-MockCalled Start-Service -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly
        Assert-MockCalled Remove-Item -Times 0 -Exactly
        Assert-MockCalled Rename-Item -Times 0 -Exactly
    }
    It 'does not treat SFC exit 1 as repaired' {
        Mock Invoke-Native { 0 } -ParameterFilter { $File -eq 'dism.exe' }
        Mock Invoke-Native { 1 } -ParameterFilter { $File -eq 'sfc.exe' }
        { Invoke-DeepRepair } | Should -Throw
        $script:NeedsReview | Should -Be $true
    }
    It 'skips SFC after DISM fails' {
        Mock Invoke-Native { 5 }
        { Invoke-DeepRepair } | Should -Throw
        Assert-MockCalled Invoke-Native -Times 0 -Exactly -ParameterFilter { $File -eq 'sfc.exe' }
    }
    It 'requires review for SFC exit zero as well' {
        Mock Invoke-Native { 0 }
        Invoke-DeepRepair
        $script:NeedsReview | Should -Be $true
    }
    It 'reports a partial COM search as incomplete' {
        $script:searchResultCode = 3
        Mock New-Object {
            $searcher = [pscustomobject]@{ Online=$false; ServerSelection=0 }
            $searcher | Add-Member ScriptMethod Search {
                param($Criteria)
                [pscustomobject]@{ ResultCode=$script:searchResultCode; Updates=[pscustomobject]@{ Count=2 } }
            }
            $session = [pscustomobject]@{ Searcher=$searcher }
            $session | Add-Member ScriptMethod CreateUpdateSearcher { $this.Searcher }
            return $session
        } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        { Invoke-UpdateSearch } | Should -Throw '*partially succeeded*'
        $script:searchResultCode = 4
        { Invoke-UpdateSearch } | Should -Throw '*failed/incomplete*'
        $script:searchResultCode = 2
        { Invoke-UpdateSearch } | Should -Not -Throw
    }
    It 'reports preflight failure as 2 and performs no repair' {
        Mock Assert-Requirement { throw 'not elevated' }
        Mock Invoke-CacheRepair {}
        Mock New-Item {}
        Invoke-TestWorkflow -Confirm:$false | Should -Be 2
        Assert-MockCalled Invoke-CacheRepair -Times 0 -Exactly
        Assert-MockCalled New-Item -Times 0 -Exactly
    }
    It 'blocks later commands and scan after a failed cache prerequisite' {
        Mock Assert-Requirement {}
        Mock New-Item {}
        Mock Add-Content {}
        Mock Invoke-CacheRepair { throw 'shutdown failed' }
        Mock Invoke-DeepRepair {}
        Mock Invoke-UpdateSearch {}
        Invoke-TestWorkflow -Confirm:$false -ResetWinsock | Should -Be 1
        Assert-MockCalled Invoke-Native -Times 0 -Exactly
        Assert-MockCalled Invoke-DeepRepair -Times 0 -Exactly
        Assert-MockCalled Invoke-UpdateSearch -Times 0 -Exactly
    }
    It 'SkipDeepRepair still repairs caches and searches, with no native repair' {
        Mock Assert-Requirement {}
        Mock New-Item {}
        Mock Add-Content {}
        Mock Invoke-CacheRepair {}
        Mock Get-ServiceSnapshot { [pscustomobject]@{ Name='bits'; Status='Running' } }
        Mock Restore-ServiceSnapshot {}
        Mock Invoke-DeepRepair {}
        Mock Invoke-UpdateSearch {}
        Invoke-TestWorkflow -Confirm:$false -SkipDeepRepair | Should -Be 0
        Assert-MockCalled Invoke-CacheRepair -Times 1 -Exactly
        Assert-MockCalled Invoke-UpdateSearch -Times 1 -Exactly
        Assert-MockCalled Invoke-DeepRepair -Times 0 -Exactly
        Assert-MockCalled Invoke-Native -Times 0 -Exactly
    }
    It 'returns 1 for netsh failure and blocks later steps' {
        Mock Assert-Requirement {}
        Mock New-Item {}
        Mock Add-Content {}
        Mock Invoke-CacheRepair {}
        Mock Invoke-Native { 5 }
        Mock Invoke-UpdateSearch {}
        Mock Invoke-DeepRepair {}
        Invoke-TestWorkflow -Confirm:$false -ResetWinsock | Should -Be 1
        Assert-MockCalled Invoke-DeepRepair -Times 0 -Exactly
        Assert-MockCalled Invoke-UpdateSearch -Times 0 -Exactly
    }
    It 'recovers services when cache rename fails' {
        Mock Get-ServiceSnapshot { [pscustomobject]@{ Name='bits'; Status='Running' } }
        Mock Stop-RepairService {}
        Mock Rename-UpdateCache { throw 'file locked' }
        Mock Restore-ServiceSnapshot {}
        { Invoke-CacheRepair } | Should -Throw
        Assert-MockCalled Restore-ServiceSnapshot -Times 1 -Exactly
    }

}


