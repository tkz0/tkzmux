#!/usr/bin/env bash
# scan-personal-data.sh — look for personal data before (and after) this repo goes public.
#
# Two questions, two modes:
#   tree     what a stranger sees when they clone: the tracked working tree. Exits 1 on any hit.
#   history  what a stranger sees with `git log`: every commit on a branch or remote-tracking ref,
#            plus the notes refs. Reports only — history is never rewritten by this script.
#
# Usage:
#   scripts/scan-personal-data.sh                 # tree (default)
#   scripts/scan-personal-data.sh --mode history
#   scripts/scan-personal-data.sh --mode all
#   scripts/scan-personal-data.sh -p 'acme-corp' -p 'someone@example\.com'
#
# Extending: add an ERE to PATTERNS, or a pathspec to EXCLUDES, below. Both are plain arrays.
# Patterns are extended regular expressions as `git grep -E` understands them; keep them free of
# GNU-only escapes (`\b`) so they behave the same on macOS.
set -uo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# What counts as personal data. Add to this list; nothing else needs editing.
# ---------------------------------------------------------------------------
PATTERNS=(
  # Credentials and tokens — these must never appear anywhere, at any time.
  'ghp_'                              # GitHub personal access token
  'gho_|ghu_|ghs_|ghr_'               # other GitHub token prefixes
  'github_pat_'                       # GitHub fine-grained PAT
  'sk-ant'                            # Anthropic API key
  '(^|[^A-Za-z0-9_.-])sk-[A-Za-z0-9]' # generic "sk-" secret key (guarded: not disk-, task-, mask-)
  'AKIA[0-9A-Z]{16}'                  # AWS access key id
  'BEGIN (RSA|OPENSSH|DSA|EC|PGP) PRIVATE KEY'

  # This machine and this person.
  '/Users/thomaskrantz'               # the author's home directory
  '/Users/thomas([/"[:space:]]|$)'    # a shortened form that leaked into test fixtures
  'thomas@tkz\.se'                    # the author's email
  'Thomas|thomaskrantz|Krantz'        # the author's name (LICENSE is excluded below)
  '//tkz\.se'                         # the author's personal domain (se.tkz.tkzmux is the app id)

  # Account labels. Accounts are discovered at runtime and configured, never named in code
  # (CLAUDE.md: "No personal names or account labels in code; they come from config").
  'claude-alt'

  # Real client / employer / project names that used to live in the sample state.
  'Almi|almi'
  '[Ff]ront[Ii]nvest'
  '[Cc]ore ?[Ii]nvest|core-invest'
  'Workamo|workamo'
  '(^|[^A-Za-z])[Aa]ira([^A-Za-z]|$)'  # bounded: "repairable" is not a hit
  'mac-dash'
)

# Paths that are allowed to match. Everything here is either a legitimate attribution or the
# scanner itself (which necessarily contains every pattern).
EXCLUDES=(
  ':(exclude)scripts/scan-personal-data.sh'
  ':(exclude)LICENSE'                 # "Copyright (c) 2026 Thomas Krantz" is the point of the file
  ':(exclude)vendor'                  # third-party text; the *binaries* under it are scanned below
)

# Committed binaries `git grep -I` would skip. A compiler embeds absolute source and cache paths in
# an object file, so a prebuilt archive can carry the build machine's home directory into a public
# repo. Scanned with `strings`, against the same PATTERNS.
BINARY_ROOTS=(vendor)

MODE=tree
while (($#)); do
  case "$1" in
    --mode) MODE="${2:?--mode needs tree|history|notes|all}"; shift 2 ;;
    -p|--pattern) PATTERNS+=("${2:?-p needs a pattern}"); shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in tree|history|notes|all) ;; *) echo "unknown mode: $MODE" >&2; exit 2 ;; esac

hits=0

scan_tree() {
  # `--untracked` so a file that is written but not yet committed is checked too; git-ignored
  # paths (`.build/`, `build/`) stay out on their own.
  echo "== working tree (tracked + untracked files) =="
  local pattern found
  for pattern in "${PATTERNS[@]}"; do
    found="$(git grep -n -I -E --untracked -e "$pattern" -- . "${EXCLUDES[@]}" 2>/dev/null)" || true
    if [[ -n "$found" ]]; then
      hits=$((hits + 1))
      echo
      echo "-- $pattern"
      printf '%s\n' "$found"
    fi
  done
  scan_binaries
  echo
  if ((hits)); then
    echo "FAIL: $hits pattern(s) matched in the working tree."
  else
    echo "OK: no pattern matched in the working tree."
  fi
}

scan_binaries() {
  local file pattern found strung
  for file in $(git ls-files -- "${BINARY_ROOTS[@]}" 2>/dev/null); do
    [[ -f "$file" ]] || continue
    strung="$(strings -- "$file" 2>/dev/null)" || continue
    for pattern in "${PATTERNS[@]}"; do
      found="$(printf '%s\n' "$strung" | grep -E -e "$pattern" | sort -u | head -10)" || true
      if [[ -n "$found" ]]; then
        hits=$((hits + 1))
        echo
        echo "-- $pattern  (embedded in the binary $file)"
        printf '%s\n' "$found" | sed 's/^/   /'
      fi
    done
  done
}

scan_history() {
  echo "== history (branches + remote-tracking refs) =="
  echo "   Reporting only — this script never rewrites history."
  local pattern commits n
  for pattern in "${PATTERNS[@]}"; do
    commits="$(git log --branches --remotes --format='%h %ad %s' --date=short \
                 -S"$pattern" --pickaxe-regex 2>/dev/null)" || true
    [[ -z "$commits" ]] && continue
    n="$(printf '%s\n' "$commits" | wc -l | tr -d ' ')"
    echo
    echo "-- $pattern  ($n commit(s))"
    printf '%s\n' "$commits"
    echo "   files:"
    git log --branches --remotes --format='' --name-only -S"$pattern" --pickaxe-regex 2>/dev/null \
      | grep -v '^$' | sort -u | sed 's/^/     /'
  done
}

scan_notes() {
  echo
  echo "== notes refs (git notes are not part of branch history, but do get pushed on demand) =="
  local refs ref pattern found
  refs="$(git for-each-ref --format='%(refname)' 'refs/notes/*' 2>/dev/null)" || true
  if [[ -z "$refs" ]]; then
    echo "   no notes refs."
    return
  fi
  for ref in $refs; do
    echo
    echo "-- $ref  ($(git rev-list --count "$ref" 2>/dev/null) commit(s))"
    for pattern in "${PATTERNS[@]}"; do
      found="$(git grep -c -I -E -e "$pattern" "$ref" 2>/dev/null | head -5)" || true
      [[ -n "$found" ]] && echo "   matches $pattern:" && printf '%s\n' "$found" | sed 's/^/     /'
    done
  done
}

case "$MODE" in
  tree)    scan_tree ;;
  history) scan_history ;;
  notes)   scan_notes ;;
  all)     scan_tree; echo; scan_history; scan_notes ;;
esac

# Only the working tree gates: history findings are a decision for a human, not a build failure.
if [[ "$MODE" == tree || "$MODE" == all ]] && ((hits)); then
  exit 1
fi
exit 0
