<#
.SYNOPSIS
    Wrapper around vs-tabs.ps1 that finds the project's solution one folder up,
    so it doesn't need to be given. Copy it into a folder below the project root
    and rename it as you like. Snapshots are stored in this script's folder
    unless -LayoutsDir is given.

    Requires the JIGS_DIR environment variable to point at the jigs clone.
    If PowerShell refuses to run this script, see "Execution policy" in the
    jigs README: https://github.com/MangkorN/jigs#execution-policy

.EXAMPLE
    .\pq-tabs.ps1
.EXAMPLE
    .\pq-tabs.ps1 -Action Save -Name combat-refactor
.EXAMPLE
    .\pq-tabs.ps1 -Action Load -Name combat-refactor
.EXAMPLE
    .\pq-tabs.ps1 -Action View -Name combat-refactor
.EXAMPLE
    # Positional form, via a profile alias (Set-Alias pqt <path>\pq-tabs.ps1)
    pqt load combat-refactor
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Save', 'Load', 'List', 'View', 'Help')]
    [string]$Action = 'Help',

    [Parameter(Position = 1)]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        # Same resolution as vs-tabs.ps1's completer, see its comment.
        $dir = $fakeBoundParameters['LayoutsDir']
        if (-not $dir) {
            $typed = $commandAst.GetCommandName()
            $cmd = if ($typed) { Get-Command $typed -ErrorAction SilentlyContinue }
            while ($cmd -is [System.Management.Automation.AliasInfo]) { $cmd = $cmd.ResolvedCommand }
            $dir = if ($cmd.Path) { Split-Path $cmd.Path -Parent } else { $PWD.Path }
        }
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

# One level above this folder is the project root, where the .sln lives. vs-tabs.ps1 finds it there,
# and shows its help without needing one.
& (Join-Path $env:JIGS_DIR 'powershell\vs-tabs.ps1') `
    -Action $Action -Name $Name -SolutionDir (Split-Path $PSScriptRoot -Parent) `
    -LayoutsDir $LayoutsDir
