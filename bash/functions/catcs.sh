# catcs: prints every .cs file in a directory, not its subdirectories, with UTF-8 byte order marks removed.
# catcsc copies the output to the clipboard.
catcs()
{
    if [[ $1 == -h || $1 == --help ]]; then
        cat <<'USAGE'
usage: catcs [<dir>]
   or: catcsc [<dir>]

Print every .cs file in <dir> (default: .), not its subdirectories, each
followed by a blank line, with UTF-8 byte order marks removed. catcsc copies
the output to the clipboard.
USAGE
        return 0
    fi
    local f files=("${1:-.}"/*.cs)
    [[ -e ${files[0]} ]] || { echo "catcs: no .cs files in ${1:-.}" >&2; return 1; }
    for f in "${files[@]}"; do
        LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$f"
        echo
    done
}

catcsc()
{
    [[ $1 == -h || $1 == --help ]] && { catcs "$1"; return; }
    toclip catcs "$@"
}
