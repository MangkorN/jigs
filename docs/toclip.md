# toclip

Runs a command and copies its output to the clipboard.

```bash
toclip <command> [args...]
```

UTF-8 safe, via `/dev/clipboard`. If the command fails, the clipboard is left untouched.

## Why not `clip.exe`

Windows' own `clip.exe` takes piped output too (`git log --oneline -5 | clip`), with three differences:

- **It garbles anything beyond ASCII.** `clip.exe` reads piped bytes in a legacy Windows code page rather than as UTF-8, so accented letters,
  CJK text, emoji and box-drawing characters in a command's UTF-8 output paste as mojibake: `é` becomes `Ã©` or `├⌐`, depending on the code page.
  `toclip` writes through Git Bash's `/dev/clipboard`, which turns the UTF-8 text into Windows' Unicode clipboard format.
- **It copies even when the command fails.** In `command | clip`, `clip.exe` runs regardless, so a failed or interrupted command replaces the
  clipboard with partial or empty output, and the pipeline reports `clip.exe`'s success. `toclip` copies only when the command succeeds;
  otherwise it leaves the clipboard as it was and returns the command's own exit code.
- **It says nothing.** `toclip` reports what it copied, such as `git: copied 12 lines to clipboard`, on stderr.
