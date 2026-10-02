#!/usr/bin/env bash
# check-binary.sh: symbol and ELF checks for a final Linux executable that links libghostty-vt.
# It is read-only: it inspects the ELF and never modifies it.
#
# libghostty-vt's archive carries zig's compiler_rt, which defines libc/libm names (memcpy,
# memmove, memset, exp, ...) as weak hidden globals. scripts/build-ghostty-vt-linux.sh localizes
# them, so every object in the executable, Swift code and a static Swift runtime included, keeps
# calling glibc. This script proves that on the linked result, which the archive checks cannot:
#
#   exports      `nm -D --defined-only` must not export memcpy, memmove or memset.
#   glibc-bind   `nm -D --undefined-only` must import memcpy, memmove and memset @GLIBC_*.
#   call-sites   `objdump -d` must show no call or jump to a local memcpy/memmove body from a
#                function outside compiler_rt; those calls belong on @plt. A local `t memcpy`
#                in the symbol table is harmless by itself: compiler_rt's own calls use it.
#   glibc-max    the highest GLIBC_ version the ELF needs must not exceed the ceiling: the
#                section's `glibc-max` line in docs/linux/linkage-policy.txt, or --max-glibc.
#   gnu-stack    PT_GNU_STACK must exist and must not be executable (RWE).
#   linkage      scripts/linux/check-linkage.sh <elf> <section>. NEEDED and RUNPATH rules live
#                only in linkage-policy.txt and are checked only there; this script names no library.
#
# A fully static ELF (no dynamic section, e.g. the musl hook of WOR-305 S6) has no glibc imports
# to bind to, so exports, glibc-bind, call-sites and glibc-max are reported as not applicable.
#
# Usage:
#   scripts/linux/check-binary.sh [options] <elf> --section <section>
#
#   --section NAME    a checkable section of linkage-policy.txt: tkzmux or tkzmux-hook (any
#                     section with a `glibc-max` line, or with --max-glibc, works)
#   --max-glibc X.Y   GLIBC_ ceiling; overrides the section's `glibc-max` line
#   --archive FILE    the libghostty-vt.a whose compiler_rt.o functions may call a local
#                     memcpy/memmove (default: the committed artifact bundle's archive)
#   --policy FILE     use FILE instead of docs/linux/linkage-policy.txt (passed on to check-linkage.sh)
#   -q, --quiet       print only violations and the final verdict
#   -h, --help        show this help
#
# Env: NM, OBJDUMP and READELF override the binutils tools.
#
# Exit status: 0 = every check passes, 1 = at least one violation, 2 = usage, policy or tool error.
#
# Examples:
#   scripts/linux/check-binary.sh .build/release/tkzmux --section tkzmux
#   scripts/linux/check-binary.sh .build/release/tkzmux-hook --section tkzmux-hook --max-glibc 2.35
set -uo pipefail
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
policy="$root/docs/linux/linkage-policy.txt"
archive="$root/vendor/ghostty-vt/ghostty-vt-linux.artifactbundle/x86_64-unknown-linux-gnu/libghostty-vt.a"
section=""
max_glibc=""
quiet=0
elf=""

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "check-binary: $*" >&2; exit 2; }
say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }

# One case per option. WOR-323 S1 adds its --no-avx512 and PIE checks here, each as a flag
# plus one more check_* function below.
while [ $# -gt 0 ]; do
  case "$1" in
    --section) [ $# -ge 2 ] || die "--section needs a name"; section="$2"; shift 2 ;;
    --section=*) section="${1#--section=}"; shift ;;
    --max-glibc) [ $# -ge 2 ] || die "--max-glibc needs a version"; max_glibc="$2"; shift 2 ;;
    --max-glibc=*) max_glibc="${1#--max-glibc=}"; shift ;;
    --archive) [ $# -ge 2 ] || die "--archive needs a file"; archive="$2"; shift 2 ;;
    --archive=*) archive="${1#--archive=}"; shift ;;
    --policy) [ $# -ge 2 ] || die "--policy needs a file"; policy="$2"; shift 2 ;;
    --policy=*) policy="${1#--policy=}"; shift ;;
    -q|--quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$elf" ] || die "one ELF per run (got '$elf' and '$1')"; elf="$1"; shift ;;
  esac
done

[ -n "$elf" ] || { usage >&2; die "no ELF given"; }
[ -n "$section" ] || die "--section is required"
section="${section#[}"; section="${section%]}"
[ -f "$elf" ] || die "no such file: $elf"
[ -r "$policy" ] || die "policy file not readable: $policy"
awk -v want="[$section]" '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "") } $0 == want { found = 1 } END { exit !found }' "$policy" \
  || die "no section [$section] in $policy"

nm_bin="${NM:-nm}"; objdump_bin="${OBJDUMP:-objdump}"; readelf_bin="${READELF:-readelf}"
for tool in "$nm_bin" "$objdump_bin" "$readelf_bin"; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found (install binutils)"
done

hdr="$("$readelf_bin" -hW "$elf" 2>/dev/null)" || die "not an ELF file: $elf"
grep -q 'Advanced Micro Devices X86-64' <<< "$hdr" || die "not an x86_64 ELF: $elf"

# The ceiling: --max-glibc, else the `glibc-max` line inside [section]. The policy grammar is
# check-linkage.sh's; only that one directive is read here.
if [ -z "$max_glibc" ]; then
  max_glibc="$(awk -v want="[$section]" '
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    /^\[/ { in_section = ($0 == want); next }
    in_section && $1 == "glibc-max" { print $2; exit }' "$policy")"
  [ -n "$max_glibc" ] || die "[$section] in $policy has no glibc-max line; pass --max-glibc"
fi
[[ "$max_glibc" =~ ^[0-9]+\.[0-9]+$ ]] || die "--max-glibc must look like 2.35, got '$max_glibc'"

fails=0
pass() { say "   ok    $1: $2"; }
fail() { echo "   FAIL  $1: $2"; fails=$((fails + 1)); }
na()   { say "   n/a   $1: $2"; }

dynsec="$("$readelf_bin" -SW "$elf" | grep -c ' \.dynamic ' || true)"
dynamic=1; [ "$dynsec" -eq 0 ] && dynamic=0

say "check-binary: $elf  [$section]  glibc-max $max_glibc"

# --------------------------------------------------------------------------------- exports
check_exports() {
  local exported
  exported="$("$nm_bin" -D --defined-only "$elf" 2>/dev/null | awk '{ sub(/@.*/, "", $NF); print $NF }' \
    | grep -xE 'memcpy|memmove|memset' | sort -u | tr '\n' ' ')"
  if [ -n "$exported" ]; then
    fail exports "the ELF exports ${exported% }, so its own copy shadows glibc's (see linux-localize-symbols.txt)"
  else
    pass exports "memcpy/memmove/memset are not exported"
  fi
}

# ------------------------------------------------------------------------------ glibc-bind
check_glibc_bind() {
  local imports name missing=""
  imports="$("$nm_bin" -D --undefined-only "$elf" 2>/dev/null | awk '{ print $NF }')"
  for name in memcpy memmove memset; do
    grep -qE "^$name@GLIBC_[0-9.]+$" <<< "$imports" || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    fail glibc-bind "no${missing} @GLIBC_* import; the ELF's own calls bind to a local copy instead of glibc"
  else
    pass glibc-bind "memcpy, memmove and memset import @GLIBC_*"
  fi
}

# ------------------------------------------------------------------------------ call-sites
check_call_sites() {
  if ! "$readelf_bin" -SW "$elf" | grep -q ' \.symtab '; then
    fail call-sites "the ELF has no .symtab, so local memcpy/memmove bodies cannot be told from @plt; check it before stripping"
    return
  fi
  [ -r "$archive" ] || die "archive not readable: $archive (see --archive)"
  local crt bodies result
  # The entry addresses of every memcpy/memmove body linked into the ELF. objdump names a call
  # target after any alias at that address (compiler_rt.memcpy.memcpyFast, ...), so calls are
  # matched by address, not by the name it prints.
  bodies="$("$nm_bin" --defined-only "$elf" 2>/dev/null \
    | awk '$NF == "memcpy" || $NF == "memmove" { a = $1; sub(/^0+/, "", a); print a }' | sort -u | tr '\n' ' ')"
  if [ -z "$bodies" ]; then
    pass call-sites "no local memcpy/memmove body is linked in; every call goes through @plt"
    return
  fi
  crt="$(mktemp)"
  # Every symbol compiler_rt.o defines, local or global: those functions may call its own copies.
  "$nm_bin" -A --defined-only "$archive" 2>/dev/null \
    | awk -F: '$2 == "compiler_rt.o" { n = split($3, f, " "); print f[n] }' | sort -u > "$crt"
  if [ ! -s "$crt" ]; then
    rm -f "$crt"
    die "no compiler_rt.o member in $archive"
  fi
  # A call, or a jump (tail call), whose target is one of those entry addresses.
  result="$("$objdump_bin" -d --no-show-raw-insn "$elf" 2>/dev/null | awk -v crtfile="$crt" -v bodies="$bodies" '
    BEGIN {
      while ((getline l < crtfile) > 0) crt[l] = 1
      n = split(bodies, b, " "); for (i = 1; i <= n; i++) body[b[i]] = 1
    }
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /\t(bnd |notrack )?(call|j)[a-z]*[[:space:]]+[0-9a-f]+ </ {
      t = $0; sub(/.*\t(bnd |notrack )?(call|j)[a-z]*[[:space:]]+/, "", t); sub(/ .*/, "", t)
      if (!(t in body)) next
      if (fn in crt) { own++; next }
      bad++; if (bad <= 5) print "      " fn " -> " $NF
    }
    END { if (bad > 5) print "      ... " bad - 5 " more"; print "own=" own + 0 }')"
  rm -f "$crt"
  if [ "$(grep -vc '^own=' <<< "$result")" -gt 0 ]; then
    fail call-sites "calls outside compiler_rt reach a local memcpy/memmove body instead of @plt:"
    grep -v '^own=' <<< "$result"
  else
    pass call-sites "no call outside compiler_rt reaches a local memcpy/memmove body (${result#own=} from compiler_rt itself)"
  fi
}

# ------------------------------------------------------------------------------- glibc-max
check_glibc_max() {
  local versions top worst
  # .gnu.version_r lists every version the ELF needs, one `Name: GLIBC_x.y` line each.
  versions="$("$readelf_bin" -VW "$elf" 2>/dev/null | grep -oE 'Name: GLIBC_[0-9]+(\.[0-9]+)+' \
    | sed 's/^Name: GLIBC_//' | sort -uV)"
  if [ -z "$versions" ]; then
    fail glibc-max "the ELF needs no GLIBC_ version; is it linked against glibc?"
    return
  fi
  top="$(tail -n 1 <<< "$versions")"
  if [ "$(printf '%s\n%s\n' "$top" "$max_glibc" | sort -V | tail -n 1)" = "$max_glibc" ]; then
    pass glibc-max "highest GLIBC_$top <= $max_glibc"
  else
    worst="$("$nm_bin" -D --undefined-only "$elf" 2>/dev/null | awk '{ print $NF }' \
      | awk -F'@' -v max="$max_glibc" '{
          v = $2; sub(/^GLIBC_/, "", v)
          if ($2 !~ /^GLIBC_[0-9]/) next
          split(v, a, "."); split(max, m, ".")
          if (a[1] + 0 > m[1] + 0 || (a[1] + 0 == m[1] + 0 && a[2] + 0 > m[2] + 0)) print $0
        }' | sort -u | head -8 | tr '\n' ' ')"
    fail glibc-max "needs GLIBC_$top, above the $max_glibc ceiling: ${worst% }"
  fi
}

# ------------------------------------------------------------------------------- gnu-stack
check_gnu_stack() {
  local line flags
  line="$("$readelf_bin" -lW "$elf" | grep -E '^[[:space:]]*GNU_STACK[[:space:]]' || true)"
  if [ -z "$line" ]; then
    fail gnu-stack "no PT_GNU_STACK header; the loader would make the stack executable"
    return
  fi
  # GNU_STACK Offset VirtAddr PhysAddr FileSiz MemSiz Flg Align. Flg is "RW " or "RWE" and may
  # contain blanks ("R E"), so it is every column between MemSiz and Align.
  flags="$(awk '{ f = ""; for (i = 7; i < NF; i++) f = f $i; print f }' <<< "$line")"
  if [[ "$flags" == *E* ]]; then
    fail gnu-stack "PT_GNU_STACK is $flags (executable stack)"
  else
    pass gnu-stack "PT_GNU_STACK is $flags"
  fi
}

if [ "$dynamic" -eq 1 ]; then
  check_exports
  check_glibc_bind
  check_call_sites
  check_glibc_max
else
  for c in exports glibc-bind call-sites glibc-max; do
    na "$c" "statically linked (no .dynamic): nothing binds to glibc at run time"
  done
fi
check_gnu_stack

# --------------------------------------------------------------------------------- linkage
# Delegated; the shared-library rules are linkage-policy.txt's alone.
linkage_args=(--policy "$policy")
[ "$quiet" -eq 1 ] && linkage_args+=(--quiet)
"$script_dir/check-linkage.sh" "${linkage_args[@]}" "$elf" "$section" | sed 's/^/   | /'
linkage_status="${PIPESTATUS[0]}"
case "$linkage_status" in
  0) pass linkage "check-linkage.sh [$section] passed" ;;
  1) fail linkage "check-linkage.sh [$section] failed (rules: ${policy#"$root/"})" ;;
  *) die "check-linkage.sh exited $linkage_status" ;;
esac

if [ "$fails" -eq 0 ]; then
  echo "PASS  $elf  [$section]"
  exit 0
fi
echo "FAIL  $elf  [$section]  ($fails check(s) failed)"
exit 1
