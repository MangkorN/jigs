# toclip

Runs a command and copies its output to the clipboard.

```bash
toclip <command> [<args>...]
```

UTF-8 safe, via `/dev/clipboard`. If the command fails, the clipboard is left untouched.

## Why not `clip.exe`

Windows' `clip.exe` also takes piped output (`git log --oneline -5 | clip`), but differs in three ways:

- **Non-ASCII text:** `clip.exe` reads piped bytes in a legacy code page, not as UTF-8, so accented letters, CJK text, emoji and
  box-drawing characters paste as mojibake (`é` becomes `Ã©` or `├⌐`, depending on the code page). `toclip` writes through Git Bash's
  `/dev/clipboard`, which stores the text as Unicode.
- **Failed commands:** in `command | clip`, `clip.exe` runs regardless, so a failed or interrupted command replaces the clipboard with
  partial or empty output, and the pipeline reports success. `toclip` copies only if the command succeeds; otherwise it leaves the
  clipboard as it was and returns the command's exit code.
- **Feedback:** `toclip` prints what it copied on stderr, such as `git: copied 12 lines to clipboard`. `clip.exe` prints nothing.
