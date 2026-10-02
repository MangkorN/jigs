# csbundle: concatenates the .cs files of each directory under a source tree
# into one .txt per directory, named by relative path:
#   Root.txt, Root_Drivers.txt, Root_Settings_SubSettings.txt, ...
csbundle()
{
    local prefix="Root" out="" headers=1
    local opt OPTIND=1
    while getopts ":p:o:nh" opt; do
        case $opt in
            p) prefix=$OPTARG ;;
            o) out=$OPTARG ;;
            n) headers=0 ;;
            h) cat <<'USAGE'
usage: csbundle [-p prefix] [-o outdir] [-n] [srcdir]
  srcdir     root of the tree to bundle (default: .)
  -p prefix  name of the root bundle and prefix for the rest (default: Root)
  -o outdir  output directory (default: ~/cs_bundles/<srcdir name>)
  -n         omit the per-file path header comments
USAGE
               return 0 ;;
            :)  echo "csbundle: -$OPTARG needs an argument" >&2; return 2 ;;
            \?) echo "csbundle: unknown option -$OPTARG" >&2; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    local src
    src=$(cd -- "${1:-.}" 2>/dev/null && pwd) \
        || { echo "csbundle: not a directory: ${1:-.}" >&2; return 1; }
    out=${out:-$HOME/cs_bundles/${src##*/}}
    mkdir -p -- "$out" && out=$(cd -- "$out" && pwd) || return 1

    # Output inside the tree would get re-scanned, and inside Assets/ Unity would import it.
    case "$out/" in
        "$src"/*) echo "csbundle: output dir must not be inside the source tree" >&2; return 1 ;;
    esac

    # Clear bundles from a previous run so renamed/removed directories don't leave stale files.
    rm -f -- "$out/$prefix.txt" "$out/$prefix"_*.txt

    local dir rel name f n=0 total=0
    local -a files
    while IFS= read -r -d '' dir; do
        files=()
        while IFS= read -r -d '' f; do files+=("$f"); done \
            < <(find "$dir" -maxdepth 1 -type f -name '*.cs' -print0 | LC_ALL=C sort -z)
        (( ${#files[@]} )) || continue

        rel=${dir#"$src"}; rel=${rel#/}
        name=$prefix${rel:+_${rel//\//_}}

        for f in "${files[@]}"; do
            (( headers )) && printf '// ===== %s =====\n' "${rel:+$rel/}${f##*/}"
            LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$f"   # strip UTF-8 BOM
            echo
        done > "$out/$name.txt"

        printf '  %-45s %3d files\n' "$name.txt" "${#files[@]}"
        n=$((n + 1)); total=$((total + ${#files[@]}))
    done < <(find "$src" -type d -print0 | LC_ALL=C sort -z)

    (( n )) || { echo "csbundle: no .cs files under $src" >&2; return 1; }
    echo "csbundle: $total files -> $n bundles in $(cygpath -w "$out" 2>/dev/null || echo "$out")"
}
