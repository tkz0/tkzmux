#!/usr/bin/env bash
# asan-valgrind.sh — the sanitizer runs of the asan-valgrind CI job (WOR-314 S2).
#
#   scripts/linux/asan-valgrind.sh asan [swift test args…]
#   scripts/linux/asan-valgrind.sh valgrind [cycles]
#
# Both include the GTK window checks, so they need a Wayland display, and they set
# TKZMUX_REQUIRE_DISPLAY=1. CI, or a local run that should not open windows on the desktop, gives
# them a headless sway and, inside it, a private session bus:
#
#   scripts/linux/headless-sway.sh dbus-run-session -- scripts/linux/asan-valgrind.sh asan
#
# Both also set GSK_RENDERER=cairo (GPU drivers stay out of the window checks),
# GDK_DEBUG=no-portals (GTK does not start xdg-desktop-portal on the private bus) and
# GIO_USE_VFS=local (GIO does not activate gvfsd there either).
#
# asan      `swift test --sanitize=address --no-parallel` in its own scratch path (.build/asan), so
#           the debug build is untouched. AddressSanitizer and LeakSanitizer run in the test runner
#           and in every `tkzmux` child the tests start (CanvasCycleTests, MainLoopBridgeTests,
#           InstalledStubTests), with scripts/linux/asan.supp and scripts/linux/lsan.supp, and write
#           their reports to .build/asan-reports. It fails on any AddressSanitizer error, on a test
#           failure, without Swift Testing's `Test run with N tests` line (N > 0, the CI rule of
#           ci-linux.yml), and on a leak owned by Tkz code (below).
# valgrind  Memcheck on the debug `tkzmux --canvas-cycle-check --cycles <cycles>` (default 100),
#           with scripts/linux/valgrind.supp; the log is kept at .build/valgrind-canvas-cycle.log.
#           It fails when the check fails, on an error with a Tkz frame among the innermost 8
#           frames of any of its stacks, and on a definite leak owned by Tkz code.
#
# Tkz code is every `tkz_*` C function and every Swift symbol of a Tkz module. A leak is owned by
# the first frame of its allocation stack that is not an allocator or runtime frame (malloc and
# friends, the Swift runtime and standard library, g_malloc, g_object_new, …), so a leaked
# TkzCanvas is tkz_canvas_new's and a leaked closure box is TkzGtkShell's. A rule of "any Tkz frame
# in the stack" would not do: everything GTK runs has the main loop (TkzGtkShell) further out.
# Records owned by the GTK shell layer, the C boundary S2 polices (`tkz_*`, TkzGtkShell,
# TkzLinuxShim, TkzmuxLinux), are counted as `shell`, those of other Tkz modules as `other-tkz`;
# both are fatal and printed in full. Third-party ones (one-time GTK, Mesa, fontconfig, Foundation
# and XCTest allocations) are listed on stderr and never fatal.
#
# Valgrind needs debug symbols for the dynamic loader (it must redirect ld.so's memcmp and strlen).
# Arch strips them into `glibc-debug`, and only the current version stays on the mirrors, so a
# pinned image or a machine that has not upgraded has none that match. Point TKZMUX_VALGRIND_GLIBC
# at the usr/lib of an unpacked glibc and glibc-debug of one version (scripts/linux/fetch-glibc-debug.sh
# makes one, and CI does): the check then runs through that loader, with that glibc.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

usage() {
  sed -n '4,5p' "$0" | sed 's/^#   //' >&2
  exit 64
}

need_display() {
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "asan-valgrind.sh: no WAYLAND_DISPLAY; run it under scripts/linux/headless-sway.sh" >&2
    exit 1
  fi
  export TKZMUX_REQUIRE_DISPLAY=1 GSK_RENDERER=cairo GDK_DEBUG=no-portals GIO_USE_VFS=local
}

# The awk program both gates share. Reads Memcheck (`==pid==`) or LeakSanitizer records on stdin.
# Prints each fatal (shell or other-tkz) record in full, lists the third-party ones on stderr, and
# ends with one line: `shell=<n> other-tkz=<n> third-party=<n>`.
# shellcheck disable=SC2016  # an awk program: its $ fields are awk's
gate_awk='
  function owner_of(fn) { return fn ~ shell ? "shell" : (fn ~ tkz ? "other-tkz" : "third-party") }
  function flush() {
    if (head != "" && frames > 0) {
      kind = leak ? owner_of(owner) : near
      count[kind]++
      if (kind != "third-party") print block "\n"
      else print "  " kind ": " head " | " (leak ? owner : first) > "/dev/stderr"
    }
    head = ""; block = ""; frames = 0; depth = 0; leak = 0; near = "third-party"; owner = ""; first = ""
  }
  function frame(fn) {
    frames++; depth++
    if (first == "" && fn !~ allocator) first = fn
    if (leak && owner == "" && fn !~ allocator) owner = fn
    if (depth <= 8 && near != "shell" && fn ~ tkz) near = owner_of(fn)
  }
  BEGIN {
    near = "third-party"
    shell = "(^tkz_|TkzGtkShell|TkzLinuxShim|TkzmuxLinux)"
    tkz = "(^tkz_|Tkz)"
    allocator = "^(malloc|calloc|realloc|reallocarray|posix_memalign|aligned_alloc|memalign|operator|strdup|strndup|" \
                "swift_|swift::|[$]ss|[$]sS[A-Za-z]|g_malloc|g_realloc|g_try_malloc|g_slice_|g_strdup|g_strndup|" \
                "g_memdup|g_type_create_instance|g_object_new)"
  }
  # LeakSanitizer
  /^(Direct|Indirect) leak of / { flush(); head = $0; block = $0; leak = 1; next }
  head != "" && /^ *#[0-9]+ / {
    block = block "\n" $0
    fn = $3
    if (match($0, / in [^ ]+/)) fn = substr($0, RSTART + 4, RLENGTH - 4)
    frame(fn)
    next
  }
  # Memcheck
  /^==[0-9]+== *$/ { flush(); next }
  /^==[0-9]+== / {
    line = $0; sub(/^==[0-9]+== /, "", line)
    if (head == "") { head = line; block = $0; leak = line ~ /definitely lost/; next }
    block = block "\n" $0
    if (line ~ /^   (at|by) 0x/) {
      fn = line; sub(/^   (at|by) 0x[0-9A-Fa-f]+: /, "", fn); sub(/ .*/, "", fn)
      frame(fn)
    } else {
      depth = 0   # the next stack of the same record: where the block was freed or allocated
    }
    next
  }
  head != "" { flush() }
  END {
    flush()
    print "shell=" count["shell"] + 0 " other-tkz=" count["other-tkz"] + 0 " third-party=" count["third-party"] + 0
  }
'

# Runs the gate over stdin; fails when it found a record owned by Tkz code.
gate() {
  local summary
  summary="$(awk "$gate_awk")"
  echo "$summary"
  [[ "$(tail -n 1 <<< "$summary")" == "shell=0 other-tkz=0 "* ]]
}

run_asan() {
  need_display
  local log reports=".build/asan-reports" status=0
  log="$(mktemp)"
  rm -rf "$reports"
  mkdir -p "$reports"
  # Inherited by every tkzmux child. Reports go to $reports/report.<pid>, not into the test output;
  # a memory error still exits non-zero (ASan's default), a leak does not (exitcode=0): leaks are
  # gated by owner below.
  export ASAN_OPTIONS="detect_leaks=1:detect_stack_use_after_return=1:suppressions=$repo/scripts/linux/asan.supp:log_path=$repo/$reports/report${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
  export LSAN_OPTIONS="suppressions=$repo/scripts/linux/lsan.supp:print_suppressions=0:exitcode=0${LSAN_OPTIONS:+:$LSAN_OPTIONS}"
  swift test --build-system native --sanitize=address --scratch-path .build/asan --no-parallel "$@" 2>&1 \
    | tee "$log" || status=$?
  local counts
  counts="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} .*/\1/p')"
  rm -f "$log"

  local errors
  errors="$(grep -l 'ERROR: AddressSanitizer' "$reports"/report.* 2> /dev/null || true)"
  if [ -n "$errors" ]; then
    while read -r report; do cat "$report" >&2; done <<< "$errors"
    echo "asan-valgrind.sh: AddressSanitizer errors (reports in $reports)" >&2
    exit 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "asan-valgrind.sh: swift test --sanitize=address failed ($status)" >&2
    exit "$status"
  fi
  if [ -z "$counts" ] || grep -qx 0 <<< "$counts"; then
    echo "asan-valgrind.sh: swift test ended without a 'Test run with N tests' line, or with N = 0" >&2
    exit 1
  fi
  if ! cat "$reports"/report.* 2> /dev/null | gate; then
    echo "asan-valgrind.sh: LeakSanitizer found leaks owned by Tkz code (reports in $reports)" >&2
    exit 1
  fi
  echo "asan-valgrind.sh: ASan green: $(awk '{ n += $1 } END { print n }' <<< "$counts") tests, no Tkz leak"
}

run_valgrind() {
  need_display
  local cycles="${1:-100}" log=".build/valgrind-canvas-cycle.log" status=0
  command -v valgrind > /dev/null || { echo "asan-valgrind.sh: valgrind is not installed" >&2; exit 127; }
  swift build --build-system native --product tkzmux
  local bin
  bin="$(swift build --build-system native --show-bin-path)/tkzmux"
  local args=(--leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite --num-callers=40
              --suppressions="$repo/scripts/linux/valgrind.supp" --log-file="$log")
  local command=("$bin" --canvas-cycle-check --cycles "$cycles")
  if [ -n "${TKZMUX_VALGRIND_GLIBC:-}" ]; then
    args+=(--extra-debuginfo-path="$TKZMUX_VALGRIND_GLIBC/debug")
    command=("$TKZMUX_VALGRIND_GLIBC/ld-linux-x86-64.so.2" --library-path
             "$TKZMUX_VALGRIND_GLIBC${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${command[@]}")
  fi
  valgrind "${args[@]}" "${command[@]}" || status=$?
  grep -E '(ERROR SUMMARY|definitely lost:)' "$log" || true
  if [ "$status" -ne 0 ]; then
    echo "asan-valgrind.sh: the canvas cycle check failed under Valgrind ($status); log: $log" >&2
    exit "$status"
  fi
  if ! gate < "$log"; then
    echo "asan-valgrind.sh: Valgrind found errors or definite leaks in Tkz code; log: $log" >&2
    exit 1
  fi
  echo "asan-valgrind.sh: Valgrind clean in Tkz code ($cycles cycles)"
}

[ $# -ge 1 ] || usage
mode="$1"
shift
case "$mode" in
  asan) run_asan "$@" ;;
  valgrind) run_valgrind "$@" ;;
  *) usage ;;
esac
