#!/usr/bin/env bash
# Tests what gitro promises against a throwaway repository: requests that would write, start other programs or read
# outside the repository are refused, nothing is written and no other program starts even with the repository set up
# to start them, credentials stay hidden, and presence files are read whatever their layout.
#   bash tests/gitro-test.sh
# Exits with the number of failed checks.

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../bash/functions/gitro.sh
source "$root/bash/functions/gitro.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/gitro-test.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
repo=$work/repo
ran=$work/ran.txt
secret=$work/secret.txt

passed=0 failed=0

# Prints one line per check, with its section in a column, and counts it.
check()
{
    local section=$1 about=$2 ok=$3 detail=$4
    if (( ok )); then
        (( passed++ ))
        printf 'ok    %-10s %s\n' "$section" "$about"
    else
        (( failed++ ))
        printf 'FAIL  %-10s %s\n      %s\n' "$section" "$about" "$detail"
    fi
}

# Checks that request $3... is refused: exit 2, a message, and nothing of the secret.
refused()
{
    local section=$1 about=$2 out code
    shift 2
    out=$(cd "$repo" && gitro "$@" 2>&1)
    code=$?
    check "$section" "$about" "$(( code == 2 && ${#out} > 0 ))" "exit $code: ${out:0:200}"
    [[ $out == *SECRET* ]] && check "$section" "$about: the secret stays out" 0 "${out:0:200}"
}

# Checks that request $3... answers with exit 0 and output matching pattern $3.
answers()
{
    local section=$1 about=$2 pattern=$3 out code
    shift 3
    out=$(cd "$repo" && gitro "$@" 2>&1)
    code=$?
    [[ $code == 0 && $out =~ $pattern ]]
    check "$section" "$about" "$(( $? == 0 ))" "exit $code: ${out:0:200}"
}

# A repository set up to start a program wherever git would: an external diff, textconv and diff command for *.txt,
# a pager, a file-watcher hook and signature checks, all recording their start in ran.txt.
setup()
{
    printf '#!/bin/sh\necho "$0 $*" >> "%s"\n' "$ran" > "$work/mark.sh" && chmod +x "$work/mark.sh"
    echo 'SECRET outside the repository' > "$secret"
    git init -q "$repo" && cd "$repo" || return
    git config user.name test && git config user.email test@example.com && git config commit.gpgSign false
    echo one > a.txt && echo '*.txt diff=marked' > .gitattributes
    git add . && git commit -qm first
    echo two >> a.txt && git commit -qam second
    git branch -q feature HEAD~1
    echo three >> a.txt && git stash -q
    local commit
    commit=$(printf 'tree %s\nparent %s\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n x\n -----END PGP SIGNATURE-----\n\nsigned\n' \
        "$(git rev-parse 'HEAD^{tree}')" "$(git rev-parse HEAD)" | git hash-object -t commit -w --stdin)
    git branch -q signed "$commit"
    git remote add origin https://someone:SECRET-token@example.com/team/repo.git
    local mark=$work/mark.sh
    git config diff.external "$mark external"
    git config diff.marked.textconv "$mark textconv"
    git config diff.marked.command "$mark command"
    git config core.pager "$mark pager"
    git config core.fsmonitor "$mark fsmonitor"
    git config log.showSignature true
    git config gpg.program "$mark"
    touch a.txt   # stale file stats, so git status would refresh the index and write it back
    cd - >/dev/null || return
}

setup || { echo "gitro-test: couldn't set up the test repository" >&2; exit 1; }
index_before=$(cksum < "$repo/.git/index")
refs_before=$(git -C "$repo" for-each-ref | cksum)
config_before=$(cksum < "$repo/.git/config")

refused writes   'show --output writes a file'                  show --format=x --no-patch "--output=$repo/.git/config" HEAD
refused writes   'diff --output writes a file'                  diff "--output=$work/written"
refused writes   '--output given as two arguments too'          log --format=%H --output "$work/written"
refused writes   'stash, which would stash the changes'         stash
answers writes   'branch <name> only lists'                     '^$' branch new-branch
answers writes   'tag <name> only lists'                        '^$' tag v9

refused programs '--ext-diff'                                   diff --ext-diff HEAD~1
refused programs 'grep -O, which opens a pager'                 grep "-O$work/mark.sh" two
refused programs 'grep --open-files-in-pager'                   grep --open-files-in-pager two
refused programs 'signature placeholders in --format'           log '--format=%h %G?' -1 signed
refused programs 'signature placeholders in --pretty'           log '--pretty=format:%GS' -1 signed
refused programs 'range-diff while a textconv program is set'   range-diff feature...master
refused programs 'git options before the command'               -c core.pager=x log
refused programs 'a cluster hiding a value (-po<file>)'         diff "-po$work/written"

refused outside  'diff of a file outside, as two names'         diff "$secret" /dev/null
refused outside  'diff of a file outside, by a relative path'   diff ../secret.txt a.txt
refused outside  'diff of a file outside, after --'             diff -- ../secret.txt a.txt
refused outside  'diff of a file outside, beside a revision'    diff HEAD "$secret"
refused outside  'diff --no-index'                              diff --no-index "$secret" a.txt
refused outside  'grep -f <file>'                               grep -f "$secret"
refused outside  'blame --contents <file>'                      blame --contents "$secret" -- a.txt
refused outside  'the same, abbreviated (--cont)'               blame --cont "$secret" -- a.txt
refused outside  'ls-files --exclude-from=<file>'               ls-files "--exclude-from=$secret"
refused outside  '--pathspec-from-file=<file>'                  diff "--pathspec-from-file=$secret"
answers outside  'an option after -- is only a path'            '^$' log --oneline -- "--output=$work/written"
out=$(cd "$repo" && gitro log -- ../secret.txt 2>&1)
check outside    'log of a path outside: git refuses it'        "$(( $? != 0 ))" "$out"
out=$(cd "$repo" && gitro show HEAD:../secret.txt 2>&1)
check outside    'show <rev>:<path outside>: git refuses it'    "$(( $? != 0 ))" "$out"

answers reads    'status'                                       'On branch' status
answers reads    'diff between commits'                         '\+two' diff HEAD~1 HEAD
answers reads    'diff of a path inside'                        '' diff -- a.txt
answers reads    'log -p'                                       '\+two' log -p -1
answers reads    'show of a signed commit'                      'signed' show --stat signed
answers reads    'stash-show -p'                                '\+three' stash-show -p
answers reads    'blame'                                        'one' blame -- a.txt
answers reads    'grep'                                         'two' grep two
answers reads    'the remote, without its credentials'          'https://example\.com/team/repo\.git' remote
out=$(cd "$repo" && gitro remote 2>&1)
check reads      'no credentials in the remote output'          "$([[ $out != *SECRET* ]] && echo 1 || echo 0)" "$out"

ran_text=$(cat -- "$ran" 2>/dev/null)
check after      'no other program started'                     "$([[ -z $ran_text ]] && echo 1 || echo 0)" "$ran_text"
check after      'the index is unchanged'                       "$([[ $(cksum < "$repo/.git/index") == "$index_before" ]] && echo 1 || echo 0)" ''
check after      'refs are unchanged'                           "$([[ $(git -C "$repo" for-each-ref | cksum) == "$refs_before" ]] && echo 1 || echo 0)" ''
check after      'the config is unchanged'                      "$([[ $(cksum < "$repo/.git/config") == "$config_before" ]] && echo 1 || echo 0)" ''
check after      'no file written outside'                      "$([[ ! -e $work/written ]] && echo 1 || echo 0)" ''

git -C "$repo" config --unset diff.marked.textconv
answers reads    'range-diff without a textconv program'        'second' range-diff feature...master

presence=$work/gitro-server.json
_gitro_presence_write "$presence" "$(_gitro_presence_fields 'odd "name" \ here' /d/Repos/x "$work" 42 2026-01-01T00:00:00Z)"
check presence   "a name with quotes and a backslash"           "$([[ $(_gitro_presence_field "$presence" name) == 'odd "name" \ here' ]] && echo 1 || echo 0)" "$(cat "$presence")"
check presence   'a number'                                     "$([[ $(_gitro_presence_field "$presence" pid) == 42 ]] && echo 1 || echo 0)" ''
printf '{"gitro":1,"name":"compact","pid":7,"seen":1}' > "$presence"
check presence   'compact JSON'                                 "$([[ $(_gitro_presence_field "$presence" name),$(_gitro_presence_field "$presence" pid) == compact,7 ]] && echo 1 || echo 0)" ''
printf '{\r\n\t"pid" :\r\n\t\t8,\r\n\t"name"\t:\t"tabs"\r\n}\r\n' > "$presence"
check presence   'other indentation and CRLF'                   "$([[ $(_gitro_presence_field "$presence" name),$(_gitro_presence_field "$presence" pid) == tabs,8 ]] && echo 1 || echo 0)" ''
printf '{"name": "x \\"pid\\": 9", "pid": 10}' > "$presence"
check presence   'a key inside a value is not a key'            "$([[ $(_gitro_presence_field "$presence" pid) == 10 ]] && echo 1 || echo 0)" ''
_gitro_presence_field "$presence" missing >/dev/null
check presence   'a missing key fails'                          "$(( $? != 0 ))" ''

echo "$passed passed, $failed failed"
exit "$failed"
