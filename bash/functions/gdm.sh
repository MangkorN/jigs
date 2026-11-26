# gdm: git diff showing only the changed lines, with file headers but no context lines or hunk headers.
# Accepts any git diff arguments.
gdm()
{
  if [[ $1 == -h || $1 == --help ]]; then
    cat <<'USAGE'
usage: gdm [<git diff options>] [<commit>...] [-- <path>...]

Show git diff with only the added and removed lines, keeping file headers but
no context lines or hunk headers. Takes any git diff arguments.
USAGE
    return 0
  fi
  local c=never
  [ -t 1 ] && c=always
  git diff --unified=0 --color="$c" "$@" | awk '
    {
      s = $0
      gsub(/\033\[[0-9;]*m/, "", s)
    }
    s ~ /^diff --git /                   { hdr = 1; print; next }
    s ~ /^@@/                            { hdr = 0; next }
    hdr && s ~ /^(new|deleted) file mode|^rename (from|to) |^Binary files / { print; next }
    hdr                                  { next }
    s ~ /^[-+]/                          { print }
  '
}
