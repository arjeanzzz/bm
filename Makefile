PREFIX ?= $(HOME)/.local

# Hardened runtime blocks DYLD_INSERT_LIBRARIES and debugger attach to the helper.
bm-touchid: bm-touchid.swift
	swiftc -O $< -o $@
	codesign -s - -f -o runtime $@

install: bm-touchid
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/bm $(PREFIX)/bin/bm

test:
	./test.sh

.PHONY: install test
