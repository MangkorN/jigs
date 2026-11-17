# gitro: read-only git commands from a fixed menu, for inspecting a repository without changing it.
# Every command maps to one git subcommand and accepts only the flags on its allow-list,
# so a caller can see status, diffs, history and refs but can never write to the repository
# or reach files outside it. 'gitro serve' answers the same commands for other processes
# through request files in a folder, so they never need access to the repository itself.
#   gitro                                                    help
#   gitro diff --cached -- src                               staged changes under src
#   gitro -C /d/Repos/MyProject log -5 --stat                another repository
#   gitro serve /d/Repos/MyProject /d/Exchange/myproject     answer requests dropped into that folder
#   gitro serve -k /d/Repos/MyProject /d/Exchange/myproject  same, keeping a copy of each response
#   gitro list /d/Exchange                                   servers answering in the folders under /d/Exchange
#   gitro ui                                                 browser page for running servers
#   bash gitro.sh status                                     as a script, without loading it first

# The jigs folder, found when this file is loaded, since a relative path to it stops working once the shell changes folder.
_GITRO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)

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
        list)
            [[ $repo == . ]] || { echo "gitro: list takes the folder as an argument: gitro list [<root>]" >&2; return 2; }
            shift
            _gitro_list "$@"
            ;;
        ui)
            [[ $repo == . ]] || { echo "gitro: ui doesn't take -C" >&2; return 2; }
            shift
            _gitro_ui "$@"
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
  gitro serve [-i <seconds>] [-k] [-n <name>] <repo> <dir>
  gitro list [<root>]
  gitro ui [start | stop | status] [<option>...]
  gitro help [<command> | serve]

Runs in the current directory's repository unless -C names one.
Each command accepts only the flags on its allow-list (gitro help <command>),
and everything after -- is a path. Nothing is written to the repository,
not even the index: commands run against a temporary copy of it.
Output goes to the terminal, so it can be redirected or piped like any command's.

examples:
  gitro status --short --branch
  gitro diff --cached --stat -- src
  gitro log --oneline -10
  gitro -C /d/Repos/MyProject show HEAD~2:README.md
  gitro -C /d/Repos/MyProject status > /d/Temp/status.txt

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
  gitro list shows which servers answer in the folders under <root> (default: here).

ui:
  gitro ui starts a local companion in the background and opens a browser page for starting,
  watching and stopping servers, with folder pickers (gitro ui -h).
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
gitro serve [-i <seconds>] [-k] [-n <name>] <repo> <dir>

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

While it runs, the server keeps <dir>/gitro-server.json up to date: its name
(-n, by default the repository's folder name), repository, host, process id,
start time, and 'seen', the Unix time it last refreshed the file, every 10 seconds.
A caller that can see several request folders can read these files to find the one
that serves a repository. A file not refreshed for a minute belongs to a server
that stopped without removing it. One folder has one server: gitro serve refuses
a folder whose server is still running. gitro list shows the servers under a folder.

A 'help' request answers with this help, and 'help <command>' with that command's.
gitro polls every 0.5 seconds unless -i sets another interval.
With -k it also keeps a copy of each response in <dir>/kept/, removed after an hour,
so you can look back at what was asked even after the caller removed its response.
It keeps its own temporary files in <dir> as .work, .body and .part.
The server's terminal only logs one line per request and doesn't read typed input.
To run commands yourself, use gitro directly in another terminal.

example: start a server, then write a request by hand from another terminal:
  gitro serve /d/Repos/MyProject /d/Exchange/myproject
  printf '%s\n' status --short > /d/Exchange/myproject/t1.tmp
  mv /d/Exchange/myproject/t1.tmp /d/Exchange/myproject/t1.req
  sleep 1; cat /d/Exchange/myproject/t1.out
EOF
}

# The server sets traps so it can remove its presence file however it stops. Run as a function in
# an interactive shell, it runs in a subshell, so the traps and Ctrl+C leave that shell alone.
# Run as a script, it runs in the script's own process, so stopping that process stops the server.
_gitro_serve()
{
    if [[ -n $_gitro_script ]]; then
        _gitro_serve_run "$@"
    else
        ( _gitro_serve_run "$@" )
    fi
}

_gitro_serve_run()
{
    interval=0.5 keep=0 label=''
    while [[ $1 == -* ]]; do
        case $1 in
            -i)
                [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "gitro serve: -i needs a number of seconds" >&2; exit 2; }
                interval=$2
                shift 2
                ;;
            -k)
                keep=1
                shift
                ;;
            -n)
                [[ -n $2 ]] || { echo "gitro serve: -n needs a name" >&2; exit 2; }
                label=$2
                shift 2
                ;;
            *)
                echo "gitro serve: unknown option '$1'" >&2
                exit 2
                ;;
        esac
    done
    (( $# == 2 )) || { echo "usage: gitro serve [-i <seconds>] [-k] [-n <name>] <repo> <dir>" >&2; exit 2; }

    # Windows-style paths (D:\Repos\MyProject), as other programs pass them, become /d/Repos/MyProject.
    repo=$1 dir=$2
    if command -v cygpath >/dev/null; then
        repo=$(cygpath -u -- "$repo") && dir=$(cygpath -u -- "$dir") || exit
    fi
    _gitro_check_repo "$repo" || exit
    toplevel=$(git -C "$repo" rev-parse --show-toplevel) || exit
    [[ -n $label ]] || label=${toplevel##*/}
    mkdir -p -- "$dir" && dir=$(cd -- "$dir" && pwd) || exit

    presence=$dir/gitro-server.json
    owner=$(_gitro_presence_owner "$presence")
    if [[ -n $owner ]]; then
        echo "gitro serve: $dir is already served by $owner. Stop that server first, or use another folder." >&2
        exit 2
    fi
    # $BASHPID is this process, even in a subshell; bash 3.2 lacks it, and there a child shell reports its parent instead.
    pid=${BASHPID:-$(exec sh -c 'echo "$PPID"')}
    trap 'trap "" PIPE; _gitro_presence_remove "$presence" "$pid"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # The file names the folder the way git names the repository: D:/Exchange/myproject on Windows.
    shown=$dir
    command -v cygpath >/dev/null && shown=$(cygpath -m -- "$dir")
    fields=$(_gitro_presence_fields "$label" "$toplevel" "$shown" "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    _gitro_presence_write "$presence" "$fields" || exit

    kept=''
    if (( keep )); then
        kept=$dir/kept
        mkdir -p -- "$kept" || exit
    fi

    for file in "$dir"/*.work; do
        [[ -f $file ]] && mv -f -- "$file" "${file%.work}.req"
    done

    echo "gitro: serving '$label' ($toplevel) from $dir${kept:+, keeping responses in $kept} (Ctrl+C stops)" >&2

    last_prune=$SECONDS last_seen=$SECONDS
    while :; do
        for file in "$dir"/*.req; do
            [[ -f $file ]] || continue
            name=${file%.req}
            mv -f -- "$file" "$name.work" 2>/dev/null || continue
            # A read loop rather than mapfile, which macOS's bash 3.2 lacks.
            request=()
            while IFS= read -r line || [[ -n $line ]]; do
                request+=("${line%$'\r'}")
            done < "$name.work"
            _gitro_answer "$repo" "$name" "$kept" "${request[@]}"
            rm -f -- "$name.work"
        done

        if (( SECONDS - last_seen >= 10 )); then
            _gitro_presence_write "$presence" "$fields"
            last_seen=$SECONDS
        fi
        if (( SECONDS - last_prune >= 60 )); then
            find "$dir" ${kept:+"$kept"} -maxdepth 1 -name '*.out' -mmin +60 -delete 2>/dev/null
            last_prune=$SECONDS
        fi
        # Waiting with the wait builtin lets a signal's trap run at once. Waiting on sleep directly, bash would
        # first report sleep's death by the same signal, and if the reader of its output is gone, that write
        # alone would end the server before its cleanup.
        sleep "$interval" &
        wait $!
    done
}

# PRESENCE: gitro-server.json, one per request folder, with one field per line so these functions can read it back.

# Escapes $1 for a JSON string. Control characters, which a name or path shouldn't have, become spaces.
_gitro_json()
{
    local text=${1//\\/\\\\}
    text=${text//[$'\001'-$'\037']/ }
    printf '%s' "${text//\"/\\\"}"
}

# Names the system whose process ids a presence file holds. Git Bash says MINGW64_NT-... or MSYS_NT-...
# depending on how it was started, with the same processes either way.
_gitro_system()
{
    case $(uname -s) in
        MINGW*|MSYS*) echo Windows ;;
        *) uname -s ;;
    esac
}

# Prints the fixed fields of a presence file, for name $1, repository $2, folder $3, process id $4 and start time $5.
_gitro_presence_fields()
{
    printf '  "gitro": 1,\n'
    printf '  "name": "%s",\n' "$(_gitro_json "$1")"
    printf '  "repo": "%s",\n' "$(_gitro_json "$2")"
    printf '  "dir": "%s",\n' "$(_gitro_json "$3")"
    printf '  "host": "%s",\n' "$(_gitro_json "$HOSTNAME")"
    printf '  "system": "%s",\n' "$(_gitro_json "$(_gitro_system)")"
    printf '  "pid": %d,\n' "$4"
    printf '  "started": "%s",' "$5"
}

# Writes presence file $1 from fields $2, with 'seen' set to now. Replaced in one rename, so readers never see half of it.
_gitro_presence_write()
{
    printf '{\n%s\n  "seen": %s\n}\n' "$2" "$(date +%s)" > "$1.tmp" && mv -f -- "$1.tmp" "$1"
}

# Removes presence file $1 if it's still the one process $2 wrote.
_gitro_presence_remove()
{
    [[ $(_gitro_presence_field "$1" pid) == "$2" ]] && rm -f -- "$1"
}

# Prints field $2 of presence file $1: a string field's text, or a number.
_gitro_presence_field()
{
    local line value
    line=$(grep -m1 "^  \"$2\": " -- "$1" 2>/dev/null) || return 1
    value=${line#*\": }
    value=${value%,}
    if [[ $value == \"*\" ]]; then
        value=${value:1:${#value}-2}
        value=$(printf '%s' "$value" | sed 's/\\\(.\)/\1/g')
    fi
    printf '%s\n' "$value"
}

# Prints who serves through presence file $1, such as 'piquest' (D:/Repos/PiQuest-Unity, pid 1234),
# if that server still runs. Prints nothing if there's no file, or the file is stale:
# not refreshed for a minute, or written on this machine by a process that's gone.
_gitro_presence_owner()
{
    [[ -f $1 ]] || return 0
    local seen pid
    seen=$(_gitro_presence_field "$1" seen)
    pid=$(_gitro_presence_field "$1" pid)
    [[ $seen =~ ^[0-9]+$ && $pid =~ ^[0-9]+$ ]] || return 0
    (( $(date +%s) - seen < 60 )) || return 0
    if [[ $(_gitro_presence_field "$1" host) == "$HOSTNAME" && $(_gitro_presence_field "$1" system) == "$(_gitro_system)" ]]; then
        kill -0 "$pid" 2>/dev/null || return 0
    fi
    printf "'%s' (%s, pid %s)" "$(_gitro_presence_field "$1" name)" "$(_gitro_presence_field "$1" repo)" "$pid"
}

# Lists the servers whose presence files are in folder $1 (default: here) or the folders directly under it.
_gitro_list()
{
    local root=${1:-.}
    (( $# <= 1 )) || { echo "usage: gitro list [<root>]" >&2; return 2; }
    command -v cygpath >/dev/null && root=$(cygpath -u -- "$root")
    [[ -d $root ]] || { echo "gitro list: '$1' isn't a folder" >&2; return 2; }

    local file state found=0
    for file in "$root/gitro-server.json" "$root"/*/gitro-server.json; do
        [[ -f $file ]] || continue
        (( found++ )) || printf '%-16s %-6s %-40s %s\n' NAME STATE REPO FOLDER
        state=live
        [[ -n $(_gitro_presence_owner "$file") ]] || state=stale
        printf '%-16s %-6s %-40s %s\n' "$(_gitro_presence_field "$file" name)" "$state" \
            "$(_gitro_presence_field "$file" repo)" "${file%/gitro-server.json}"
    done
    (( found )) || echo "gitro list: no gitro servers in $root or the folders under it" >&2
}

# Runs one request for repository $1 and writes the response to $2.out,
# with a copy in folder $3 unless it's empty.
_gitro_answer()
{
    local repo=$1 name=$2 kept=$3
    shift 3

    local rc
    {
        case $1 in
            ''|help) _gitro_help "${@:2}" ;;
            *) _gitro_run "$repo" "$@" ;;
        esac
    } > "$name.body" 2>&1
    rc=$?

    # The copy is made first, so it exists by the time the response and the log line appear.
    if { printf '# gitro exit=%d: %s\n' "$rc" "$*"; cat -- "$name.body"; } > "$name.part"; then
        [[ -n $kept ]] && cp -f -- "$name.part" "$kept/${name##*/}.out"
        mv -f -- "$name.part" "$name.out"
    fi
    rm -f -- "$name.body"

    printf '%s  %s: %s (exit %d)\n' "$(date +%T)" "${name##*/}" "$*" "$rc" >&2
}

# Starts the companion behind gitro's browser page: powershell/gitro-ui.ps1 on Windows,
# python/gitro-ui.py elsewhere, both from this clone, translating the options for each.
_gitro_ui()
{
    local action=start
    case $1 in
        start|stop|status) action=$1; shift ;;
    esac
    local foreground=0 port='' open='' site='' site_given=0 opt OPTARG OPTIND=1
    while getopts ':fp:o:s:h' opt; do
        case $opt in
            f) foreground=1 ;;
            p) port=$OPTARG ;;
            o) open=$OPTARG ;;
            s) site=$OPTARG; site_given=1 ;;
            h)
                cat <<'EOF'
usage: gitro ui [start] [-f] [-p <port>] [-o local|hosted|none] [-s <site url>]
       gitro ui stop | status

Runs a companion process on 127.0.0.1 for the jigs site's Run page, where gitro servers can be
started, watched and stopped, with folder pickers, and opens that page. The companion runs in the
background, so the terminal can be closed; the page finds it by itself.

  start   starts the companion, or finds the one already running, and opens the page (the default)
  stop    stops the companion and every server it started (the page's Stop button does the same)
  status  shows whether the companion runs, and its servers

  -f  run in this terminal instead of the background, where Ctrl+C stops it
  -p  port to listen on (default 47210)
  -o  page to open: local (site/run/index.html in this clone, the default), hosted, or none
  -s  hosted site allowed to use the companion (default: the GitHub Pages address
      of this clone's origin remote; '' allows none)

The companion is powershell/gitro-ui.ps1 on Windows and python/gitro-ui.py (Python 3.8+) elsewhere.
It keeps its session and log in .gitro-ui/ in this clone.
EOF
                return 0
                ;;
            :) echo "gitro ui: -$OPTARG needs a value" >&2; return 2 ;;
            *) echo "gitro ui: unknown option -$OPTARG (gitro ui -h)" >&2; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))
    (( $# == 0 )) || { echo "gitro ui: unexpected '$1' (gitro ui -h)" >&2; return 2; }
    if [[ $action != start && ( $foreground == 1 || $site_given == 1 || -n $port$open ) ]]; then
        echo "gitro ui: $action takes no options" >&2
        return 2
    fi

    local root=$_GITRO_ROOT
    [[ -n $root && -f $root/python/gitro-ui.py ]] || { echo "gitro ui: can't find the jigs folder this gitro.sh came from" >&2; return 1; }
    local -a cmd
    case $(uname -s) in
        MINGW*|MSYS*|CYGWIN*)
            command -v powershell.exe >/dev/null || { echo "gitro ui: needs Windows PowerShell (powershell.exe)" >&2; return 1; }
            cmd=(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$root/powershell/gitro-ui.ps1")" "$action")
            (( foreground )) && cmd+=(-Foreground)
            [[ -n $port ]] && cmd+=(-Port "$port")
            [[ -n $open ]] && cmd+=(-Open "$open")
            (( site_given )) && cmd+=(-SiteUrl "$site")
            # In mintty, a console program needs winpty for Ctrl+C to reach it.
            if (( foreground )) && [[ $(tty 2>/dev/null) == /dev/pty* ]] && command -v winpty >/dev/null; then
                cmd=(winpty "${cmd[@]}")
            fi
            ;;
        *)
            command -v python3 >/dev/null || { echo "gitro ui: needs python3" >&2; return 1; }
            cmd=(python3 "$root/python/gitro-ui.py" "$action")
            (( foreground )) && cmd+=(--foreground)
            [[ -n $port ]] && cmd+=(--port "$port")
            [[ -n $open ]] && cmd+=(--open "$open")
            (( site_given )) && cmd+=(--site-url "$site")
            ;;
    esac
    # Only the foreground companion reads the terminal; the other actions get no input, so they can't hold it.
    if (( foreground )); then
        "${cmd[@]}"
    else
        "${cmd[@]}" </dev/null
    fi
}

# Run as a script (bash gitro.sh status) rather than loaded with source: behaves like the gitro command.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    _gitro_script=1
    gitro "$@"
    exit
fi
