# tkzmux — pure SwiftPM. `make app` assembles build/tkzmux.app without an Xcode project.
#
#   SIGN_IDENTITY   codesign identity. Default "-" = ad-hoc: fine for local use, but Gatekeeper
#                   will quarantine it on anyone else's Mac. A "Developer ID Application: …"
#                   identity additionally turns on the hardened runtime + secure timestamp.
#   NOTARY_PROFILE  `xcrun notarytool store-credentials` keychain profile name.
#   VERSION         override the version derived from `git describe` (see scripts/lib/version.sh).
#   SWIFT_FLAGS     extra flags for `swift build`/`test`/`run`, e.g. `-c release`. Never a target
#                   selection: see the cross-compile refusal below.
#
# Release runbook: docs/release.md.
#
# Two hosts, one Makefile: `build`, `test` and `run` work on macOS and Linux; `app`, `notarize` and
# `dist` are macOS-only and fail fast on Linux. Written for GNU Make 3.81 (what macOS ships): plain
# ifeq/else/endif, no `else ifeq`, no .ONESHELL.
SIGN_IDENTITY ?= -
NOTARY_PROFILE ?= tkzmux-notary
SWIFT_FLAGS ?=

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Package.swift picks its target graph with `#if os(Linux)`, evaluated on the machine that runs
# SwiftPM, so a cross-compile would silently build the wrong graph (docs/linux/build.md). Only
# native builds are supported.
CROSS_FLAGS := --triple --swift-sdk --sdk --destination --arch
ifneq ($(filter $(CROSS_FLAGS) $(addsuffix =%,$(CROSS_FLAGS)),$(SWIFT_FLAGS)),)
$(error cross-compiling is not supported: Package.swift branches on the host OS, so build on the target machine and drop $(filter $(CROSS_FLAGS) $(addsuffix =%,$(CROSS_FLAGS)),$(SWIFT_FLAGS)) from SWIFT_FLAGS)
endif

.PHONY: all build test app vendor vendor-linux run clean notarize dist

all: build

vendor:
	scripts/build-ghostty-vt.sh

# Linux x86_64 only: rebuilds vendor/ghostty-vt/ghostty-vt-linux.artifactbundle at the COMMIT the
# macOS `make vendor` pinned (docs/linux/vendoring.md).
vendor-linux:
	scripts/build-ghostty-vt-linux.sh

ifeq ($(UNAME_S),Linux)
ifneq ($(UNAME_M),x86_64)
$(error Linux builds are x86_64 only: vendor/ghostty-vt/ghostty-vt-linux.artifactbundle has no $(UNAME_M) variant)
endif
# Linux: the native build system, passed explicitly (ADR-0002 D2), so a toolchain bump cannot
# switch backends. Tests run serially (docs/linux/build.md).
SWIFT_BUILD_SYSTEM := --build-system native

build:
	swift build $(SWIFT_BUILD_SYSTEM) $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_BUILD_SYSTEM) --no-parallel $(SWIFT_FLAGS)

run:
	swift run $(SWIFT_BUILD_SYSTEM) $(SWIFT_FLAGS) tkzmux

app notarize dist:
	@echo "make $@: macOS only (it assembles, signs or notarizes build/tkzmux.app)." >&2; \
	echo "  On Linux use make build, make test or make run; Linux packaging is WOR-324." >&2; \
	exit 1
else
# macOS: as before, plus SWIFT_FLAGS.
build:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

run:
	swift run $(SWIFT_FLAGS) tkzmux

app:
	SIGN_IDENTITY="$(SIGN_IDENTITY)" VERSION="$(VERSION)" scripts/make-app.sh

# Submit the already-built build/tkzmux.app to Apple's notary service, staple the ticket, and
# prove Gatekeeper accepts the result. Requires `make app` with a real SIGN_IDENTITY first.
#
# Written as one backslash-continued shell command on purpose: macOS ships GNU Make 3.81, which
# has no `.ONESHELL:`, and one make recipe *line* = one shell, so a multi-line recipe would
# happily carry on after a failed notarytool.
notarize:
	@set -e; \
	if [ "$(SIGN_IDENTITY)" = "-" ]; then \
	  echo "make notarize: SIGN_IDENTITY is \"-\" (ad-hoc)."; \
	  echo "  Apple only notarizes Developer ID signatures. Build and notarize in one go with:"; \
	  echo "    SIGN_IDENTITY=\"Developer ID Application: NAME (TEAMID)\" make app notarize"; \
	  echo "  List the identities you have: security find-identity -v -p codesigning"; \
	  exit 1; \
	fi; \
	if [ ! -d build/tkzmux.app ]; then \
	  echo "make notarize: build/tkzmux.app does not exist — run 'make app' first."; exit 1; \
	fi; \
	if codesign -dv build/tkzmux.app 2>&1 | grep -q "Signature=adhoc"; then \
	  echo "make notarize: build/tkzmux.app was signed ad-hoc — the notary service would reject it"; \
	  echo "  after a multi-minute upload. Rebuild it with the identity:"; \
	  echo "    SIGN_IDENTITY=\"$(SIGN_IDENTITY)\" make app notarize"; \
	  exit 1; \
	fi; \
	echo "==> ditto -c -k --keepParent build/tkzmux.app build/tkzmux.zip"; \
	rm -f build/tkzmux.zip; \
	ditto -c -k --keepParent build/tkzmux.app build/tkzmux.zip; \
	echo "==> xcrun notarytool submit --keychain-profile \"$(NOTARY_PROFILE)\" --wait"; \
	rm -f build/notarytool.log; \
	xcrun notarytool submit build/tkzmux.zip \
	  --keychain-profile "$(NOTARY_PROFILE)" --wait 2>&1 | tee build/notarytool.log || true; \
	if ! grep -q "status: Accepted" build/notarytool.log; then \
	  id=`awk '/^ *id: /{print $$2; exit}' build/notarytool.log`; \
	  echo "make notarize: notarization did NOT succeed (transcript in build/notarytool.log)."; \
	  echo "  A missing keychain profile is the usual cause; create it once with:"; \
	  echo "    xcrun notarytool store-credentials $(NOTARY_PROFILE) --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUER-UUID>"; \
	  if [ -n "$$id" ]; then \
	    echo "  Per-file rejection reasons:"; \
	    echo "    xcrun notarytool log $$id --keychain-profile \"$(NOTARY_PROFILE)\""; \
	  fi; \
	  exit 1; \
	fi; \
	echo "==> xcrun stapler staple build/tkzmux.app"; \
	xcrun stapler staple build/tkzmux.app; \
	echo "==> spctl -a -vv -t exec build/tkzmux.app"; \
	spctl -a -vv -t exec build/tkzmux.app; \
	echo "==> notarized and stapled"

# Tag → signed + notarized build → build/dist/*.zip(+.sha256) → GitHub release (+ optional cask
# bump). Refuses to start unless the tree is clean, HEAD carries a v* tag, and a real identity
# is set. See docs/release.md.
dist:
	SIGN_IDENTITY="$(SIGN_IDENTITY)" NOTARY_PROFILE="$(NOTARY_PROFILE)" scripts/make-dist.sh
endif

clean:
	rm -rf .build build
