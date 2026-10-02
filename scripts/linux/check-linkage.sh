#!/usr/bin/env bash
# check-linkage.sh: check the direct NEEDED (and RUNPATH/RPATH) entries of Linux ELF binaries
# against one section of docs/linux/linkage-policy.txt.
#
# This is the only NEEDED check in the repo. check-binary.sh (WOR-302), ci-linux.yml (WOR-303),
# the hook (WOR-305), release (WOR-323) and packaging (WOR-324) all call it, and none of them
# keeps its own list of libraries. Every allow/deny rule lives in the policy file, and this
# script hard-codes none.
#
# What is gated: `readelf -d` NEEDED and RUNPATH/RPATH entries, and nothing else. The ldd closure
# count is printed for information only. GTK brings about 112 libraries (X11, systemd, dbus, ...)
# into the closure, so a closure gate would fail every build. See ADR-0002, "Linkage enforcement".
#
# Usage:
#   scripts/linux/check-linkage.sh [options] <elf>... <section>
#   scripts/linux/check-linkage.sh [options] --section <section> <elf>...
#   scripts/linux/check-linkage.sh [options] --lint
#
#   <section>         a checkable policy section: tkzmux, tkzmux-hook, tkzmux-vtdump or tests.
#                     Both `tkzmux` and `[tkzmux]` are accepted.
#   --policy FILE     use FILE instead of docs/linux/linkage-policy.txt
#   --no-closure      skip the informational ldd closure count. ldd runs the binary's loader,
#                     so use this for binaries you did not build.
#   --lint            validate the policy file only, then exit
#   -q, --quiet       print only violations and the final verdict
#   -h, --help        show this help
#
# Env: READELF overrides the readelf binary. llvm-readelf also works.
#
# Exit status: 0 = every ELF passes, 1 = at least one violation, 2 = usage, policy or tool error.
#
# Examples:
#   scripts/linux/check-linkage.sh .build/release/tkzmux tkzmux
#   scripts/linux/check-linkage.sh .build/release/tkzmux-hook tkzmux-hook
#   scripts/linux/check-linkage.sh /usr/bin/curl tkzmux     # fails, naming libcurl.so.4
set -uo pipefail
export LC_ALL=C   # deterministic glob ranges ([a-z]) and readelf output

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "check-linkage: needs bash >= 4 (associative arrays)" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$script_dir/../../docs/linux/linkage-policy.txt"
section=""
lint_only=0
closure=1
quiet=0
elfs=()

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "check-linkage: $*" >&2; exit 2; }
say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) [ $# -ge 2 ] || die "--policy needs a file"; policy="$2"; shift 2 ;;
    --policy=*) policy="${1#--policy=}"; shift ;;
    --section) [ $# -ge 2 ] || die "--section needs a name"; section="$2"; shift 2 ;;
    --section=*) section="${1#--section=}"; shift ;;
    --no-closure) closure=0; shift ;;
    --lint) lint_only=1; shift ;;
    -q|--quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; elfs+=("$@"); break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) elfs+=("$1"); shift ;;
  esac
done

[ -r "$policy" ] || die "policy file not readable: $policy"

# --------------------------------------------------------------------------- policy parsing
# One rule per index across these parallel arrays.
R_OWNER=()   # section or @group the rule was written in
R_KIND=()    # allow | deny | runpath-allow | runpath-deny
R_PAT=()     # glob
R_WHY=()     # justification
R_NOTE=()    # optional note (e.g. "measured-by: WOR-300 S4"), may be empty
R_LINE=()    # policy line number, for messages
declare -A S_EXISTS=() S_STDLIB=() S_STATUS=() S_GLIBC=() S_INCLUDES=() S_LINE=()
errors=0

perr() { echo "check-linkage: $policy:$1: $2" >&2; errors=$((errors + 1)); }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

current=""
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  line="$(trim "$raw")"
  [ -z "$line" ] && continue
  [ "${line:0:1}" = "#" ] && continue

  if [[ "$line" =~ ^\[(@?[A-Za-z0-9_.-]+)\]$ ]]; then
    current="${BASH_REMATCH[1]}"
    [ -n "${S_EXISTS[$current]:-}" ] && perr "$lineno" "duplicate section [$current]"
    S_EXISTS[$current]=1
    S_LINE[$current]=$lineno
    continue
  fi
  [ -n "$current" ] || { perr "$lineno" "directive outside any section: $line"; continue; }

  verb="${line%%[[:space:]]*}"
  rest="$(trim "${line#"$verb"}")"
  case "$verb" in
    stdlib)
      case "$rest" in
        static|dynamic) S_STDLIB[$current]="$rest" ;;
        *) perr "$lineno" "stdlib must be static or dynamic, got '$rest'" ;;
      esac
      [ "${current:0:1}" = "@" ] && perr "$lineno" "stdlib belongs in a checkable section, not group [$current]"
      ;;
    status)
      [ -n "$rest" ] || perr "$lineno" "empty status"
      S_STATUS[$current]="$rest" ;;
    glibc-max)
      [[ "$rest" =~ ^[0-9]+\.[0-9]+$ ]] || perr "$lineno" "glibc-max must look like 2.35, got '$rest'"
      S_GLIBC[$current]="$rest" ;;
    include)
      [ -n "$rest" ] || perr "$lineno" "include needs at least one @group"
      for g in $rest; do
        [ "${g:0:1}" = "@" ] || perr "$lineno" "include takes @groups only, got '$g'"
      done
      S_INCLUDES[$current]="${S_INCLUDES[$current]:-} $rest" ;;
    allow|deny|runpath-allow|runpath-deny)
      IFS='|' read -r -a cols <<< "$rest"
      for i in "${!cols[@]}"; do cols[i]="$(trim "${cols[i]}")"; done
      pat="${cols[0]:-}"
      if [ "$verb" = "allow" ]; then
        need=4; why="${cols[3]:-}"; note="${cols[4]:-}"
        { [ -n "${cols[1]:-}" ] && [ -n "${cols[2]:-}" ]; } \
          || perr "$lineno" "allow needs: <glob> | <arch pkg> | <ubuntu pkg> | <justification>"
      else
        need=2; why="${cols[1]:-}"; note="${cols[2]:-}"
      fi
      [ -n "$pat" ] || perr "$lineno" "$verb without a pattern"
      [[ "$pat" =~ [[:space:]] ]] && perr "$lineno" "pattern contains whitespace: '$pat'"
      if [ "${#cols[@]}" -lt "$need" ] || [ -z "$why" ]; then
        perr "$lineno" "$verb $pat has no justification"
      fi
      [ "${#cols[@]}" -le $((need + 1)) ] || perr "$lineno" "$verb $pat has too many | columns"
      R_OWNER+=("$current"); R_KIND+=("$verb"); R_PAT+=("$pat")
      R_WHY+=("$why"); R_NOTE+=("$note"); R_LINE+=("$lineno") ;;
    *) perr "$lineno" "unknown directive '$verb'" ;;
  esac
done < "$policy"

[ -n "${S_EXISTS[@swift-runtime]:-}" ] || perr 0 "missing group [@swift-runtime] (used by stdlib static|dynamic)"
for s in "${!S_EXISTS[@]}"; do
  if [ "${s:0:1}" != "@" ] && [ -z "${S_STDLIB[$s]:-}" ]; then
    perr "${S_LINE[$s]}" "section [$s] has no 'stdlib static|dynamic' line"
  fi
  for g in ${S_INCLUDES[$s]:-}; do
    [ -n "${S_EXISTS[$g]:-}" ] || perr "${S_LINE[$s]}" "[$s] includes unknown group [$g]"
  done
done
for i in "${!R_KIND[@]}"; do
  if [ "${R_OWNER[i]}" = "@swift-runtime" ] && [ "${R_KIND[i]}" != "allow" ]; then
    perr "${R_LINE[i]}" "[@swift-runtime] may hold allow lines only"
  fi
done

[ "$errors" -eq 0 ] || die "policy has $errors error(s); fix $policy"

checkable=()
for s in "${!S_EXISTS[@]}"; do [ "${s:0:1}" = "@" ] || checkable+=("$s"); done
mapfile -t checkable < <(printf '%s\n' "${checkable[@]}" | sort)

if [ "$lint_only" -eq 1 ]; then
  echo "check-linkage: policy OK: ${#R_KIND[@]} rules, sections: ${checkable[*]}"
  exit 0
fi

# ------------------------------------------------------------------------- arguments
if [ -z "$section" ]; then
  [ "${#elfs[@]}" -ge 2 ] || { usage >&2; die "need <elf>... <section>"; }
  section="${elfs[-1]}"
  unset 'elfs[-1]'
fi
[ "${#elfs[@]}" -ge 1 ] || die "no ELF files given"
section="${section#[}"; section="${section%]}"
[ "${section:0:1}" != "@" ] || die "[$section] is a shared group, not a checkable section"
[ -n "${S_EXISTS[$section]:-}" ] || die "no section [$section] in $policy (have: ${checkable[*]})"

readelf_bin="${READELF:-}"
if [ -z "$readelf_bin" ]; then
  if command -v readelf >/dev/null 2>&1; then readelf_bin=readelf
  elif command -v llvm-readelf >/dev/null 2>&1; then readelf_bin=llvm-readelf
  else die "readelf not found (install binutils, or set READELF)"; fi
fi

# ------------------------------------------------------------------- effective rule set
# Expand includes depth-first; a group included twice contributes once.
declare -A seen_group=()
eff=()   # rule indices that apply to $section
collect() {
  local owner="$1" depth="$2" g i
  [ "$depth" -le 16 ] || die "include nesting too deep at [$owner] (cycle?)"
  for i in "${!R_OWNER[@]}"; do [ "${R_OWNER[i]}" = "$owner" ] && eff+=("$i"); done
  for g in ${S_INCLUDES[$owner]:-}; do
    [ -n "${seen_group[$g]:-}" ] && continue
    seen_group[$g]=1
    collect "$g" $((depth + 1))
  done
}
collect "$section" 0
stdlib="${S_STDLIB[$section]}"
swift_rt=()
for i in "${!R_OWNER[@]}"; do [ "${R_OWNER[i]}" = "@swift-runtime" ] && swift_rt+=("$i"); done

where() { local o="${R_OWNER[$1]}"; printf '[%s] line %s' "$o" "${R_LINE[$1]}"; }

# verdict <kind-prefix> <value>  ->  sets V_OK (0/1), V_MSG
# kind-prefix is "" for NEEDED entries and "runpath-" for RUNPATH entries.
verdict() {
  local pre="$1" val="$2" i
  for i in "${eff[@]}"; do
    # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
    if [ "${R_KIND[i]}" = "${pre}deny" ] && [[ "$val" == ${R_PAT[i]} ]]; then
      V_OK=0; V_MSG="DENIED by ${R_PAT[i]} ($(where "$i")): ${R_WHY[i]}"; return
    fi
  done
  if [ -z "$pre" ]; then
    for i in "${swift_rt[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$val" == ${R_PAT[i]} ]]; then
        if [ "$stdlib" = "static" ]; then
          V_OK=0; V_MSG="DENIED: [$section] declares stdlib=static, so the Swift runtime must be linked in, not NEEDED (${R_PAT[i]}, $(where "$i"))"
        else
          V_OK=1; V_MSG="ok (stdlib=dynamic: ${R_PAT[i]})"
        fi
        return
      fi
    done
  fi
  for i in "${eff[@]}"; do
    # shellcheck disable=SC2053
    if [ "${R_KIND[i]}" = "${pre}allow" ] && [[ "$val" == ${R_PAT[i]} ]]; then
      V_OK=1; V_MSG="ok (${R_PAT[i]}, $(where "$i"))"
      [ -n "${R_NOTE[i]}" ] && V_MSG="$V_MSG [${R_NOTE[i]}]"
      return
    fi
  done
  V_OK=0
  if [ -z "$pre" ]; then V_MSG="NOT ALLOWED: no allow rule in [$section] matches"
  else V_MSG="NOT ALLOWED: [$section] allows no such RUNPATH/RPATH entry"; fi
}

# ------------------------------------------------------------------------------- check
say "check-linkage: section [$section], stdlib=$stdlib${S_GLIBC[$section]:+, glibc-max ${S_GLIBC[$section]} (enforced by check-binary.sh)}"
[ -n "${S_STATUS[$section]:-}" ] && say "check-linkage: status: ${S_STATUS[$section]}"

total_fail=0
for elf in "${elfs[@]}"; do
  [ -f "$elf" ] || { echo "check-linkage: no such file: $elf" >&2; exit 2; }
  if ! hdr="$("$readelf_bin" -h "$elf" 2>&1)" || ! grep -q 'ELF Header' <<< "$hdr"; then
    echo "check-linkage: not an ELF file: $elf" >&2; exit 2
  fi
  dyn="$("$readelf_bin" -dW "$elf" 2>&1)" || { echo "check-linkage: $readelf_bin -d failed on $elf: $dyn" >&2; exit 2; }

  needed=(); paths=()
  while IFS= read -r l; do
    if [[ "$l" =~ \(NEEDED\).*\[([^]]+)\] ]]; then
      needed+=("${BASH_REMATCH[1]}")
    elif [[ "$l" =~ \((RUNPATH|RPATH)\).*\[([^]]*)\] ]]; then
      IFS=':' read -r -a parts <<< "${BASH_REMATCH[2]}"
      for p in "${parts[@]}"; do paths+=("${BASH_REMATCH[1]}=$p"); done
    fi
  done <<< "$dyn"

  say ""
  say "== $elf"
  fails=0
  if [ "${#needed[@]}" -eq 0 ] && grep -qi 'no dynamic section' <<< "$dyn"; then
    say "   (no dynamic section: statically linked, nothing NEEDED)"
  fi
  for lib in "${needed[@]}"; do
    verdict "" "$lib"
    if [ "$V_OK" -eq 1 ]; then say "   NEEDED  $lib  $V_MSG"
    else echo "   NEEDED  $lib  $V_MSG"; fails=$((fails + 1)); fi
  done
  for entry in "${paths[@]}"; do
    tag="${entry%%=*}"; p="${entry#*=}"
    verdict "runpath-" "$p"
    if [ "$V_OK" -eq 1 ]; then say "   $tag $p  $V_MSG"
    else echo "   $tag $p  $V_MSG"; fails=$((fails + 1)); fi
  done

  if [ "$closure" -eq 1 ] && [ "$quiet" -eq 0 ] && command -v ldd >/dev/null 2>&1; then
    if out="$(ldd "$elf" 2>/dev/null)"; then
      n="$(grep -c '=>' <<< "$out")"
      missing="$(grep -c 'not found' <<< "$out")"
      extra=""; [ "$missing" -gt 0 ] && extra=", $missing not found"
      say "   info: ldd closure = $n shared objects$extra (not gated)"
    else
      say "   info: ldd closure unavailable (static binary, or not loadable here)"
    fi
  fi

  if [ "$fails" -eq 0 ]; then
    echo "PASS  $elf  [$section]  (${#needed[@]} NEEDED, ${#paths[@]} RUNPATH/RPATH)"
  else
    echo "FAIL  $elf  [$section]  ($fails violation(s))"
    total_fail=$((total_fail + 1))
  fi
done

[ "$total_fail" -eq 0 ] || exit 1
exit 0
