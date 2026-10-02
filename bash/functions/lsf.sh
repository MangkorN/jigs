# lsf: sorted list of every file under a directory (default: .) as relative paths,
# excluding .meta files. lsfc copies the list to the clipboard instead.
lsf()
{
    ( cd -- "${1:-.}" && find . -type f ! -name '*.meta' | sed 's|^\./||' | sort )
}

lsfc() { toclip lsf "$@"; }
