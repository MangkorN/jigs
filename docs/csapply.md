# csapply

Overwrites files in a project with same-named files from a flat folder, keeping their Unity `.meta` files, byte order marks and line endings.

```bash
csapply [-a] [-n] [-y] [-r] [<target>] [<srcdir>]
```

Overwrites files under `<target>` (default: `$CSAPPLY_TARGET`) with same-named files from the flat folder `<srcdir>` (default: `.`). Prints a plan and asks for confirmation before writing.

- Matches by exact file name (case-insensitive). Files with no match or more than one match are reported and skipped.
- Overwrites contents in place and never touches `.meta` files, so Unity GUIDs are preserved.
- Adopts the target file's BOM and line endings, unless `-r` is given.
- Marks targets with no git backup: uncommitted changes, untracked, or outside a repository.
- `-n` dry run, `-y` skip confirmation, `-a` all file types instead of only `.cs`.
