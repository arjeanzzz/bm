#!/bin/bash
# Smoke test on a throwaway database. Note: briefly uses the system clipboard.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export BM_DB="$tmp/t.kdbx" BM_CLIP_TIMEOUT=2
mp=test-master

printf '%s\n%s\n' "$mp" "$mp" | ./bm init >/dev/null
printf '%s\n%s\n%s\n' "$mp" s3cret s3cret | ./bm add https://example.com/login -g work/dev -u bob -p >/dev/null
printf '%s\n' "$mp" | ./bm add https://news.ycombinator.com -t hn >/dev/null

out="$(printf '%s\n' "$mp" | ./bm ls)"
grep -q 'work/dev/example.com' <<<"$out" || { echo "FAIL ls: $out"; exit 1; }
grep -q '^hn$' <<<"$out" || { echo "FAIL ls hn: $out"; exit 1; }

[[ "$(printf '%s\n' "$mp" | ./bm url hn)" == https://news.ycombinator.com ]] || { echo "FAIL url"; exit 1; }

printf '%s\n' "$mp" | ./bm pass example >/dev/null
sleep 1
[[ "$(pbpaste)" == s3cret ]] || { echo "FAIL pass"; exit 1; }
sleep 3
[[ "$(pbpaste)" != s3cret ]] || { echo "FAIL clipboard not cleared"; exit 1; }

printf '%s\n' "$mp" | ./bm edit hn --url https://lobste.rs >/dev/null
[[ "$(printf '%s\n' "$mp" | ./bm url hn)" == https://lobste.rs ]] || { echo "FAIL edit"; exit 1; }

printf '%s\ny\n' "$mp" | ./bm rm hn >/dev/null
printf '%s\n' "$mp" | ./bm ls | grep -q '^hn$' && { echo "FAIL rm"; exit 1; }

if printf 'wrong\n' | ./bm ls >/dev/null 2>&1; then echo "FAIL wrong password accepted"; exit 1; fi

echo OK
