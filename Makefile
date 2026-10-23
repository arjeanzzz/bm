PREFIX ?= $(HOME)/.local

# The Touch ID helper is macOS only; on Linux make builds nothing and install links bm.
ifeq ($(shell uname -s),Darwin)
all: bm-touchid
else
all:
endif

# Hardened runtime blocks DYLD_INSERT_LIBRARIES and debugger attach to the helper.
bm-touchid: bm-touchid.swift
	swiftc -O $< -o $@
	codesign -s - -f -o runtime $@

# The less safe install: a link to bm in this folder, which any program that runs as
# you can change. For daily use copy bm and the helper as root (see README).
install: all
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/bm $(PREFIX)/bin/bm

# Release files in dist/: bm, bm-touchid for Apple Silicon and Intel, SHA256SUMS.
release: bm bm-touchid.swift
	rm -rf dist
	mkdir dist
	cp bm dist/bm
	swiftc -O -target arm64-apple-macos13.0 bm-touchid.swift -o dist/bm-touchid-arm64
	swiftc -O -target x86_64-apple-macos13.0 bm-touchid.swift -o dist/bm-touchid-x86_64
	lipo -create dist/bm-touchid-arm64 dist/bm-touchid-x86_64 -output dist/bm-touchid
	rm dist/bm-touchid-arm64 dist/bm-touchid-x86_64
	codesign -s - -f -o runtime dist/bm-touchid
	cd dist && shasum -a 256 bm bm-touchid >SHA256SUMS

test:
	./test.sh

.PHONY: all install release test
