PREFIX ?= $(HOME)/.local

# Hardened runtime blocks DYLD_INSERT_LIBRARIES and debugger attach to the helper.
bm-touchid: bm-touchid.swift
	swiftc -O $< -o $@
	codesign -s - -f -o runtime $@

install: bm-touchid
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/bm $(PREFIX)/bin/bm

# Root-owned copies that programs running as you cannot change: make && sudo make install-system
# Not built here on purpose: sudo would build the helper as root.
# The bin dir must be owned by root and writable only by root, or the copies can be replaced.
install-system: PREFIX = /usr/local
install-system:
	@test bm-touchid -nt bm-touchid.swift || { echo "bm-touchid is not built or out of date: run 'make' as your user first" >&2; exit 1; }
	mkdir -p $(PREFIX)/bin
	@case "$$(stat -f %Su%Sp $(PREFIX)/bin)" in rootd????-??-*) ;; \
	  *) echo "$(PREFIX)/bin is not owned by root or is writable by others, use another PREFIX" >&2; exit 1 ;; esac
	install -m 755 -o root -g wheel bm bm-touchid $(PREFIX)/bin/

test:
	./test.sh

.PHONY: install install-system test
