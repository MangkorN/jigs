# vs-tabs

Saves and restores Visual Studio 2022 (17.9+) document tab layouts by name.

Actions are `save`, `load`, `list`, `view` (read-only), and `help` (the default). Action and snapshot name are positional, so `.\vs-tabs.ps1 save my-layout` is the same as `.\vs-tabs.ps1 -Action Save -Name my-layout`. Run `vs-tabs.ps1` with no arguments for full help.

## Per-project wrapper

`examples/project-tabs/` is a wrapper that fills in the solution path for one project. To use it in a project:

1. Copy `project-tabs.ps1` and `.gitignore` into a folder one level below the project root (the folder containing the `.sln`), e.g. `<ProjectRoot>/VSTabs/`. Rename the script as you like.
2. Make sure `JIGS_DIR` is set (see [Install](../README.md#powershell)).
3. From that folder: `.\project-tabs.ps1 save my-layout`
4. (Optional) Add a `pt` alias to your PowerShell profile so the wrapper runs from any directory:

   ```powershell
   if (-not (Test-Path $PROFILE)) { New-Item $PROFILE -Force | Out-Null }; Add-Content $PROFILE 'Set-Alias pt D:\Repos\MyProject\VSTabs\project-tabs.ps1'
   ```

   - `$PROFILE` is the path of the script PowerShell runs at the start of every session (each PowerShell version has its own).
   - `if (-not (Test-Path $PROFILE)) { New-Item $PROFILE -Force | Out-Null }` creates that file, and its folder, only if it doesn't exist yet, so an existing profile is never overwritten.
   - `Add-Content` appends the `Set-Alias` line to the profile, so every new session defines the alias.

   New windows pick it up. For an already open window, run `. $PROFILE`.

   Then `pt`, `pt list`, `pt view`, `pt view my-layout`, `pt save my-layout` and `pt load my-layout` all work, and snapshot names tab-complete from the wrapper's folder regardless of the current directory.

Snapshots are saved as `.json` next to the wrapper and ignored by its `.gitignore`.
