PREFIX ?= $(HOME)/.local

bm-touchid: bm-touchid.swift
	swiftc -O $< -o $@

install: bm-touchid
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/bm $(PREFIX)/bin/bm

test:
	./test.sh

.PHONY: install test
