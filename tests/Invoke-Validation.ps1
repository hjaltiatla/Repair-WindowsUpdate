#Requires -Version 5.1
# Validation only: never invokes the production repair entry point.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.7.1
Import-Module PSScriptAnalyzer -MinimumVersion 1.24.0
$repo = Split-Path $PSScriptRoot -Parent
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -Recurse)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
$findings = @(Invoke-ScriptAnalyzer -Path (Join-Path $repo 'Repair-WindowsUpdate.ps1'))
if ($findings.Count) { $findings | Format-Table -AutoSize; throw 'PSScriptAnalyzer findings require review.' }
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'Repair-WindowsUpdate.Tests.ps1'
$config.Run.PassThru = $true
# Tests use mocks only; do not create Pester's optional HKCU registry sandbox.
$config.TestRegistry.Enabled = $false
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { exit 1 }
exit 0
