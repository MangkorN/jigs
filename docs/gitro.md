# gitro

Runs read-only git commands from a fixed menu. `gitro serve` answers them through a shared folder, so a program without access to the repository, such as an AI agent in a sandbox, can still inspect it.

```bash
gitro [-C <repo>] <command> [<flag>...] [<arg>...] [-- <path>...]
gitro serve [-i <seconds>] [-k] [-n <name>] <repo> <dir>
gitro list [<root>]
gitro ui [start | stop | status] [<option>...]
gitro help [<command> | serve]
```

The menu covers status, diffs, history, blame, search, branches, tags, refs, stashes and more. `gitro` with no arguments lists it, and `gitro help <command>` shows a command's usage and allowed flags.

Each command maps to one git subcommand and accepts only the flags on its allow-list, so it can't change the repository, read files outside it or start another program:

- Flags that write files, run external programs or reach outside the repository (`--output`, `--ext-diff`, `--no-index`, `grep -f`, `blame --contents`, ...) are on no list. Write actions such as `branch -d` can't be expressed either, and `branch` and `tag` always run with `--list`.
- Arguments before `--` can't start with `-`, so they can't pass options. Everything after `--` is a path.
- `diff` refuses names outside the working tree, before or after `--`. Given two names and one of them outside, `git diff` would compare the files on disk instead, as if given `--no-index`.
- git starts no pager, external diff, textconv converter, file-watcher hook (`core.fsmonitor`) or signature check, even if the repository's config sets one. `--format` and `--pretty` refuse signature placeholders (`%G?`, ...), which start gpg, and `range-diff` is refused while a textconv converter is configured, since it runs it despite `--no-textconv`.
- The repository's clean filters, such as Git LFS's, still run, since git needs them to read working-tree files.
- Commands run against a temporary copy of the index, since `git status` and `git diff` otherwise refresh it and write it back.
- `remote` hides any credentials embedded in remote URLs.

`tests/gitro-test.sh` checks these against a repository set up to start a program wherever git would.

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

## Serving other processes

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
gitro serve -n backend /d/Repos/MyProject /d/Exchange/myproject
gitro list /d/Exchange    # the servers answering in /d/Exchange and the folders under it
```

## Connecting a caller

A caller is anything that can write and read files in the request folder: an AI agent in a sandbox, a tool in a VM or container,
a script running under another account. It needs no git, no access to the repository and nothing installed.

**What a caller can see:** whatever the allow-listed commands show about the repository, such as its files, history, diffs,
branches and tags. **What it can't do:** change anything, run anything but gitro's commands, or read outside the repository.
So serve only repositories the caller may read.

To connect one:

1. **Pick a request folder the caller can reach:** for an agent on your machine, a folder it's allowed to work in; for a VM or container,
   a shared or mounted folder. Keep it outside the repository, since the caller needs only this folder.
2. **Start a server** for the repository and that folder, in a terminal or on the Run page (`gitro ui`):

   ```bash
   gitro serve -k /d/Repos/MyProject /d/Exchange/myproject
   ```

   `-k` keeps a copy of each response for an hour, so you can see what the caller got as well as what it asked.
3. **Tell the caller where the folder is.** It learns the rest from the folder: `gitro-server.json` names the repository being served,
   and a `help serve` request answers with the protocol. To an agent, for instance:

   > This project's git repository is served read-only through gitro in `/mnt/exchange/myproject`, a folder you can write to.
   > You have no access to the repository itself. To run a gitro command, write its arguments, one per line, to a new file in that folder,
   > rename the file so its name ends in `.req`, then wait for the file with the same name ending in `.out`, read it and delete it.
   > Start with `help serve`, then `help`, then `status --short --branch`.

   Give the folder's path as the caller sees it: `D:\Exchange\myproject` on Windows can be `/mnt/d/Exchange/myproject` in WSL,
   or wherever a container mounts it.
4. **Watch the requests.** The server's terminal logs one line per request, and the Run page shows each request with its response.

A caller that can see several request folders, such as `/mnt/exchange`, finds a repository's server by reading each folder's
`gitro-server.json`. A server that isn't running answers nothing, so a caller should give up after a while and say so rather than wait.

### A caller in a few lines

A caller that runs scripts can keep one of these as a helper. Each sends one request, waits up to 20 seconds and returns the response,
whose first line is `# gitro exit=<code>: <request>`.

```bash
# gitro_ask <folder> <command> [<arg>...]
gitro_ask() {
    local dir=$1 name=req-$$-$RANDOM i
    shift
    printf '%s\n' "$@" > "$dir/$name.tmp" && mv "$dir/$name.tmp" "$dir/$name.req" || return
    for (( i = 0; i < 100; i++ )); do
        if [[ -f $dir/$name.out ]]; then
            cat "$dir/$name.out" && rm -f "$dir/$name.out"
            return
        fi
        sleep 0.2
    done
    rm -f "$dir/$name.req"
    echo "no answer: is gitro serve running for $dir?" >&2
    return 1
}
```

```python
import os, time, uuid

def gitro_ask(folder, *args):
    """gitro_ask('/mnt/exchange/myproject', 'log', '--oneline', '-5')"""
    name = os.path.join(folder, 'req-' + uuid.uuid4().hex)
    with open(name + '.tmp', 'w', encoding='utf-8', newline='\n') as request:
        request.write('\n'.join(args) + '\n')
    os.replace(name + '.tmp', name + '.req')
    for _ in range(100):
        if os.path.exists(name + '.out'):
            with open(name + '.out', encoding='utf-8', errors='replace') as response:
                text = response.read()
            os.remove(name + '.out')
            return text
        time.sleep(0.2)
    raise TimeoutError('no answer: is gitro serve running for %s?' % folder)
```

```powershell
# Invoke-Gitro D:\Exchange\myproject log, --oneline, -5
function Invoke-Gitro([string]$Folder, [string[]]$Arguments) {
    $name = Join-Path $Folder ('req-' + [guid]::NewGuid().ToString('N'))
    # UTF-8 without a byte order mark, which gitro would read as part of the command.
    [IO.File]::WriteAllText("$name.tmp", ($Arguments -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath "$name.tmp" -Destination "$name.req"
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path -LiteralPath "$name.out") {
            $text = [IO.File]::ReadAllText("$name.out")
            Remove-Item -LiteralPath "$name.out"
            return $text
        }
        Start-Sleep -Milliseconds 200
    }
    throw "No answer: is gitro serve running for $Folder?"
}
```

## Browser UI

```bash
gitro ui                  # starts the companion in the background and opens the Run page from this clone
gitro ui -o hosted        # opens the hosted copy of the site instead
gitro ui -p 47300         # listens on another port (47210 by default)
gitro ui -f               # runs in this terminal instead, where Ctrl+C stops it
gitro ui status           # whether it runs, and its servers
gitro ui stop             # stops it and every server it started
```

`gitro ui` starts a small companion process in the background and opens the jigs site's Run page, `site/run/index.html`. The terminal can be closed afterwards; running `gitro ui` again reopens the page. The companion is `powershell/gitro-ui.ps1` on Windows and `python/gitro-ui.py` on macOS and Linux (Python 3.8 or newer). On the Run page you can:

- pick a repository and a request folder with the system's folder dialog, or type a path and choose from its subfolders
- start, restart and stop servers, several at once, each running as `gitro serve -k`
- watch requests arrive with their responses, and send your own

Stopping the companion, from the page or with `gitro ui stop`, stops every server it started.

The page works without the companion: it then says gitro ui isn't running and offers a demo built from real gitro answers. While the companion runs, it writes its port and a random token to `.gitro-ui/session.js` in the clone, which ignores itself in git. The page reads that file every two seconds, so it connects by itself when the companion starts and notices when it stops. The companion's log is in the same folder.

The companion listens on 127.0.0.1 only, and answers only calls that carry its token, from pages opened from a file or from the hosted site. The hosted page can't read your files, so `gitro ui -o hosted` opens it with the token in the link; reaching your machine from there also needs the browser's one-time permission to access apps and services on your device. `gitro ui -h` lists the options.

To check a companion end to end, start `gitro ui` and run `python tests/gitro-ui-test.py`, which finds it through the session file. On macOS and Linux, `python3 tests/gitro-ui-test.py --launch` also tests starting and stopping it.
