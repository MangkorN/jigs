# catcs: prints every .cs file in a directory (default: .), non-recursive,
# each followed by a blank line, with any UTF-8 BOM stripped.
# catcsc copies the output to the clipboard instead.
catcs()
{
    local f files=("${1:-.}"/*.cs)
    [[ -e ${files[0]} ]] || { echo "catcs: no .cs files in ${1:-.}" >&2; return 1; }
    for f in "${files[@]}"; do
        LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$f"
        echo
    done
}

catcsc() { toclip catcs "$@"; }
