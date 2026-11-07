# gitro: read-only git commands from a fixed menu, for inspecting a repository without changing it.
# Every command maps to one git subcommand and accepts only the flags on its allow-list,
# so a caller can see status, diffs, history and refs but can never write to the repository
# or reach files outside it. 'gitro serve' answers the same commands for other processes
# through request files in a folder, so they never need access to the repository itself.
#   gitro                                   help
#   gitro diff --cached -- Assets           staged changes under Assets
#   gitro -C /d/Repos/MyRepo log -5 --stat  another repository
#   gitro serve /d/Repos/MyRepo /d/Exchange answer requests dropped into /d/Exchange

_GITRO_MENU=(
    '#Working tree and index'
    status diff ls-files check-ignore check-attr
    '#History'
    log show blame grep shortlog reflog
    '#Refs and objects'
    branch tag for-each-ref rev-parse rev-list describe merge-base range-diff ls-tree cat-file
    '#Other'
    stash-list stash-show remote worktree submodules lfs-files
)

gitro()
{
    local repo=.
    if [[ $1 == -C ]]; then
        [[ -n $2 ]] || { echo "gitro: -C needs a repository path" >&2; return 2; }
        repo=$2
        shift 2
    fi

    case $1 in
        ''|help|-h|--help)
            shift
            _gitro_help "$@"
            ;;
        serve)
            [[ $repo == . ]] ||
                { echo "gitro: serve takes the repository as an argument: gitro serve <repo> <dir>" >&2; return 2; }
            shift
            _gitro_serve "$@"
            ;;
        *)
            _gitro_check_repo "$repo" && _gitro_run "$repo" "$@"
            ;;
    esac
}

# Sets the _g_* variables, declared local by the caller, to the definition of command $1.
#   _g_git      git subcommand and its fixed arguments
#   _g_flags    allowed flags; <n> stands for a number and <value> for any text
#   _g_args     usage of the arguments before --, empty if none are allowed
#   _g_pattern  1 if the first argument is a search pattern, passed to git with -e
#   _g_default  arguments used when none are given
#   _g_paths    none, optional or required: whether paths may or must follow --
#   _g_filter   post-processing of the output, if any
_gitro_spec()
{
    _g_git=() _g_flags=() _g_args='' _g_pattern=0 _g_default=() _g_paths=none _g_filter='' _g_about=''

    case $1 in
        status)
            _g_about='working tree and index state'
            _g_git=(status)
            _g_flags=(-s --short -b --branch --long -v --verbose --show-stash --ahead-behind --no-ahead-behind
                --renames --no-renames -u '-u<value>' --untracked-files '--untracked-files=<value>'
                --ignored '--ignored=<value>' --ignore-submodules '--ignore-submodules=<value>'
                --porcelain '--porcelain=<value>')
            _g_paths=optional
            ;;
        diff)
            _g_about='changes: unstaged, staged (--cached), or between commits'
            _g_git=(diff --no-ext-diff --no-textconv)
            _g_flags=(--cached --staged --merge-base -p --patch -s --no-patch --raw --stat '--stat=<value>' --numstat
                --shortstat --dirstat '--dirstat=<value>' --compact-summary --summary --name-only --name-status
                '-U<n>' '--unified=<n>' -W --function-context --word-diff '--word-diff=<value>'
                '--word-diff-regex=<value>' -w --ignore-all-space -b --ignore-space-change --ignore-space-at-eol
                --ignore-cr-at-eol --ignore-blank-lines -M '-M<value>' --find-renames '--find-renames=<value>'
                --no-renames '--diff-filter=<value>' --relative '--relative=<value>' -R --minimal --patience
                --histogram --check --full-index --abbrev '--abbrev=<n>')
            _g_args='[<commit> [<commit>]]'
            _g_paths=optional
            ;;
        ls-files)
            _g_about='names of tracked, modified, deleted or untracked files'
            _g_git=(ls-files)
            _g_flags=(-c --cached -d --deleted -m --modified -o --others -i --ignored --exclude-standard -s --stage
                -u --unmerged -t -v --full-name --directory --no-empty-directory --eol --error-unmatch --deduplicate
                '--format=<value>' '--abbrev=<n>')
            _g_paths=optional
            ;;
        check-ignore)
            _g_about='which ignore rule, if any, matches each path (exit 1 if none)'
            _g_git=(check-ignore)
            _g_flags=(-v --verbose -n --non-matching -q --quiet)
            _g_paths=required
            ;;
        check-attr)
            _g_about='gitattributes that apply to each path'
            _g_git=(check-attr)
            _g_flags=(-a --all --cached '--source=<value>')
            _g_args='[<attribute>...]'
            _g_paths=required
            ;;
        log)
            _g_about='commit history'
            _g_git=(log --no-ext-diff --no-textconv)
            _g_flags=(--oneline '-<n>' '-n<n>' '--max-count=<n>' '--skip=<n>' -p --patch -s --no-patch --stat
                '--stat=<value>' --shortstat --numstat --name-only --name-status --summary --raw '-U<n>'
                '--unified=<n>' -w --ignore-all-space --word-diff '--word-diff=<value>' --graph --all --branches
                '--branches=<value>' --tags '--tags=<value>' --remotes '--remotes=<value>' --decorate
                '--decorate=<value>' --no-decorate --first-parent -m --cc --reverse --merges --no-merges --follow
                '--author=<value>' '--committer=<value>' '--grep=<value>' -i --regexp-ignore-case --all-match
                --invert-grep -E --extended-regexp -F --fixed-strings '--since=<value>' '--after=<value>'
                '--until=<value>' '--before=<value>' '-S<value>' '-G<value>' --pickaxe-all --pickaxe-regex
                '-L<value>' --pretty '--pretty=<value>' '--format=<value>' --abbrev-commit --no-abbrev-commit
                '--date=<value>' --relative-date --left-right --cherry-pick --cherry-mark --cherry --boundary
                --ancestry-path --simplify-by-decoration --full-history --topo-order --date-order
                --author-date-order --no-walk --source '--diff-filter=<value>' -M --find-renames --no-renames
                --relative '--relative=<value>')
            _g_args='[<revision range>...]'
            _g_paths=optional
            ;;
        show)
            _g_about='a commit, tag or tree, or a file at a revision (<rev>:<path>)'
            _g_git=(show --no-ext-diff --no-textconv)
            _g_flags=(-p --patch -s --no-patch --stat '--stat=<value>' --shortstat --numstat --name-only --name-status
                --summary --raw '-U<n>' '--unified=<n>' -W --function-context -w --ignore-all-space --word-diff
                '--word-diff=<value>' --oneline --pretty '--pretty=<value>' '--format=<value>' --abbrev-commit
                '--date=<value>' -m --cc --first-parent '--diff-filter=<value>' -M --find-renames --no-renames
                --relative '--relative=<value>' -R --check)
            _g_args='[<object>...]'
            _g_paths=optional
            ;;
        blame)
            _g_about='the commit that last changed each line of a file'
            _g_git=(blame --no-textconv)
            _g_flags=('-L<value>' -w -M '-M<n>' -C '-C<n>' -e --show-email -s -l -t -f --show-name -n --show-number
                --root --porcelain --line-porcelain '--date=<value>' '--abbrev=<n>' --first-parent --reverse)
            _g_args='[<rev>]'
            _g_paths=required
            ;;
        grep)
            _g_about='search tracked files, in the working tree, the index (--cached) or a revision'
            _g_git=(grep --no-textconv)
            _g_flags=(-n --line-number --column -i --ignore-case -w --word-regexp -v --invert-match -l
                --files-with-matches -L --files-without-match -c --count -h -H --full-name -E --extended-regexp
                -F --fixed-strings -P --perl-regexp -o --only-matching -p --show-function -W --function-context
                '-A<n>' '-B<n>' '-C<n>' '--context=<n>' '--max-depth=<n>' '-m<n>' '--max-count=<n>' --cached
                --heading --break)
            _g_args='<pattern> [<rev>...]'
            _g_pattern=1
            _g_paths=optional
            ;;
        shortlog)
            _g_about='commit counts and subjects per author'
            _g_git=(shortlog)
            _g_flags=(-s --summary -n --numbered -e --email -c --committer '--group=<value>' '--since=<value>'
                '--until=<value>' --no-merges --merges --first-parent --all)
            _g_args='[<revision range>...]'
            _g_default=(HEAD)
            _g_paths=optional
            ;;
        reflog)
            _g_about='where HEAD or a branch has pointed over time'
            _g_git=(reflog show)
            _g_flags=('-<n>' '-n<n>' '--max-count=<n>' --oneline '--format=<value>' '--pretty=<value>'
                '--date=<value>' --relative-date --stat --name-status)
            _g_args='[<ref>]'
            ;;
        branch)
            _g_about='local and remote-tracking branches'
            _g_git=(branch --list)
            _g_flags=(-v -vv --verbose -a --all -r --remotes -i --ignore-case --merged '--merged=<value>'
                --no-merged '--no-merged=<value>' --contains '--contains=<value>' '--no-contains=<value>'
                '--points-at=<value>' '--sort=<value>' '--format=<value>' '--abbrev=<n>' --no-abbrev)
            _g_args='[<pattern>...]'
            ;;
        tag)
            _g_about='tags'
            _g_git=(tag --list)
            _g_flags=(-n '-n<n>' -i --ignore-case '--sort=<value>' --contains '--contains=<value>'
                '--no-contains=<value>' '--points-at=<value>' --merged '--merged=<value>' --no-merged
                '--no-merged=<value>' '--format=<value>')
            _g_args='[<pattern>...]'
            ;;
        for-each-ref)
            _g_about='refs in a custom format, e.g. upstream ahead/behind with %(upstream:track)'
            _g_git=(for-each-ref)
            _g_flags=('--format=<value>' '--sort=<value>' '--count=<n>' --merged '--merged=<value>' --no-merged
                '--no-merged=<value>' --contains '--contains=<value>' '--no-contains=<value>' '--points-at=<value>'
                --ignore-case)
            _g_args='[<pattern>...]'
            ;;
        rev-parse)
            _g_about='object ids for names, and repository paths and state'
            _g_git=(rev-parse)
            _g_flags=(--verify -q --quiet --short '--short=<n>' --abbrev-ref '--abbrev-ref=<value>' --symbolic
                --symbolic-full-name --all --branches '--branches=<value>' --tags '--tags=<value>' --remotes
                '--remotes=<value>' --show-toplevel --show-prefix --show-cdup --git-dir --absolute-git-dir
                --git-common-dir --show-superproject-working-tree --is-inside-work-tree --is-inside-git-dir
                --is-bare-repository --is-shallow-repository '--since=<value>' '--until=<value>')
            _g_args='[<rev>...]'
            ;;
        rev-list)
            _g_about='commit ids, or counts such as ahead/behind (--count --left-right A...B)'
            _g_git=(rev-list)
            _g_flags=(--count --left-right --left-only --right-only --cherry-pick --cherry-mark --cherry '-<n>'
                '-n<n>' '--max-count=<n>' '--skip=<n>' --all --branches --tags --remotes --first-parent --merges
                --no-merges --reverse --topo-order --date-order '--since=<value>' '--until=<value>'
                '--author=<value>' '--grep=<value>' --ancestry-path --boundary --oneline --abbrev-commit
                '--abbrev=<n>' '--pretty=<value>' '--format=<value>' --timestamp --parents --children)
            _g_args='[<revision range>...]'
            _g_paths=optional
            ;;
        describe)
            _g_about='a name for a commit relative to the nearest tag'
            _g_git=(describe)
            _g_flags=(--tags --all --always --long --contains --exact-match --first-parent '--abbrev=<n>'
                '--match=<value>' '--exclude=<value>' '--candidates=<n>')
            _g_args='[<commit>...]'
            ;;
        merge-base)
            _g_about='best common ancestor of commits (--is-ancestor answers with the exit code)'
            _g_git=(merge-base)
            _g_flags=(-a --all --is-ancestor --fork-point --octopus --independent)
            _g_args='<commit>...'
            ;;
        range-diff)
            _g_about='two versions of a commit series side by side, e.g. before and after a rebase'
            _g_git=(range-diff)
            _g_flags=('--creation-factor=<n>' --no-dual-color --left-only --right-only)
            _g_args='<old range> <new range> | <old>...<new> | <base> <old> <new>'
            ;;
        ls-tree)
            _g_about='files and folders stored in a tree, such as a commit'
            _g_git=(ls-tree)
            _g_flags=(-r -d -t -l --long --name-only --name-status --object-only --full-name --full-tree
                '--abbrev=<n>' '--format=<value>')
            _g_args='<tree-ish>'
            _g_paths=optional
            ;;
        cat-file)
            _g_about='type (-t), size (-s) or content (-p) of an object'
            _g_git=(cat-file)
            _g_flags=(-t -s -p -e)
            _g_args='[<type>] <object>'
            ;;
        stash-list)
            _g_about='stash entries'
            _g_git=(stash list)
            _g_flags=(--oneline '--format=<value>' '--pretty=<value>' '--date=<value>' --stat --name-only --name-status)
            ;;
        stash-show)
            _g_about='changes recorded in a stash entry'
            _g_git=(stash show --no-ext-diff --no-textconv)
            _g_flags=(-p --patch --stat --numstat --shortstat --name-only --name-status --summary -u
                --include-untracked --no-include-untracked --only-untracked '-U<n>' -w --word-diff)
            _g_args='[<stash>]'
            ;;
        remote)
            _g_about='remote names and URLs, with any credentials in the URLs hidden'
            _g_git=(remote -v)
            _g_filter=credentials
            ;;
        worktree)
            _g_about='linked working trees'
            _g_git=(worktree list)
            _g_flags=(--porcelain -v --verbose)
            ;;
        submodules)
            _g_about='submodule commits and states'
            _g_git=(submodule status)
            _g_flags=(--recursive --cached)
            _g_paths=optional
            ;;
        lfs-files)
            _g_about='files stored with Git LFS (needs git-lfs)'
            _g_git=(lfs ls-files)
            _g_flags=(-l --long -s --size -n --name-only -a --all -d --deleted --json)
            _g_args='[<ref>]'
            ;;
        *)
            return 1
            ;;
    esac
}

_gitro_check_repo()
{
    [[ $(GIT_OPTIONAL_LOCKS=0 git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] && return
    echo "gitro: '$1' is not inside a git working tree" >&2
    return 2
}

# Succeeds if flag $1 matches one of the allowed flags that follow it.
# A cluster of single-letter flags, such as -sn, is allowed if each letter is allowed on its own.
_gitro_flag_allowed()
{
    local flag=$1 allowed re
    shift
    for allowed; do
        re=${allowed//<n>/[0-9]+}
        re=${re//<value>/.+}
        [[ $flag =~ ^$re$ ]] && return 0
    done

    [[ $flag =~ ^-[A-Za-z]{2,}$ ]] || return 1
    local i letter_allowed
    for (( i = 1; i < ${#flag}; i++ )); do
        letter_allowed=0
        for allowed; do
            [[ $allowed == "-${flag:i:1}" ]] && { letter_allowed=1; break; }
        done
        (( letter_allowed )) || return 1
    done
}

# Runs menu command $2 in repository $1. Flags before -- are checked against the command's allow-list,
# other arguments before -- can't start with '-', and everything after -- is passed as paths.
_gitro_run()
{
    local repo=$1 cmd=$2
    shift 2

    local -a _g_git _g_flags _g_default
    local _g_args _g_pattern _g_paths _g_filter _g_about
    _gitro_spec "$cmd" || { echo "gitro: unknown command '$cmd' (gitro help lists them)" >&2; return 2; }

    local -a flags=() args=() paths=()
    local arg has_paths=0
    for arg; do
        if (( has_paths )); then
            paths+=("$arg")
        elif [[ $arg == -- ]]; then
            has_paths=1
        elif [[ $arg == -* ]]; then
            _gitro_flag_allowed "$arg" "${_g_flags[@]}" ||
                { echo "gitro $cmd: '$arg' is not an allowed flag (gitro help $cmd lists them)" >&2; return 2; }
            flags+=("$arg")
        else
            args+=("$arg")
        fi
    done

    if [[ -z $_g_args ]] && (( ${#args[@]} )); then
        echo "gitro $cmd: takes no arguments, got '${args[0]}'" >&2
        return 2
    fi
    if [[ $_g_paths == none ]] && (( has_paths )); then
        echo "gitro $cmd: takes no paths" >&2
        return 2
    fi
    if [[ $_g_paths == required ]] && (( ${#paths[@]} == 0 )); then
        echo "gitro $cmd: needs at least one path after --" >&2
        return 2
    fi
    if (( _g_pattern )) && (( ${#args[@]} == 0 )); then
        echo "gitro $cmd: needs a pattern" >&2
        return 2
    fi

    (( ${#args[@]} )) || args=("${_g_default[@]}")

    local -a argv=("${_g_git[@]}" "${flags[@]}")
    if (( _g_pattern )); then
        argv+=(-e "${args[0]}" "${args[@]:1}")
    else
        argv+=("${args[@]}")
    fi
    (( has_paths )) && argv+=(-- "${paths[@]}")

    # git status and git diff refresh the index's cached file stats and write them back when they can.
    # Running against a temporary copy of the index keeps those writes, and the index lock, out of the repository.
    local -a env=(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0)
    local index index_copy=''
    index=$(git -C "$repo" rev-parse --path-format=absolute --git-path index 2>/dev/null)
    if [[ -f $index ]]; then
        index_copy=$(mktemp "${TMPDIR:-/tmp}/gitro-index.XXXXXX") || return
        command -v cygpath >/dev/null && index_copy=$(cygpath -m "$index_copy")
        cp -- "$index" "$index_copy" || { rm -f -- "$index_copy"; return 1; }
        env+=(GIT_INDEX_FILE="$index_copy")
    fi

    local -a git=(git -C "$repo" --no-pager -c core.quotepath=false -c color.ui=auto)
    local rc
    if [[ $_g_filter == credentials ]]; then
        env "${env[@]}" "${git[@]}" "${argv[@]}" </dev/null | sed -E 's#(://)[^/@[:space:]]+@#\1#'
        rc=${PIPESTATUS[0]}
    else
        env "${env[@]}" "${git[@]}" "${argv[@]}" </dev/null
        rc=$?
    fi

    [[ -n $index_copy ]] && rm -f -- "$index_copy" "$index_copy.lock"
    return "$rc"
}

_gitro_help()
{
    if [[ $1 == serve ]]; then
        _gitro_help_serve
    elif [[ -n $1 ]]; then
        _gitro_help_command "$1"
    else
        _gitro_help_menu
    fi
}

_gitro_help_menu()
{
    local -a _g_git _g_flags _g_default
    local _g_args _g_pattern _g_paths _g_filter _g_about
    local entry

    cat <<'EOF'
gitro: read-only git commands from a fixed menu.

usage:
  gitro [-C <repo>] <command> [<flag>...] [<arg>...] [-- <path>...]
  gitro serve [-i <seconds>] <repo> <dir>
  gitro help [<command> | serve]

Runs in the current directory's repository unless -C names one.
Each command accepts only the flags on its allow-list (gitro help <command>),
and everything after -- is a path. Nothing is written to the repository,
not even the index: commands run against a temporary copy of it.

commands:
EOF
    for entry in "${_GITRO_MENU[@]}"; do
        if [[ $entry == '#'* ]]; then
            printf '  %s\n' "${entry#'#'}"
        else
            _gitro_spec "$entry"
            printf '    %-14s%s\n' "$entry" "$_g_about"
        fi
    done
    cat <<'EOF'

serve:
  gitro serve answers these commands for other processes through request files in a folder,
  so they can inspect the repository without access to it (gitro help serve).
EOF
}

_gitro_help_command()
{
    local -a _g_git _g_flags _g_default
    local _g_args _g_pattern _g_paths _g_filter _g_about
    _gitro_spec "$1" || { echo "gitro: unknown command '$1' (gitro help lists them)" >&2; return 2; }

    local usage="gitro [-C <repo>] $1"
    (( ${#_g_flags[@]} )) && usage+=' [<flag>...]'
    [[ -n $_g_args ]] && usage+=" $_g_args"
    case $_g_paths in
        optional) usage+=' [-- <path>...]' ;;
        required) usage+=' -- <path>...' ;;
    esac

    printf '%s\n\n%s\n' "$_g_about" "$usage"
    printf 'runs: git %s\n' "${_g_git[*]}"
    (( ${#_g_default[@]} )) && printf 'without arguments: %s\n' "${_g_default[*]}"
    (( _g_pattern )) && printf 'the pattern is passed with -e, so it may contain spaces and other special characters\n'
    if (( ${#_g_flags[@]} )); then
        printf '\nflags (<n> is a number, <value> any text, written as one argument):\n'
        printf '%s\n' "${_g_flags[*]}" | fold -s -w 100 | sed 's/ *$//; s/^/  /'
    else
        printf '\nflags: none\n'
    fi
}

_gitro_help_serve()
{
    cat <<'EOF'
gitro serve [-i <seconds>] <repo> <dir>

Answers gitro requests for <repo> that appear in <dir>, until stopped with Ctrl+C.
Any process that can write to <dir> can query the repository this way,
without access to the repository itself.

  1. Write a request file with one argument per line: the command first,
     then its flags, arguments and paths, as they would follow 'gitro'.
     Write it under another name, then rename it to <name>.req,
     so it's never read half-written.
  2. gitro takes the request, runs it and writes <name>.out. Its first line is
       # gitro exit=<code>: <request>
     and the command's output and errors follow.
  3. Requests are removed once taken, and responses after an hour.

A 'help' request answers with this help, and 'help <command>' with that command's.
gitro polls every 0.5 seconds unless -i sets another interval.
It keeps its own temporary files in <dir> as .work, .body and .part.
EOF
}

_gitro_serve()
{
    local interval=0.5
    if [[ $1 == -i ]]; then
        [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "gitro serve: -i needs a number of seconds" >&2; return 2; }
        interval=$2
        shift 2
    fi
    (( $# == 2 )) || { echo "usage: gitro serve [-i <seconds>] <repo> <dir>" >&2; return 2; }

    local repo=$1 dir=$2
    _gitro_check_repo "$repo" || return
    mkdir -p -- "$dir" || return

    local file
    for file in "$dir"/*.work; do
        [[ -f $file ]] && mv -f -- "$file" "${file%.work}.req"
    done

    echo "gitro: serving $(git -C "$repo" rev-parse --show-toplevel) from $dir (Ctrl+C stops)" >&2

    local name last_prune=$SECONDS
    local -a request
    while :; do
        for file in "$dir"/*.req; do
            [[ -f $file ]] || continue
            name=${file%.req}
            mv -f -- "$file" "$name.work" 2>/dev/null || continue
            mapfile -t request < "$name.work"
            request=("${request[@]%$'\r'}")
            _gitro_answer "$repo" "$name" "${request[@]}"
            rm -f -- "$name.work"
        done

        if (( SECONDS - last_prune >= 60 )); then
            find "$dir" -maxdepth 1 -name '*.out' -mmin +60 -delete 2>/dev/null
            last_prune=$SECONDS
        fi
        sleep "$interval"
    done
}

# Runs one request for repository $1 and writes the response to $2.out.
_gitro_answer()
{
    local repo=$1 name=$2
    shift 2

    local rc
    {
        case $1 in
            ''|help) _gitro_help "${@:2}" ;;
            *) _gitro_run "$repo" "$@" ;;
        esac
    } > "$name.body" 2>&1
    rc=$?

    { printf '# gitro exit=%d: %s\n' "$rc" "$*"; cat -- "$name.body"; } > "$name.part" &&
        mv -f -- "$name.part" "$name.out"
    rm -f -- "$name.body"

    printf '%s  %s: %s (exit %d)\n' "$(date +%T)" "${name##*/}" "$*" "$rc" >&2
}
