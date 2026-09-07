# tkzmux — pure SwiftPM. `make app` assembles build/tkzmux.app without an Xcode project.
SIGN_IDENTITY ?= -

.PHONY: all build test app vendor run clean

all: build

build:
	swift build

test:
	swift test

app:
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/make-app.sh

vendor:
	scripts/build-ghostty-vt.sh

run:
	swift run tkzmux

clean:
	rm -rf .build build
