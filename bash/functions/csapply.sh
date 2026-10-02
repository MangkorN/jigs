# csapply: overwrites files in a target tree with same-named files from a flat source folder.
# Matching is by file name, case-insensitive. Contents are overwritten in place
# and .meta files are never touched, so Unity GUIDs and references are preserved.
csapply()
(
    all=0; yes=0; dry=0; raw=0
    OPTIND=1
    while getopts ":aynrh" opt; do
        case $opt in
            a) all=1 ;;
            y) yes=1 ;;
            n) dry=1 ;;
            r) raw=1 ;;
            h) cat <<'EOF'
usage: csapply [-a] [-n] [-y] [-r] [target] [srcdir]
  target   tree to update (default: $CSAPPLY_TARGET)
  srcdir   flat folder of replacement files (default: .)
  -a       all file types, not just .cs (.meta is always excluded)
  -n       dry run: print the plan and exit
  -y       apply without confirmation
  -r       raw copy: don't adapt BOM/line endings to the target file
EOF
               exit 0 ;;
            \?) echo "csapply: unknown option -$OPTARG" >&2; exit 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    target=${1:-$CSAPPLY_TARGET}
    [[ -n $target ]] || { echo "csapply: no target given and CSAPPLY_TARGET is unset" >&2; exit 2; }
    target=$(cd -- "$target" 2>/dev/null && pwd) || { echo "csapply: not a directory: ${1:-$CSAPPLY_TARGET}" >&2; exit 1; }
    src=$(cd -- "${2:-.}" 2>/dev/null && pwd) || { echo "csapply: not a directory: ${2:-.}" >&2; exit 1; }
    case "$src/" in
        "$target"/*) echo "csapply: source folder must not be inside the target tree" >&2; exit 1 ;;
    esac

    pat='*.cs'; (( all )) && pat='*'

    # Index target files by lowercased name; skip dot-dirs, Unity-ignored "~" dirs, and build output.
    declare -A index
    while IFS= read -r -d '' p; do
        key=${p##*/}; key=${key,,}
        index[$key]+=$p$'\n'
    done < <(find "$target" -mindepth 1 \
                \( -type d \( -name '.*' -o -name '*~' -o -name Library -o -name Temp \
                              -o -name Logs -o -name obj \) -prune \) \
                -o -type f -iname "$pat" ! -iname '*.meta' -print0)

    declare -a files
    while IFS= read -r -d '' p; do files+=("$p"); done \
        < <(find "$src" -maxdepth 1 -type f -iname "$pat" ! -iname '*.meta' -print0 | LC_ALL=C sort -z)
    (( ${#files[@]} )) || { echo "csapply: no matching files in $src" >&2; exit 1; }

    # Resolve each source file to its target by exact (case-insensitive) name.
    declare -a dst status gitstate
    declare -A claims
    for i in "${!files[@]}"; do
        key=${files[i]##*/}; key=${key,,}
        mapfile -t cands < <(printf '%s' "${index[$key]}")
        case ${#cands[@]} in
            0) status[i]=new ;;
            1) status[i]=match; dst[i]=${cands[0]}; claims[${cands[0]}]+=x ;;
            *) status[i]=ambig; dst[i]=${index[$key]} ;;
        esac
    done

    tmpdir=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmpdir"' EXIT

    n_update=0
    for i in "${!files[@]}"; do
        [[ ${status[i]} == match ]] || continue
        if [[ ${claims[${dst[i]}]} != x ]]; then status[i]=dup; continue; fi
        out=$tmpdir/$i
        if (( raw )); then cp -- "${files[i]}" "$out"
        else __csapply_render "${files[i]}" "${dst[i]}" > "$out"; fi
        if cmp -s -- "$out" "${dst[i]}"; then status[i]=same; continue; fi
        status[i]=update; n_update=$((n_update + 1))
        gitstate[i]=$(__csapply_gitstate "${dst[i]}")
    done

    for i in "${!files[@]}"; do
        name=${files[i]##*/}
        case ${status[i]} in
            update)
                case ${gitstate[i]} in
                    dirty)     note='  ! has uncommitted changes, which will be lost' ;;
                    untracked) note='  ! untracked, no git backup' ;;
                    nogit)     note='  ! not in a git repo' ;;
                    *)         note='' ;;
                esac
                printf '  UPDATE  %-40s -> %s%s\n' "$name" "${dst[i]#"$target"/}" "$note" ;;
            same)  printf '  same    %-40s    identical, skipped\n' "$name" ;;
            new)   printf '  NEW     %-40s    no match in target, skipped\n' "$name" ;;
            dup)   printf '  DUP     %-40s    multiple sources map to %s, skipped\n' "$name" "${dst[i]#"$target"/}" ;;
            ambig) printf '  AMBIG   %-40s    multiple matches, skipped:\n' "$name"
                   while IFS= read -r c; do
                       [[ -n $c ]] && printf '            %s\n' "${c#"$target"/}"
                   done <<< "${dst[i]}" ;;
        esac
    done

    (( n_update )) || { echo "csapply: nothing to update"; exit 0; }
    (( dry )) && { echo "csapply: dry run, $n_update file(s) would be updated"; exit 0; }
    if (( ! yes )); then
        read -r -p "Apply $n_update update(s)? [y/N] " ans < /dev/tty
        [[ $ans == [yY]* ]] || { echo "csapply: aborted"; exit 1; }
    fi

    fail=0
    for i in "${!files[@]}"; do
        [[ ${status[i]} == update ]] || continue
        cat -- "$tmpdir/$i" > "${dst[i]}" || { echo "csapply: failed to write ${dst[i]}" >&2; fail=1; }
    done
    (( fail )) && exit 1
    echo "csapply: updated $n_update file(s)"
)

# Writes source content using the destination's encoding conventions:
# UTF-8 BOM if the destination has one, CRLF if the destination contains any CR.
__csapply_render()
(
    export LC_ALL=C
    s=$1; d=$2; bom=0; crlf=0
    [[ $(head -c3 -- "$d") == $'\xEF\xBB\xBF' ]] && bom=1
    grep -q $'\r' -- "$d" && crlf=1
    (( bom )) && printf '\xEF\xBB\xBF'
    if (( crlf )); then
        sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/$/\r/' -- "$s"
    else
        sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -- "$s"
    fi
)

# Prints the git state of a file: clean, dirty, untracked, or nogit.
__csapply_gitstate()
{
    local dir=${1%/*} f=${1##*/}
    git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null || { echo nogit; return; }
    git -C "$dir" ls-files --error-unmatch -- "$f" &>/dev/null || { echo untracked; return; }
    git -C "$dir" diff --quiet HEAD -- "$f" &>/dev/null && echo clean || echo dirty
}
