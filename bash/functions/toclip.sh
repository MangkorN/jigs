# toclip: runs a command and copies its output to the clipboard, leaving the clipboard alone if the command fails.
#   toclip git log --oneline -5
toclip()
{
    (( $# )) || { echo "usage: toclip <command> [<args>...]" >&2; return 2; }
    if [[ $1 == -h || $1 == --help ]]; then
        cat <<'USAGE'
usage: toclip <command> [<args>...]

Run <command> and copy its output to the clipboard as Unicode text. If the
command fails, the clipboard is left as it was and the command's exit code is
returned.

example
   toclip git log --oneline -5
USAGE
        return 0
    fi
    local out
    out=$("$@") || return
    printf '%s\n' "$out" > /dev/clipboard
    echo "$1: copied $(wc -l <<< "$out") lines to clipboard" >&2
}
