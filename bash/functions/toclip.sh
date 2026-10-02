# toclip: runs a command and copies its output to the clipboard.
# If the command fails, the clipboard is left untouched.
#   toclip git log --oneline -5
toclip()
{
    local out
    out=$("$@") || return
    printf '%s\n' "$out" > /dev/clipboard
    echo "$1: copied $(wc -l <<< "$out") lines to clipboard" >&2
}
