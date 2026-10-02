<#
.SYNOPSIS
    Save and restore Visual Studio 2022 (17.9+) document tab layouts by name,
    via the solution's DocumentLayout.json.

.PARAMETER Action
    Save, Load, List, Preview, or Help (default). Help prints common
    commands plus the execution-policy fix, with no solution required.
    Preview is read-only: bare, it shows the live DocumentLayout.json;
    with -Name, it shows a stored snapshot's contents without loading it.

.PARAMETER Name
    Snapshot name (required for Save/Load). Tab-completes against .json
    files in the layouts folder; bare name or full filename both work.

.PARAMETER SolutionPath
    Path to the .sln file. Auto-detected if omitted and exactly one .sln
    exists in the current directory (or in -SolutionDir, if given).

.PARAMETER SolutionDir
    Directory to search for a single .sln in, instead of the current
    directory. Ignored if -SolutionPath is given. Exists so wrapper scripts
    can point at a fixed directory without doing their own filesystem
    search (and duplicating this script's Help short-circuit) to do it.

.PARAMETER LayoutsDir
    Where named snapshots are stored. Defaults to the folder the script
    itself lives in.

.EXAMPLE
    .\vs-tabs.ps1 -Action Save -Name combat-refactor
.EXAMPLE
    .\vs-tabs.ps1 -Action Load -Name combat-refactor
.EXAMPLE
    .\vs-tabs.ps1 -Action List
.EXAMPLE
    # What Save would capture right now, without saving anything
    .\vs-tabs.ps1 -Action Preview
.EXAMPLE
    # What a stored snapshot contains, without loading it
    .\vs-tabs.ps1 -Action Preview -Name combat-refactor
.EXAMPLE
    # Not running from a folder with exactly one .sln (or it has more than one)
    .\vs-tabs.ps1 -Action Save -Name combat-refactor -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln
.EXAMPLE
    # Snapshots stored somewhere other than the script's own folder
    .\vs-tabs.ps1 -Action Load -Name combat-refactor -LayoutsDir D:\Shared\VSLayouts
.EXAMPLE
    # Both overrides combine independently
    .\vs-tabs.ps1 -Action List -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln -LayoutsDir D:\Shared\VSLayouts
#>

[CmdletBinding()]
param(
    [ValidateSet('Save', 'Load', 'List', 'Preview', 'Help')]
    [string]$Action = 'Help',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        # Can't reliably resolve the invoked script's own folder from inside
        # a completer, so this approximates Get-LayoutsDirectory's default
        # with $PWD instead - correct whenever run via ".\..." from that
        # folder (the normal case), and -LayoutsDir wins if already typed.
        $dir = if ($fakeBoundParameters['LayoutsDir']) { $fakeBoundParameters['LayoutsDir'] } else { $PWD.Path }
        if (-not (Test-Path $dir)) { return }
        Get-ChildItem -Path $dir -Filter "$wordToComplete*.json" -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $text = if ($_.BaseName -match '\s') { "'$($_.BaseName)'" } else { $_.BaseName }
                [System.Management.Automation.CompletionResult]::new($text, $_.BaseName, 'ParameterValue', $_.BaseName)
            }
    })]
    [string]$Name,

    [string]$SolutionPath,

    [string]$SolutionDir,

    [string]$LayoutsDir
)

$ErrorActionPreference = 'Stop'

function Show-Help {
    @"
vs-tabs.ps1 - save/restore named VS document-tab layouts (requires VS 17.9+)

COMMANDS

  .\vs-tabs.ps1                                     Show this help (default action)
  .\vs-tabs.ps1 -Action List
  .\vs-tabs.ps1 -Action Preview
  .\vs-tabs.ps1 -Action Preview -Name <snapshot-name>
  .\vs-tabs.ps1 -Action Save -Name <snapshot-name>
  .\vs-tabs.ps1 -Action Load -Name <snapshot-name>

  Add -SolutionPath <path\to.sln> if the current directory doesn't contain
  exactly one .sln. Add -LayoutsDir <path> to store/read snapshots somewhere
  other than the script's own folder (the default).

  Save and Load both only work correctly with VS fully closed - see the
  note at the end of this section before running either.

WHEN TO ADD -SolutionPath

  Needed if you're not running from a folder containing exactly one .sln -
  e.g. running from a subfolder, or the repo has more than one .sln.

    .\vs-tabs.ps1 -Action List -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln
    .\vs-tabs.ps1 -Action Save -Name combat-refactor -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln
    .\vs-tabs.ps1 -Action Load -Name combat-refactor -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln

  -SolutionDir <folder> is the same idea but searches a folder for a single
  .sln instead of naming the file directly - useful for wrapper scripts that
  know the folder but not the filename.

WHEN TO ADD -LayoutsDir

  Needed only if you want snapshots stored somewhere other than the script's
  own folder - e.g. a shared drive.

    .\vs-tabs.ps1 -Action Save -Name combat-refactor -LayoutsDir D:\Shared\VSLayouts
    .\vs-tabs.ps1 -Action Load -Name combat-refactor -LayoutsDir D:\Shared\VSLayouts
    .\vs-tabs.ps1 -Action List -LayoutsDir D:\Shared\VSLayouts

  The two combine independently - use both if you need them at once:

    .\vs-tabs.ps1 -Action Load -Name combat-refactor -SolutionPath D:\Repos\PiQuest-Unity\PiQuest.sln -LayoutsDir D:\Shared\VSLayouts

  VS MUST BE FULLY CLOSED for both Save and Load - not just the solution
  minimized or idle, actually exited:

  - Save only captures state as of the last time VS closed - opening or
    closing tabs does not flush it live, so if VS is still open, Save
    captures whatever was open the last time it was closed, not your
    current tabs. Close VS first if you need current tabs, then Save.

  - Load only takes effect if VS was already closed before you ran it. If
    VS is open when you run Load, VS still holds its old state in memory,
    and closing VS afterward makes VS write that old state back over what
    Load just applied - silently undoing it. Close VS first, then Load,
    then reopen VS to see the result.

EXECUTION POLICY

  Two distinct gates can block this script; check which error you're seeing.

  Scenario A: "running scripts is disabled on this system"
  All scripts are blocked outright. Check which scope is enforcing it:

    Get-ExecutionPolicy -List

  If MachinePolicy/UserPolicy show Undefined (no GPO lock), fix it once,
  no admin rights needed:

    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

  If MachinePolicy/UserPolicy are set by a GPO, that fix won't take. Bypass
  per-invocation instead:

    powershell -ExecutionPolicy Bypass -File .\vs-tabs.ps1 -Action List

  Scenario B: "is not digitally signed. You cannot run this script"
  RemoteSigned is already active and correctly enforced. This specific file
  carries a "downloaded from another computer" tag - Windows adds this to
  any file that arrives via a browser, email client, or file-sharing tool -
  and isn't signed, so it's blocked regardless of the policy already being
  RemoteSigned. Re-running Set-ExecutionPolicy won't fix this; strip the
  tag instead:

    Unblock-File .\vs-tabs.ps1

  This is a per-file flag, not a one-time global fix - it reappears on any
  fresh copy of the script obtained the same way.
"@ | Write-Host
}

if ($Action -eq 'Help') {
    Show-Help
    return
}

function Resolve-SolutionPath {
    param([string]$Path, [string]$SearchDir)
    if ($Path) { return (Resolve-Path $Path).Path }
    $searchIn = if ($SearchDir) { $SearchDir } else { '.' }
    $slns = Get-ChildItem -Path $searchIn -Filter *.sln -File
    if ($slns.Count -eq 1) { return $slns[0].FullName }
    if ($slns.Count -eq 0) { throw "No .sln found in '$searchIn'. Pass -SolutionPath or -SolutionDir." }
    throw "Multiple .sln files found in '$searchIn' ($($slns.Name -join ', ')). Pass -SolutionPath."
}

function Get-DocumentLayoutPath {
    param([string]$SolutionFile)
    $solutionDir  = Split-Path $SolutionFile -Parent
    $solutionName = [IO.Path]::GetFileNameWithoutExtension($SolutionFile)
    # "v17" names the VS2022 config-folder scheme regardless of update number.
    # DocumentLayout.json itself only exists on 17.9+; earlier updates store
    # this state in the binary .suo file in the same folder instead.
    $path = Join-Path $solutionDir ".vs\$solutionName\v17\DocumentLayout.json"
    if (-not (Test-Path $path)) {
        throw "DocumentLayout.json not found at '$path'. Requires VS 17.9+, and it's only " +
              "written once this solution has been opened in VS at least once."
    }
    return $path
}

function Get-LayoutsDirectory {
    # Defaults to the script's own folder (not a subfolder of it, and not
    # solution-relative) so co-locating the script and its snapshots in one
    # folder works with zero flags.
    param([string]$Override)
    if ($Override) { return $Override }
    return $PSScriptRoot
}

function Get-DocumentRows {
    # Cross-references the tab strip (Children, in on-screen order) against
    # the top-level Documents[] array via DocumentIndex, to get each open
    # tab's project name and pinned state. $null on any parse failure.
    param([string]$JsonPath)
    try {
        $json = Get-Content $JsonPath -Raw | ConvertFrom-Json
    } catch {
        return
    }
    if ($json.Version -ne 1) {
        Write-Warning "DocumentLayout.json reports Version $($json.Version), not the only version this script has been checked against (1) - grouping/pinned info may be wrong."
    }
    $docs = $json.Documents
    $json.DocumentGroupContainers.DocumentGroups.Children |
        Where-Object { $_.'$type' -eq 'Document' } |
        ForEach-Object {
            $moniker = $docs[$_.DocumentIndex].AbsoluteMoniker
            # Moniker shape: "<kind>|<project ref>.csproj|<file path>||<guid>" -
            # the project ref can carry a folder prefix, so take its last segment.
            $project = if ($moniker -match '\|([^|]+)\.csproj\|') {
                ($matches[1] -split '\\')[-1]
            } else { '(unknown project)' }
            [PSCustomObject]@{
                Project = $project
                Pinned  = [bool]$_.IsPinned
                Name    = $_.Title
            }
        }
}

function Format-DocumentSummary {
    # Pinned block first, then unpinned - each grouped by project in the
    # order projects first appear in the tab strip (not alphabetical), tab
    # order preserved within each group.
    param($Rows)
    if (-not $Rows) { return }
    $sections = @(
        @{ Set = @($Rows | Where-Object Pinned);            Suffix = ' (Pinned)' }
        @{ Set = @($Rows | Where-Object { -not $_.Pinned }); Suffix = '' }
    )
    foreach ($section in $sections) {
        if (-not $section.Set) { continue }
        $section.Set | Group-Object Project | ForEach-Object {
            "$($_.Name)$($section.Suffix)"
            $_.Group | ForEach-Object { "  $($_.Name)" }
        }
    }
}

function ConvertTo-SnapshotName {
    # Strips a directory prefix (from a tab-completed relative/absolute path)
    # and a literal trailing ".json" - but not just "whatever's after the
    # last dot", so a name like v1.2-combat-refactor survives unmangled.
    param([string]$Raw)
    if (-not $Raw) { return $Raw }
    $base = Split-Path $Raw -Leaf
    if ($base -like '*.json') { $base = $base.Substring(0, $base.Length - 5) }
    return $base
}

function Get-SnapshotPath {
    param([string]$Name, [string]$LayoutsDir)
    $path = Join-Path $LayoutsDir "$Name.json"
    if (-not (Test-Path $path)) {
        $available = if (Test-Path $LayoutsDir) {
            (Get-ChildItem $LayoutsDir -Filter *.json).BaseName -join ', '
        } else { '(none)' }
        throw "No snapshot named '$Name'. Available: $available"
    }
    return $path
}

$solutionFile = Resolve-SolutionPath -Path $SolutionPath -SearchDir $SolutionDir
$layoutPath   = Get-DocumentLayoutPath -SolutionFile $solutionFile
$layoutsDir   = Get-LayoutsDirectory -Override $LayoutsDir
$Name         = ConvertTo-SnapshotName -Raw $Name

switch ($Action) {

    'List' {
        if (-not (Test-Path $layoutsDir)) {
            Write-Host "No snapshots saved yet ($layoutsDir doesn't exist)."
            return
        }
        Get-ChildItem $layoutsDir -Filter *.json | ForEach-Object {
            [PSCustomObject]@{
                Name      = $_.BaseName
                Documents = @(Get-DocumentRows -JsonPath $_.FullName).Count
                SavedAt   = $_.LastWriteTime
            }
        } | Format-Table -AutoSize
    }

    'Preview' {
        # Read-only in both directions - never touches DocumentLayout.json
        # or any snapshot file. Bare, shows the live file (what Save would
        # capture right now); with -Name, shows a stored snapshot's contents
        # (what Load would apply) without actually loading it.
        $target = if ($Name) { Get-SnapshotPath -Name $Name -LayoutsDir $layoutsDir } else { $layoutPath }
        $label  = if ($Name) { "snapshot '$Name'" } else { 'the live DocumentLayout.json' }
        $rows   = @(Get-DocumentRows -JsonPath $target)
        Write-Host "$($rows.Count) documents in $label ($target)"
        if ($rows) { Write-Host (Format-DocumentSummary -Rows $rows | Out-String).TrimEnd() }
        if (-not $Name) {
            Write-Warning ("This reflects the last time VS was closed, not necessarily your " +
                            "current tabs - opening/closing tabs does not flush DocumentLayout.json live.")
        }
    }

    'Save' {
        # DocumentLayout.json is only rewritten when VS/the solution closes -
        # opening or closing individual tabs does NOT flush it live. So this
        # always captures state as of the last solution/VS close, never
        # "whatever's open right now" while a session is still running.
        if (-not $Name) { throw "-Name is required for Save." }
        New-Item -ItemType Directory -Path $layoutsDir -Force | Out-Null
        $dest = Join-Path $layoutsDir "$Name.json"
        Copy-Item $layoutPath $dest -Force
        $rows = @(Get-DocumentRows -JsonPath $dest)
        Write-Host "Saved '$Name' ($($rows.Count) documents) -> $dest"
        if ($rows) { Write-Host (Format-DocumentSummary -Rows $rows | Out-String).TrimEnd() }
        Write-Warning ("This reflects the last time VS was closed, not necessarily your current " +
                        "tabs. Make sure VS is fully closed before running Save if you need your " +
                        "current tabs captured, not stale ones.")
    }

    'Load' {
        if (-not $Name) { throw "-Name is required for Load." }
        $src = Get-SnapshotPath -Name $Name -LayoutsDir $layoutsDir

        Copy-Item $layoutPath "$layoutPath.bak" -Force -ErrorAction SilentlyContinue
        Copy-Item $src $layoutPath -Force
        $rows = @(Get-DocumentRows -JsonPath $src)
        Write-Host "Applied '$Name' -> $layoutPath ($($rows.Count) documents; previous state backed up as DocumentLayout.json.bak)"
        if ($rows) { Write-Host (Format-DocumentSummary -Rows $rows | Out-String).TrimEnd() }
        Write-Warning ("This only takes effect if VS was already fully closed before you ran " +
                        "Load - if it was still open, its own close-time write will silently " +
                        "overwrite what was just applied. Open VS now to see the applied layout.")
    }
}