# jigs

Small, purpose-built tools for repetitive dev tasks: bash functions for Git Bash, PowerShell scripts for Visual Studio, and a shared bashrc.

The [jigs site](https://mangkorn.github.io/jigs/) has a guide for each tool and a browser UI for running gitro servers.

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
  gitro-test.sh       test of what gitro refuses, and that it writes nothing and starts no other program
  gitro-ui-test.py    end-to-end test of a gitro ui companion
  make-docs-test.py   test of the generator that turns docs/ into the README's tool list and the site's pages
examples/
  project-tabs/       per-project wrapper for vs-tabs.ps1 (copy into a project)
```

## Install

### Bash (Git Bash)

Clone the repo, then add a line to `~/.bashrc` that loads it (the file is created if it doesn't exist):

```bash
echo 'source /d/Repos/jigs/bash/bashrc' >> ~/.bashrc
```

If `~/.bashrc` already defines any of the same functions or aliases, remove those copies. Otherwise whichever definition comes last wins.

New terminals pick everything up. For an already open terminal, run `source ~/.bashrc`. To confirm the functions loaded (optional): `type csbundle csapply gdm`.

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
powershell -ExecutionPolicy Bypass -File .\project-tabs.ps1 -Action List
```

**"is not digitally signed"**: the policy is fine, but this file carries Windows' downloaded-from-the-internet tag, which is added to files saved from a browser, chat, or email, or extracted from a downloaded zip with Explorer. Remove it per file:

```powershell
Unblock-File .\project-tabs.ps1
```

Files obtained through `git clone` never carry this tag.

## Tools

Each tool's usage and details are in [docs/](docs/) and on the [site](https://mangkorn.github.io/jigs/). After editing a page, run `python3 site/data/make-docs.py` to update this list and the site.

<!-- tools:start: written by site/data/make-docs.py from docs/, so edit those pages, then run it -->
- **[lsf](docs/lsf.md):** Lists every file under a folder as sorted relative paths, leaving out Unity's `.meta` files.
- **[catcs](docs/catcs.md):** Prints the contents of every `.cs` file in a folder (not its subfolders), with UTF-8 byte order marks stripped.
- **[toclip](docs/toclip.md):** Runs a command and copies its output to the clipboard.
- **[csbundle](docs/csbundle.md):** Bundles the `.cs` files of a source tree into one text file per folder, named by the folder's relative path.
- **[csapply](docs/csapply.md):** Overwrites files in a project with same-named files from a flat folder, keeping their Unity `.meta` files, byte order marks and line endings.
- **[gdm](docs/gdm.md):** Runs `git diff` showing only added and removed lines, with file headers but no context lines or hunk headers.
- **[gitro](docs/gitro.md):** Runs read-only git commands from a fixed menu. `gitro serve` answers them through a shared folder, so a program without access to the repository, such as an AI agent in a sandbox, can still inspect it.
- **[vs-tabs](docs/vs-tabs.md):** Saves and restores Visual Studio 2022 (17.9+) document tab layouts by name.
<!-- tools:end -->
