# gitro

Read-only git commands from a fixed menu. `gitro serve` answers them for other processes through a folder, so a caller, such as a tool in a sandbox, can inspect a repository with no access to it.

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
gitro serve -n piquest /d/Repos/PiQuest-Unity /d/Exchange/piquest
gitro list /d/Exchange    # the servers answering in /d/Exchange and the folders under it
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

`gitro ui` starts a small companion process in the background and opens the Run page of the jigs site, `site/run/index.html`. The terminal can be closed afterwards. Run it again and it opens the page for the companion already running. The companion is `powershell/gitro-ui.ps1` on Windows and `python/gitro-ui.py` on macOS and Linux, which needs Python 3.8 or newer. On the page you can pick a repository and a request folder with the system's folder dialog, or type a path and pick from its folders as you type, start, restart and stop servers (several at once), watch requests arrive with their full responses, and send requests yourself. Each server runs as `gitro serve -k`. Stopping the companion, from the page or with `gitro ui stop`, stops every server it started.

The page doesn't depend on the companion: without it, the page says gitro ui isn't running, and offers a demo built from real gitro answers. While the companion runs, it writes its port and a random token to `.gitro-ui/session.js` in the clone, which ignores itself in git. The page reads that file every two seconds, so it connects by itself when the companion starts and notices when it stops. The companion's log is in the same folder.

The companion listens on 127.0.0.1 only, and answers only pages opened from a file and the hosted site, and only calls that carry its token. The hosted page can't read your files, so `gitro ui -o hosted` opens it with the token in the link; reaching your machine from there also needs the browser's one-time permission to access apps and services on your device. `gitro ui -h` lists the options.

To check a companion end to end, start `gitro ui` and run `python tests/gitro-ui-test.py`, which finds it through the session file. On macOS and Linux, `python3 tests/gitro-ui-test.py --launch` also tests starting and stopping it.
