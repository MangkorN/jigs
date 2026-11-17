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
csbundle [-p prefix] [-o outdir] [-d depth] [-n] [srcdir]
```

Concatenates the `.cs` files of each directory under `srcdir` into one `.txt` per directory, named by relative path (`Root.txt`, `Root_Drivers.txt`, `Root_Settings_SubSettings.txt`, ...). Output defaults to `~/cs_bundles/<srcdir name>/`. Each file is preceded by a `// ===== path =====` header unless `-n` is given.

With `-d N`, directories at depth N (srcdir is 0) also absorb everything beneath them, which caps the number of bundles. `-d 0` produces a single file.

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

### gitro

```bash
gitro [-C <repo>] <command> [<flag>...] [<arg>...] [-- <path>...]
gitro serve [-i <seconds>] [-k] [-n <name>] <repo> <dir>
gitro list [<root>]
gitro ui [start | stop | status] [<option>...]
gitro help [<command> | serve]
```

Read-only git commands from a fixed menu: status, diffs, history, blame, search, branches, tags, refs, stashes and more. Run `gitro` with no arguments for the full list, and `gitro help <command>` for a command's usage and allowed flags.

Each command maps to one git subcommand and accepts only the flags on its allow-list, so nothing it runs can change the repository or read files outside it:

- Flags that write files, run external programs or reach outside the repository (`--output`, `--ext-diff`, `--no-index`, `grep -f`, `blame --contents`, ...) are on no list. Write actions such as `branch -d` can't be expressed either, and `branch` and `tag` always run with `--list`.
- Arguments before `--` can't start with `-`, so they can't pass options. Everything after `--` is a path.
- Commands run against a temporary copy of the index, since `git status` and `git diff` otherwise refresh it and write it back.
- `remote` hides any credentials embedded in remote URLs.

Flags that take a value are written as one argument (`-n5`, `--format=%h %s`). A cluster of single-letter flags works when each letter is allowed on its own (`shortlog -sn`).

Output goes to the terminal, so it can be redirected or piped like any command's:

```bash
gitro status --short --branch
gitro diff --cached --stat -- src
gitro log --oneline -10
gitro show HEAD~2:README.md
gitro -C /d/Repos/MyProject rev-list --count --left-right main...@{upstream}   # another repository
gitro -C /d/Repos/MyProject status > /d/Temp/status.txt                        # to a file
toclip gitro diff --cached --stat                                              # to the clipboard
```

`gitro.sh` also runs as a script, so programs that don't load the bashrc, such as PowerShell or a scheduled task, can call it through Git's bash. Windows paths work in this form:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' D:\Repos\jigs\bash\functions\gitro.sh -C D:\Repos\MyProject status
```

#### Serving other processes

`gitro serve` lets another process inspect a repository with no access to it, such as a tool in a VM or container that can only reach a shared folder. It watches `<dir>` and answers each request that appears there, until stopped with Ctrl+C:

1. The caller writes a request with one argument per line, the command first, under a temporary name, then renames it to `<name>.req`.
2. gitro runs it and writes `<name>.out`: a `# gitro exit=<code>: <request>` line, followed by the command's output and errors.
3. Requests are removed once taken, and responses after an hour.

```bash
gitro serve /d/Repos/MyProject /d/Exchange/myproject
gitro serve -k /d/Repos/MyProject /d/Exchange/myproject   # also keep a copy of each response
```

With `-k`, the server also keeps a copy of each response in `<dir>/kept/` for an hour, so you can look back at what was asked and answered after the caller has removed its response.

The server's terminal only logs one line per request and doesn't read typed input. To run commands yourself, use `gitro` directly in another terminal. To try the protocol by hand, write a request from another terminal:

```bash
printf '%s\n' status --short > /d/Exchange/myproject/t1.tmp
mv /d/Exchange/myproject/t1.tmp /d/Exchange/myproject/t1.req
sleep 1; cat /d/Exchange/myproject/t1.out
```

A `help serve` request returns these steps, so a caller can learn the protocol through the folder itself. Each server answers for one repository. To serve several, run one per repository, each with its own folder.

While it runs, a server keeps `<dir>/gitro-server.json` up to date: its name, repository, host, process id, start time, and the time it last refreshed the file, every 10 seconds. A caller that can see several request folders reads these to find the one serving the repository it wants. The name is the repository's folder name unless `-n` gives another. One folder has one server: `gitro serve` refuses a folder whose server is still running, and removes the file when it stops. A file left behind by a server that was killed counts as stale once its process is gone, or after a minute without a refresh.

```bash
gitro serve -n piquest /d/Repos/PiQuest-Unity /d/Exchange/piquest
gitro list /d/Exchange    # the servers answering in /d/Exchange and the folders under it
```

#### Browser UI

```bash
gitro ui                  # starts the companion in the background and opens the Run page from this clone
gitro ui -o hosted        # opens the hosted copy of the site instead
gitro ui -p 47300         # listens on another port (47210 by default)
gitro ui -f               # runs in this terminal instead, where Ctrl+C stops it
gitro ui status           # whether it runs, and its servers
gitro ui stop             # stops it and every server it started
```

`gitro ui` starts a small companion process in the background and opens the Run page of the jigs site, `site/run/index.html`. The terminal can be closed afterwards. Run it again and it opens the page for the companion already running. The companion is `powershell/gitro-ui.ps1` on Windows and `python/gitro-ui.py` on macOS and Linux, which needs Python 3.8 or newer. On the page you can pick a repository and a request folder with the system's folder dialog, or type a path and pick from its folders as you type, start, restart and stop servers (several at once), watch requests arrive with their full responses, and send requests yourself. Each server runs as `gitro serve -k`. Stopping the companion, from the page or with `gitro ui stop`, stops every server it started.

The page doesn't depend on the companion: without it, the page says gitro ui isn't running, and offers a demo built from real gitro answers. While the companion runs, it writes its port and a random token to `.gitro-ui/session.js` in the clone, which ignores itself in git. The page reads that file every two seconds, so it connects by itself when the companion starts and notices when it stops. The companion's log is in the same folder.

The companion listens on 127.0.0.1 only, and answers only pages opened from a file and the hosted site, and only calls that carry its token. The hosted page can't read your files, so `gitro ui -o hosted` opens it with the token in the link; reaching your machine from there also needs the browser's one-time permission to access apps and services on your device. `gitro ui -h` lists the options.

To check a companion end to end, start `gitro ui` and run `python tests/gitro-ui-test.py`, which finds it through the session file. On macOS and Linux, `python3 tests/gitro-ui-test.py --launch` also tests starting and stopping it.

### vs-tabs (PowerShell)

Saves and restores Visual Studio 2022 (17.9+) document tab layouts by name. Actions are `save`, `load`, `list`, `view` (read-only), and `help` (the default). Action and snapshot name are positional, so `.\vs-tabs.ps1 save my-layout` is the same as `.\vs-tabs.ps1 -Action Save -Name my-layout`. Run `vs-tabs.ps1` with no arguments for full help.

#### Per-project wrapper

`examples/pq-tabs/` is a wrapper that fills in the solution path for one project. To use it in a project:

1. Copy `pq-tabs.ps1` and `.gitignore` into a folder one level below the project root (the folder containing the `.sln`), e.g. `<ProjectRoot>/VSTabs/`. Rename the script as you like.
2. Make sure `JIGS_DIR` is set (see Install).
3. From that folder: `.\pq-tabs.ps1 save my-layout`
4. (Optional) Add a `pqt` alias to your PowerShell profile so the wrapper runs from any directory:

   ```powershell
   if (-not (Test-Path $PROFILE)) { New-Item $PROFILE -Force | Out-Null }; Add-Content $PROFILE 'Set-Alias pqt D:\Repos\MyProject\VSTabs\pq-tabs.ps1'
   ```

   - `$PROFILE` is the path of the script PowerShell runs at the start of every session (each PowerShell version has its own).
   - `if (-not (Test-Path $PROFILE)) { New-Item $PROFILE -Force | Out-Null }` creates that file, and its folder, only if it doesn't exist yet, so an existing profile is never overwritten.
   - `Add-Content` appends the `Set-Alias` line to the profile, so every new session defines the alias.

   New windows pick it up automatically. For an already open window, run `. $PROFILE`.

   Then `pqt`, `pqt list`, `pqt view`, `pqt view my-layout`, `pqt save my-layout` and `pqt load my-layout` all work, and snapshot names tab-complete from the wrapper's folder regardless of the current directory.

Snapshots are saved as `.json` next to the wrapper and ignored by its `.gitignore`.
