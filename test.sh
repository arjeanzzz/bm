#!/bin/bash
# Smoke test on a throwaway database. Note: briefly uses the system clipboard.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# BM_CONFIG: never read the real config, it could point BM_DB at the real database.
export BM_DB="$tmp/t.kdbx" BM_CLIP_TIMEOUT=2 BM_CONFIG="$tmp/config"
mp=test-master

printf '%s\n%s\n' "$mp" "$mp" | ./bm init >/dev/null
printf '%s\n%s\n%s\n' "$mp" s3cret s3cret | ./bm add https://example.com/login -g work/dev -u bob -p >/dev/null
printf '%s\n' "$mp" | ./bm add https://news.ycombinator.com -t hn >/dev/null

out="$(printf '%s\n' "$mp" | ./bm ls)"
grep -q 'work/dev/example.com' <<<"$out" || { echo "FAIL ls: $out"; exit 1; }
grep -q '^hn$' <<<"$out" || { echo "FAIL ls hn: $out"; exit 1; }

# The config is data: code in it does not run, other names are ignored with a warning,
# an allowed line wins over the environment (quotes stripped, ~/ expanded).
cat >"$BM_CONFIG" <<EOF
# comment

trap 'touch $tmp/pwned' EXIT
BM_CLIP_TIMEOUT=\$(touch $tmp/pwned)
BM_TOUCHID_TTL=3600
PATH=/nonexistent
BM_DB="~/t.kdbx"
EOF
out="$(printf '%s\n' "$mp" | HOME="$tmp" BM_DB=/nonexistent ./bm ls 2>&1)"
[[ ! -e "$tmp/pwned" ]] || { echo "FAIL config ran as code"; exit 1; }
grep -q '^hn$' <<<"$out" || { echo "FAIL config BM_DB: $out"; exit 1; }
[[ "$(grep -c ignored <<<"$out")" == 3 ]] || { echo "FAIL config warnings: $out"; exit 1; }
rm "$BM_CONFIG"

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

# ssh/telnet: fake binaries record what bm passes to them.
fake="$tmp/fake"; mkdir "$fake"
cat >"$fake/ssh" <<'EOF'
#!/bin/bash
echo "args: $*"; [[ -n "${SSH_ASKPASS:-}" ]] && echo "pw: $("$SSH_ASKPASS" "root@h's password: ")"
true
EOF
cat >"$fake/ssh-add" <<'EOF'
#!/bin/bash
grep -q 'BEGIN OPENSSH PRIVATE KEY' && echo "agent got key"
EOF
cat >"$fake/telnet" <<'EOF'
#!/bin/bash
echo "telnet $*"; printf 'login: '; read -r u; printf 'Password: '; read -r p; echo "got $u/$p"
EOF
cat >"$fake/plink" <<'EOF2'
#!/bin/bash
echo "plink $*"; while [[ $# -gt 0 ]]; do [[ "$1" == -pwfile ]] && echo "pw: $(cat "$2")"; shift; done
EOF2
chmod +x "$fake"/*
ssh-keygen -q -t ed25519 -N '' -f "$tmp/k"

printf '%s\n%s\n%s\n' "$mp" pw1 pw1 | ./bm add ssh://root@srv1.lan:2222 -p >/dev/null
printf '%s\n' "$mp" | ./bm add ssh://deploy@srv2.lan -k "$tmp/k" >/dev/null
printf '%s\n%s\n%s\n' "$mp" pw3 pw3 | ./bm add telnet://sw1.lan:23 -u admin -p >/dev/null

out="$(printf '%s\n' "$mp" | ./bm show srv2)"
grep -q 'UserName: deploy' <<<"$out" && grep -q 'ssh-key' <<<"$out" || { echo "FAIL show: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | ./bm show srv1)"
grep -q 'Password: PROTECTED' <<<"$out" && ! grep -q 'pw1' <<<"$out" || { echo "FAIL show hides password: $out"; exit 1; }

out="$(printf '%s\nn\n' "$mp" | ./bm show -s srv1 2>&1)"
grep -q 'WARNING' <<<"$out" && ! grep -q 'pw1' <<<"$out" || { echo "FAIL show -s declined: $out"; exit 1; }
out="$(printf '%s\ny\n' "$mp" | ./bm show -s srv1 2>&1)"
grep -q 'Password: pw1' <<<"$out" || { echo "FAIL show -s: $out"; exit 1; }
sleep 1
[[ "$(pbpaste)" == pw1 ]] || { echo "FAIL show -s clipboard"; exit 1; }

out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh srv1 2>&1)"
grep -q 'args: -p 2222 -l root srv1.lan' <<<"$out" && grep -q 'pw: pw1' <<<"$out" || { echo "FAIL ssh pw: $out"; exit 1; }

out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh srv2 uptime 2>&1)"
grep -q 'agent got key' <<<"$out" && grep -q 'args: -l deploy srv2.lan uptime' <<<"$out" || { echo "FAIL ssh key: $out"; exit 1; }
grep -q 'pw:' <<<"$out" && { echo "FAIL ssh key entry has no password: $out"; exit 1; }

# Key and password in one entry: both go to ssh, ssh tries the key first.
printf '%s\n%s\n%s\n' "$mp" kpw kpw | ./bm add ssh://srv3.lan -u web -p -k "$tmp/k" >/dev/null
out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh srv3 2>&1)"
grep -q 'agent got key' <<<"$out" && grep -q 'pw: kpw' <<<"$out" || { echo "FAIL ssh key+pw: $out"; exit 1; }

out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh 10.9.9.9 2>&1)"
grep -q 'without saved credentials' <<<"$out" && grep -q 'args: 10.9.9.9$' <<<"$out" || { echo "FAIL fallback no default: $out"; exit 1; }
if printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh -d any.lan >/dev/null 2>&1; then echo "FAIL -d without default"; exit 1; fi
printf '%s\n%s\n%s\n' "$mp" dpw dpw | ./bm add ssh://default -t default -u ops -p >/dev/null
out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh -d 10.0.0.5:2200 2>&1)"
grep -q 'args: -p 2200 -l ops 10.0.0.5' <<<"$out" && grep -q 'pw: dpw' <<<"$out" || { echo "FAIL ssh -d: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh -d root@1.2.3.4 2>&1)"
grep -q 'args: -l root 1.2.3.4' <<<"$out" || { echo "FAIL ssh -d user@: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm ssh admin@10.0.0.9 2>&1)"
grep -q "using 'default'" <<<"$out" && grep -q 'args: -l admin 10.0.0.9' <<<"$out" && grep -q 'pw: dpw' <<<"$out" \
  || { echo "FAIL fallback to default: $out"; exit 1; }

out="$({ printf '%s\n' "$mp"; sleep 2; } | PATH="$fake:$PATH" ./bm telnet sw1 2>&1)"
grep -q 'telnet sw1.lan 23' <<<"$out" && grep -q 'got admin/pw3' <<<"$out" || { echo "FAIL telnet: $out"; exit 1; }

out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm plink srv1 2>&1)"
grep -q 'plink -ssh -agent -P 2222 -l root -pwfile /dev/fd/[0-9]* srv1.lan' <<<"$out" && grep -q 'pw: pw1' <<<"$out" || { echo "FAIL plink: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | PATH="$fake:$PATH" ./bm plink -d 10.0.0.7 2>&1)"
grep -q 'plink -ssh -agent -l ops -pwfile /dev/fd/[0-9]* 10.0.0.7' <<<"$out" && grep -q 'pw: dpw' <<<"$out" || { echo "FAIL plink -d: $out"; exit 1; }

# Keychain + Touch ID cache, without a Touch ID dialog: NONINTERACTIVE makes the
# helper fail instead of asking; a valid cache is made by hand with the known password.
if [[ -x ./bm-touchid ]]; then
  export BM_TOUCHID_STATE="$tmp/touchid.state" BM_TOUCHID_NONINTERACTIVE=1
  # || true: under set -e a missing item would end the trap before rm.
  trap './bm-touchid --forget; security delete-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
  printf 'y\n%s\n' "$mp" | ./bm keychain on >/dev/null 2>&1
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: worked without Touch ID"; exit 1; fi
  if printf 'y\n%s\n' "$mp" | ./bm keychain on --ttl abc >/dev/null 2>&1; then echo "FAIL keychain: --ttl abc accepted"; exit 1; fi
  security find-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 || { echo "FAIL keychain: no item"; exit 1; }

  # A live holder (its pid in hp) and a state file signed with the known password.
  hold() { hp="$(./bm-touchid --hold 60 1 </dev/null >/dev/null 2>&1 & echo $!)"; sleep 1; exp=$(( $(date +%s) + 60 )); }
  valid_state() { echo "$hp $exp $(printf '%s' "$hp:$exp" | openssl dgst -sha256 -hmac "$mp" -r | cut -d' ' -f1)" > "$BM_TOUCHID_STATE"; }

  # A forged cache with a live holder must not work.
  hold
  echo "$hp $exp 00" > "$BM_TOUCHID_STATE"
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: forged cache accepted"; exit 1; fi

  # The item says ttl 0 (the default): a valid cache is refused, whatever env and config say.
  valid_state
  echo BM_TOUCHID_TTL=3600 >"$BM_CONFIG"
  if BM_TOUCHID_TTL=3600 BM_TOUCHID_LOCK=0 ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: cache from BM_TOUCHID_TTL"; exit 1; fi
  rm "$BM_CONFIG"

  # --ttl 60 goes into the item, then a valid cache works.
  printf 'y\n%s\n' "$mp" | ./bm keychain on --ttl 60 >/dev/null 2>&1
  hold; valid_state
  ./bm ls </dev/null | grep -q '^default$' || { echo "FAIL keychain: valid cache rejected"; exit 1; }

  ./bm lock >/dev/null
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: works after bm lock"; exit 1; fi
  ./bm keychain off >/dev/null
  security find-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 && { echo "FAIL keychain off"; exit 1; }
  unset BM_TOUCHID_NONINTERACTIVE
fi

[[ "$(./bm --version)" == "bm 1.2" ]] || { echo "FAIL version"; exit 1; }

echo OK
