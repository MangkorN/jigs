# lsf: lists every file under a directory as sorted relative paths, without Unity .meta files.
# lsfc copies the list to the clipboard.
lsf()
{
    if [[ $1 == -h || $1 == --help ]]; then
        cat <<'USAGE'
usage: lsf [<dir>]
   or: lsfc [<dir>]

List every file under <dir> (default: .) as sorted relative paths, without
Unity .meta files. lsfc copies the list to the clipboard.
USAGE
        return 0
    fi
    ( cd -- "${1:-.}" && find . -type f ! -name '*.meta' | sed 's|^\./||' | sort )
}

lsfc()
{
    [[ $1 == -h || $1 == --help ]] && { lsf "$1"; return; }
    toclip lsf "$@"
}
