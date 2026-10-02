# jigs

Small, purpose-built tools for repetitive dev tasks: bash functions for Git Bash, PowerShell scripts for Visual Studio, and a shared bashrc.

```
bash/
  bashrc              aliases; sources everything in functions/
  functions/
    catcs.sh          print .cs files in a directory (catcsc: to clipboard)
    csapply.sh        overwrite same-named files in a project from a flat folder
    csbundle.sh       bundle .cs files into one .txt per directory
    gdm.sh            git diff showing changed lines only
    lsf.sh            sorted list of files under a directory (lsfc: to clipboard)
    toclip.sh         copy any command's output to the clipboard
powershell/
  vs-tabs.ps1         save/restore Visual Studio tab layouts by name
examples/
  pq-tabs/            per-project wrapper for vs-tabs.ps1 (copy into a project)
```

## Install

### Bash (Git Bash)

Clone the repo, then add one line to `~/.bashrc` pointing at the clone:

```bash
source /d/Repos/jigs/bash/bashrc
```

If `~/.bashrc` already defines any of the same functions or aliases, remove those copies. Otherwise whichever definition comes last wins.

New terminals pick everything up automatically. For an already open terminal, run `source ~/.bashrc`. To confirm the functions loaded (optional): `type csbundle csapply gdm`.

New tools go in `bash/functions/` as `*.sh` files and are picked up the same way. They must use LF line endings, since bash fails on CRLF.

(Optional) Default target for `csapply`, added to `~/.bashrc` after the `source` line:

```bash
export CSAPPLY_TARGET=/d/Repos/MyProject/Assets
```

### PowerShell

Set `JIGS_DIR` as a Windows user environment variable, then restart any open terminals and Visual Studio:

```powershell
[Environment]::SetEnvironmentVariable('JIGS_DIR', 'D:\Repos\jigs', 'User')
```

`vs-tabs.ps1` can be run directly from `powershell/`, but the intended use is a small per-project wrapper (below).

#### Execution policy

If PowerShell refuses to run a script, the error message tells you which of two causes applies.

**"running scripts is disabled on this system"**: all scripts are blocked. Check which scope enforces it with `Get-ExecutionPolicy -List`. If MachinePolicy and UserPolicy are `Undefined`, fix it once (no admin rights needed):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

If they're set by Group Policy, that won't take effect. Bypass per run instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\pq-tabs.ps1 -Action List
```

**"is not digitally signed"**: the policy is fine, but this file carries Windows' downloaded-from-the-internet tag, which is added to files saved from a browser, chat, or email, or extracted from a downloaded zip with Explorer. Remove it per file:

```powershell
Unblock-File .\pq-tabs.ps1
```

Files obtained through `git clone` never carry this tag.

## Tools

### lsf / catcs

```bash
lsf [dir]       # sorted relative paths of all files under dir, excluding .meta
catcs [dir]     # contents of every .cs file in dir (non-recursive), BOMs stripped
```

`lsfc` and `catcsc` do the same and copy the result to the clipboard.

### toclip

```bash
toclip <command> [args...]
```

Runs a command and copies its output to the clipboard (UTF-8 safe, via `/dev/clipboard`). If the command fails, the clipboard is left untouched.

### csbundle

```bash
csbundle [-p prefix] [-o outdir] [-n] [srcdir]
```

Concatenates the `.cs` files of each directory under `srcdir` into one `.txt` per directory, named by relative path (`Root.txt`, `Root_Drivers.txt`, `Root_Settings_SubSettings.txt`, ...). Output defaults to `~/cs_bundles/<srcdir name>/`. Each file is preceded by a `// ===== path =====` header unless `-n` is given.

### csapply

```bash
csapply [-a] [-n] [-y] [-r] [target] [srcdir]
```

Overwrites files under `target` with same-named files from the flat folder `srcdir` (default: `.`). Prints a plan and asks for confirmation before writing.

- Matches by exact file name (case-insensitive). Files with no match or more than one match are reported and skipped.
- Overwrites contents in place and never touches `.meta` files, so Unity GUIDs are preserved.
- Adopts the target file's BOM and line endings, unless `-r` is given.
- Flags targets with uncommitted or untracked changes.
- `-n` dry run, `-y` skip confirmation, `-a` all file types instead of only `.cs`.

### gdm

```bash
gdm [git diff args]
```

`git diff` showing only added/removed lines, with file headers but no context lines or hunk headers.

### vs-tabs (PowerShell)

Saves and restores Visual Studio 2022 (17.9+) document tab layouts by name. Run `vs-tabs.ps1` with no arguments for full help.

#### Per-project wrapper

`examples/pq-tabs/` is a wrapper that fills in the solution path for one project. To use it in a project:

1. Copy `pq-tabs.ps1` and `.gitignore` into a folder one level below the project root (the folder containing the `.sln`), e.g. `<ProjectRoot>/VSTabs/`. Rename the script as you like.
2. Make sure `JIGS_DIR` is set (see Install).
3. From that folder: `.\pq-tabs.ps1 -Action Save -Name my-layout`

Snapshots are saved as `.json` next to the wrapper and ignored by its `.gitignore`.
