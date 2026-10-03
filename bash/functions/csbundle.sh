# csbundle: concatenates the .cs files of each directory under a source tree
# into one .txt per directory, named by relative path:
#   Root.txt, Root_Drivers.txt, Root_Settings_SubSettings.txt, ...
# With -d N, directories at depth N also absorb everything beneath them.
csbundle()
{
    local prefix="Root" out="" headers=1 maxdepth=-1
    local opt OPTIND=1
    while getopts ":p:o:d:nh" opt; do
        case $opt in
            p) prefix=$OPTARG ;;
            o) out=$OPTARG ;;
            d) [[ $OPTARG =~ ^[0-9]+$ ]] || { echo "csbundle: -d needs a non-negative integer" >&2; return 2; }
               maxdepth=$OPTARG ;;
            n) headers=0 ;;
            h) cat <<'USAGE'
usage: csbundle [-p prefix] [-o outdir] [-d depth] [-n] [srcdir]
  srcdir     root of the tree to bundle (default: .)
  -p prefix  name of the root bundle and prefix for the rest (default: Root)
  -o outdir  output directory (default: ~/cs_bundles/<srcdir name>)
  -d depth   deepest directory level that gets its own bundle (srcdir is 0);
             deeper directories are merged into their ancestor at that level
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

    local dir rel key name f k total=0
    local -a files parts order
    local -A counts
    while IFS= read -r -d '' dir; do
        files=()
        while IFS= read -r -d '' f; do files+=("$f"); done \
            < <(find "$dir" -maxdepth 1 -type f -name '*.cs' -print0 | LC_ALL=C sort -z)
        (( ${#files[@]} )) || continue

        rel=${dir#"$src"}; rel=${rel#/}

        # Bundle key: rel truncated to maxdepth components.
        key=$rel
        if (( maxdepth >= 0 )); then
            IFS=/ read -ra parts <<< "$rel"
            key=""
            for (( k = 0; k < maxdepth && k < ${#parts[@]}; k++ )); do
                key+=${key:+/}${parts[k]}
            done
        fi
        name=$prefix${key:+_${key//\//_}}

        # Directories arrive parent-first, so appending keeps each bundle
        # grouped by directory, with a directory's own files before its children's.
        for f in "${files[@]}"; do
            (( headers )) && printf '// ===== %s =====\n' "${rel:+$rel/}${f##*/}"
            LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$f"   # strip UTF-8 BOM
            echo
        done >> "$out/$name.txt"

        [[ -n ${counts[$name]} ]] || order+=("$name")
        counts[$name]=$(( ${counts[$name]:-0} + ${#files[@]} ))
        total=$((total + ${#files[@]}))
    done < <(find "$src" -type d -print0 | LC_ALL=C sort -z)

    (( ${#order[@]} )) || { echo "csbundle: no .cs files under $src" >&2; return 1; }
    for name in "${order[@]}"; do
        printf '  %-45s %3d files\n' "$name.txt" "${counts[$name]}"
    done
    echo "csbundle: $total files -> ${#order[@]} bundles in $(cygpath -w "$out" 2>/dev/null || echo "$out")"
}
