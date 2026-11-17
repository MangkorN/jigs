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
    gitro.sh          read-only git commands from a fixed menu, also served to other processes
    lsf.sh            sorted list of files under a directory (lsfc: to clipboard)
    toclip.sh         copy any command's output to the clipboard
powershell/
  gitro-ui.ps1        browser UI companion for gitro serve on Windows (started by gitro ui)
  vs-tabs.ps1         save/restore Visual Studio tab layouts by name
python/
  gitro-ui.py         the same companion for macOS and Linux
docs/                 one page per tool, which the README's tool list and the site are generated from
site/                 the jigs site: open site/index.html in a browser, no server needed
tests/
  gitro-ui-test.py    end-to-end test of a gitro ui companion
examples/
  pq-tabs/            per-project wrapper for vs-tabs.ps1 (copy into a project)
```

## Install

### Bash (Git Bash)

Clone the repo, then add a line to `~/.bashrc` that loads it (the file is created if it doesn't exist):

```bash
echo 'source /d/Repos/jigs/bash/bashrc' >> ~/.bashrc
```

If `~/.bashrc` already defines any of the same functions or aliases, remove those copies. Otherwise whichever definition comes last wins.

New terminals pick everything up automatically. For an already open terminal, run `source ~/.bashrc`. To confirm the functions loaded (optional): `type csbundle csapply gdm`.

New tools go in `bash/functions/` as `*.sh` files and are picked up the same way. They must use LF line endings, since bash fails on CRLF.

(Optional) Default target for `csapply`:

```bash
echo 'export CSAPPLY_TARGET=/d/Repos/MyProject/Assets' >> ~/.bashrc
```

### PowerShell

Set `JIGS_DIR` as a Windows user environment variable, then restart any open terminals and Visual Studio:

```powershell
[Environment]::SetEnvironmentVariable('JIGS_DIR', 'D:\Repos\jigs', 'User')
```

`vs-tabs.ps1` can be run directly from `powershell/`, but the intended use is a small [per-project wrapper](docs/vs-tabs.md#per-project-wrapper).

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

Each tool has a page in [docs/](docs/) with its usage and details.

<!-- tools:start: written by site/data/make-docs.py from docs/, so edit those pages, then run it -->
- **[lsf](docs/lsf.md):** Lists every file under a folder as sorted relative paths, leaving out Unity's `.meta` files.
- **[catcs](docs/catcs.md):** Prints every `.cs` file in a folder, without its subfolders, with any UTF-8 byte order mark stripped.
- **[toclip](docs/toclip.md):** Runs a command and copies its output to the clipboard.
- **[csbundle](docs/csbundle.md):** Bundles the `.cs` files of a source tree into one text file per folder, named by the folder's relative path.
- **[csapply](docs/csapply.md):** Overwrites files in a project with same-named files from a flat folder, keeping their Unity `.meta` files, byte order marks and line endings.
- **[gdm](docs/gdm.md):** `git diff` showing only added/removed lines, with file headers but no context lines or hunk headers.
- **[gitro](docs/gitro.md):** Read-only git commands from a fixed menu. `gitro serve` answers them for other processes through a folder, so a caller, such as a tool in a sandbox, can inspect a repository with no access to it.
- **[vs-tabs](docs/vs-tabs.md):** A PowerShell script that saves and restores Visual Studio 2022 (17.9+) document tab layouts by name.
<!-- tools:end -->
