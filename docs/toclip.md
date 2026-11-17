# toclip

Runs a command and copies its output to the clipboard.

```bash
toclip <command> [args...]
```

UTF-8 safe, via `/dev/clipboard`. If the command fails, the clipboard is left untouched.
