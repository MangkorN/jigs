<#
.SYNOPSIS
    Thin wrapper around vs-tabs.ps1 that fills in the solution location automatically
    for this repo, so you never have to pass it by hand.
    Snapshots are stored in this script's folder unless -LayoutsDir is given.

    Requires the JIGS_DIR environment variable to point at the jigs clone.
    If PowerShell refuses to run this script, see the "Execution policy"
    section of the jigs README: https://github.com/MangkorN/jigs#execution-policy

    The "pq-" prefix stands for PiQuest, the project this wrapper
    was originally written for.

.EXAMPLE
    .\pq-tabs.ps1
.EXAMPLE
    .\pq-tabs.ps1 -Action Save -Name combat-refactor
.EXAMPLE
    .\pq-tabs.ps1 -Action Load -Name combat-refactor
.EXAMPLE
    .\pq-tabs.ps1 -Action Preview -Name combat-refactor
#>

[CmdletBinding()]
param(
    [ValidateSet('Save', 'Load', 'List', 'Preview', 'Help')]
    [string]$Action = 'Help',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        # Same approximation as vs-tabs.ps1's completer - see its comment.
        $dir = if ($fakeBoundParameters['LayoutsDir']) { $fakeBoundParameters['LayoutsDir'] } else { $PWD.Path }
        if (-not (Test-Path $dir)) { return }
        Get-ChildItem -Path $dir -Filter "$wordToComplete*.json" -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $text = if ($_.BaseName -match '\s') { "'$($_.BaseName)'" } else { $_.BaseName }
                [System.Management.Automation.CompletionResult]::new($text, $_.BaseName, 'ParameterValue', $_.BaseName)
            }
    })]
    [string]$Name,

    [string]$LayoutsDir
)

if (-not $env:JIGS_DIR) {
    throw "JIGS_DIR is not set. Point it at your jigs clone (see the jigs README)."
}
if (-not $LayoutsDir) { $LayoutsDir = $PSScriptRoot }

# One level above this folder is the Unity project root, where the sln lives.
# No filesystem check or Help special-casing needed here - vs-tabs.ps1's own
# -SolutionDir lookup and its Help short-circuit already cover both.
& (Join-Path $env:JIGS_DIR 'powershell\vs-tabs.ps1') `
    -Action $Action -Name $Name -SolutionDir (Split-Path $PSScriptRoot -Parent) `
    -LayoutsDir $LayoutsDir
