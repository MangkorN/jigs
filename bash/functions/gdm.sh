# gdm: git diff showing only the changed lines (no context, no hunk headers).
# Accepts any git diff arguments.
gdm()
{
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
