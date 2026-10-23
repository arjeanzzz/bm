#!/bin/bash
# Smoke test on a throwaway database, macOS and Linux. Note: briefly uses the system
# clipboard.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# No BM_* setting from the caller (BM_KEYFILE, BM_ASKPASS, BM_TOUCHID_STATE, ...).
for v in $(compgen -v BM_ || true); do unset "$v"; done
# BM_CONFIG: never read the real config, it could point BM_DB at the real database.
export BM_DB="$tmp/t.kdbx" BM_CLIP_TIMEOUT=2 BM_CONFIG="$tmp/config"
mp=test-master
os="$(uname -s)"

# Clipboard: pbpaste on macOS; on Linux the tool keepassxc-cli uses (wl-copy on Wayland,
# else xclip), which needs a display.
noclip=0
if [[ "$os" == Darwin ]]; then clipboard() { pbpaste; }
elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  clipboard() { wl-paste -n 2>/dev/null || true; }
  command -v wl-copy >/dev/null && command -v wl-paste >/dev/null || noclip=1
elif [[ -n "${DISPLAY:-}" ]]; then
  clipboard() { xclip -o -selection clipboard 2>/dev/null || true; }
  command -v xclip >/dev/null || noclip=1
else noclip=1; fi
(( noclip )) && echo "skip: clipboard checks (no display, or no wl-copy/wl-paste or xclip)"

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
# Windows line ends (CR LF) work too.
awk '{ printf "%s\r\n", $0 }' "$BM_CONFIG" >"$tmp/crlf"; mv "$tmp/crlf" "$BM_CONFIG"
out="$(printf '%s\n' "$mp" | HOME="$tmp" BM_DB=/nonexistent ./bm ls 2>&1)"
[[ ! -e "$tmp/pwned" ]] || { echo "FAIL config ran as code"; exit 1; }
grep -q '^hn$' <<<"$out" || { echo "FAIL config BM_DB: $out"; exit 1; }
[[ "$(grep -c ignored <<<"$out")" == 3 ]] || { echo "FAIL config warnings: $out"; exit 1; }
rm "$BM_CONFIG"

[[ "$(printf '%s\n' "$mp" | ./bm url hn)" == https://news.ycombinator.com ]] || { echo "FAIL url"; exit 1; }

if (( noclip )); then
  # Without a clipboard bm says so, instead of reporting a copy.
  if printf '%s\n' "$mp" | ./bm pass example >/dev/null 2>&1; then echo "FAIL pass without a clipboard"; exit 1; fi
else
  printf '%s\n' "$mp" | ./bm pass example >/dev/null
  sleep 1
  [[ "$(clipboard)" == s3cret ]] || { echo "FAIL pass"; exit 1; }
  sleep 3
  [[ "$(clipboard)" != s3cret ]] || { echo "FAIL clipboard not cleared"; exit 1; }
fi

# The caller's PATH and shell settings do not reach bm: fake tools early in PATH,
# BASH_ENV and an exported function must not run, SHELLOPTS=xtrace must not leak.
evil="$tmp/evil"; mkdir "$evil"
for t in keepassxc-cli pbcopy xclip wl-copy uname; do
  printf '#!/bin/sh\ntouch "%s/hijacked"\n' "$tmp" >"$evil/$t"; chmod +x "$evil/$t"
done
printf 'touch "%s/hijacked"\n' "$tmp" >"$evil/env.sh"
# macOS: a keepassxc-cli without the KeePassXC team signature is refused (a copy of bm
# that points at the fake one).
if [[ "$os" == Darwin ]]; then
  sed "s|then KXC=/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli\$|then KXC=$evil/keepassxc-cli|" bm >"$tmp/bm-kxc"
  chmod +x "$tmp/bm-kxc"
  grep -q "KXC=$evil/keepassxc-cli" "$tmp/bm-kxc" || { echo "FAIL test copy: no KXC line in bm"; exit 1; }
  out="$(printf '%s\n' "$mp" | "$tmp/bm-kxc" ls 2>&1)" && { echo "FAIL unsigned keepassxc-cli used: $out"; exit 1; }
  grep -q 'not signed' <<<"$out" || { echo "FAIL unsigned keepassxc-cli: $out"; exit 1; }
fi
printf '%s\n' "$mp" | PATH="$evil:$PATH" ./bm pass example >/dev/null 2>&1 || (( noclip )) \
  || { echo "FAIL pass with fake tools in PATH"; exit 1; }
printf '%s\n' "$mp" | PATH="$evil:$PATH" BASH_ENV="$evil/env.sh" ./bm ls >/dev/null
( export tmp; read() { touch "$tmp/hijacked"; builtin read "$@"; }; export -f read; printf '%s\n' "$mp" | ./bm ls >/dev/null )
out="$(printf '%s\n' "$mp" | env SHELLOPTS=xtrace ./bm ls 2>&1)"
sleep 3
[[ ! -e "$tmp/hijacked" ]] || { echo "FAIL caller PATH, BASH_ENV or exported function used"; exit 1; }
grep -q "$mp" <<<"$out" && { echo "FAIL SHELLOPTS=xtrace shows the master password"; exit 1; }

printf '%s\n' "$mp" | ./bm edit hn --url https://lobste.rs >/dev/null
[[ "$(printf '%s\n' "$mp" | ./bm url hn)" == https://lobste.rs ]] || { echo "FAIL edit"; exit 1; }

printf '%s\ny\n' "$mp" | ./bm rm hn >/dev/null
printf '%s\n' "$mp" | ./bm ls | grep -q '^hn$' && { echo "FAIL rm"; exit 1; }

if printf 'wrong\n' | ./bm ls >/dev/null 2>&1; then echo "FAIL wrong password accepted"; exit 1; fi

# ssh/telnet: fake binaries record what bm passes to them.
fake="$tmp/fake"; mkdir "$fake"
cat >"$fake/ssh" <<'EOF'
#!/bin/bash
echo "args: $*"; env >"$(dirname "$0")/ssh.env"
if [[ -n "${SSH_ASKPASS:-}" ]]; then
  echo "pw: $("$SSH_ASKPASS" "root@h's password: ")"
  [[ -e "$BM_ASKPASS" ]] && echo "pw file left"
fi
true
EOF
cat >"$fake/ssh-add" <<'EOF'
#!/bin/bash
grep -q 'BEGIN OPENSSH PRIVATE KEY' && echo "agent got key"
EOF
cat >"$fake/telnet" <<'EOF'
#!/bin/bash
echo "telnet $*"; env >"$(dirname "$0")/telnet.env"; printf 'login: '; read -r u; printf 'Password: '; read -r p; echo "got $u/$p"
EOF
cat >"$fake/plink" <<'EOF2'
#!/bin/bash
echo "plink $*"; while [[ $# -gt 0 ]]; do [[ "$1" == -pwfile ]] && echo "pw: $(cat "$2")"; shift; done
EOF2
chmod +x "$fake"/*
# bm has a fixed PATH: the fake tools only work in a copy of bm whose PATH starts with
# $fake. The copy finds the helper next to it.
sed "s|^export PATH\$|PATH=$fake:\$PATH; export PATH|" bm >"$tmp/bm"; chmod +x "$tmp/bm"
grep -q "^PATH=$fake:" "$tmp/bm" || { echo "FAIL test copy: no PATH line in bm"; exit 1; }
ln -s "$PWD/bm-touchid" "$tmp/bm-touchid"
tbm="$tmp/bm"
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
if (( ! noclip )); then sleep 1; [[ "$(clipboard)" == pw1 ]] || { echo "FAIL show -s clipboard"; exit 1; }; fi

out="$(printf '%s\n' "$mp" | "$tbm" ssh srv1 2>&1)"
grep -q 'args: -p 2222 -l root -- srv1.lan' <<<"$out" && grep -q 'pw: pw1' <<<"$out" || { echo "FAIL ssh pw: $out"; exit 1; }
# Not in the environment that ssh passes on, and the file is gone after the first prompt.
grep -q pw1 "$fake/ssh.env" && { echo "FAIL ssh: password in the environment"; exit 1; }
grep -q 'pw file left' <<<"$out" && { echo "FAIL ssh: password file left"; exit 1; }

out="$(printf '%s\n' "$mp" | "$tbm" ssh srv2 uptime 2>&1)"
grep -q 'agent got key' <<<"$out" && grep -q 'args: -l deploy -- srv2.lan uptime' <<<"$out" || { echo "FAIL ssh key: $out"; exit 1; }
grep -q 'pw:' <<<"$out" && { echo "FAIL ssh key entry has no password: $out"; exit 1; }

# Key and password in one entry: both go to ssh, ssh tries the key first.
printf '%s\n%s\n%s\n' "$mp" kpw kpw | ./bm add ssh://srv3.lan -u web -p -k "$tmp/k" >/dev/null
out="$(printf '%s\n' "$mp" | "$tbm" ssh srv3 2>&1)"
grep -q 'agent got key' <<<"$out" && grep -q 'pw: kpw' <<<"$out" || { echo "FAIL ssh key+pw: $out"; exit 1; }

out="$(printf '%s\n' "$mp" | "$tbm" ssh 10.9.9.9 2>&1)"
grep -q 'without saved credentials' <<<"$out" && grep -q 'args: -- 10.9.9.9$' <<<"$out" || { echo "FAIL fallback no default: $out"; exit 1; }
if printf '%s\n' "$mp" | "$tbm" ssh -d any.lan >/dev/null 2>&1; then echo "FAIL -d without default"; exit 1; fi
printf '%s\n%s\n%s\n' "$mp" dpw dpw | ./bm add ssh://default -t default -u ops -p >/dev/null
out="$(printf '%s\n' "$mp" | "$tbm" ssh -d 10.0.0.5:2200 2>&1)"
grep -q 'args: -p 2200 -l ops -- 10.0.0.5' <<<"$out" && grep -q 'pw: dpw' <<<"$out" || { echo "FAIL ssh -d: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | "$tbm" ssh -d root@1.2.3.4 2>&1)"
grep -q 'args: -l root -- 1.2.3.4' <<<"$out" || { echo "FAIL ssh -d user@: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | "$tbm" ssh admin@10.0.0.9 2>&1)"
grep -q "using 'default'" <<<"$out" && grep -q 'args: -l admin -- 10.0.0.9' <<<"$out" && grep -q 'pw: dpw' <<<"$out" \
  || { echo "FAIL fallback to default: $out"; exit 1; }

out="$({ printf '%s\n' "$mp"; sleep 2; } | "$tbm" telnet sw1 2>&1)"
grep -q 'telnet sw1.lan 23' <<<"$out" && grep -q 'got admin/pw3' <<<"$out" || { echo "FAIL telnet: $out"; exit 1; }
grep -q pw3 "$fake/telnet.env" && { echo "FAIL telnet: password in the environment"; exit 1; }

# A host or port that starts with - is refused, it would be an option.
for c in ssh plink telnet; do
  out="$(printf '%s\n' "$mp" | "$tbm" "$c" -d "-oProxyCommand=touch $tmp/pwned" 2>&1)" && { echo "FAIL $c: option as host: $out"; exit 1; }
  grep -q 'bad host' <<<"$out" || { echo "FAIL $c: option as host: $out"; exit 1; }
done
out="$(printf '%s\n' "$mp" | "$tbm" telnet -d sw1.lan:-n 2>&1)" && { echo "FAIL telnet: option as port: $out"; exit 1; }
grep -q 'bad port' <<<"$out" || { echo "FAIL telnet: option as port: $out"; exit 1; }

out="$(printf '%s\n' "$mp" | "$tbm" plink srv1 2>&1)"
grep -q 'plink -ssh -agent -P 2222 -l root -pwfile /dev/fd/[0-9]* srv1.lan' <<<"$out" && grep -q 'pw: pw1' <<<"$out" || { echo "FAIL plink: $out"; exit 1; }
out="$(printf '%s\n' "$mp" | "$tbm" plink -d 10.0.0.7 2>&1)"
grep -q 'plink -ssh -agent -l ops -pwfile /dev/fd/[0-9]* 10.0.0.7' <<<"$out" && grep -q 'pw: dpw' <<<"$out" || { echo "FAIL plink -d: $out"; exit 1; }

# Keychain + Touch ID cache, without a Touch ID dialog: NONINTERACTIVE makes the
# helper fail instead of asking. A valid cache needs one real Touch ID (its HMAC key is
# random and only the helper can read it), so only refusals are tested here.
if [[ "$os" == Darwin && -x ./bm-touchid ]]; then
  export BM_TOUCHID_STATE="$tmp/touchid.state" BM_TOUCHID_NONINTERACTIVE=1
  # || true: under set -e a missing item would end the trap before rm.
  trap './bm-touchid --forget; security delete-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
  printf 'y\n%s\n' "$mp" | ./bm keychain on >/dev/null 2>&1
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: worked without Touch ID"; exit 1; fi
  if printf 'y\n%s\n' "$mp" | ./bm keychain on --ttl abc >/dev/null 2>&1; then echo "FAIL keychain: --ttl abc accepted"; exit 1; fi
  security find-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 || { echo "FAIL keychain: no item"; exit 1; }

  # A live holder (its pid in hp).
  hold() { hp="$(./bm-touchid --hold 60 1 </dev/null >/dev/null 2>&1 & echo $!)"; sleep 1; exp=$(( $(date +%s) + 60 )); }

  # The item allows a cache (--ttl 60) and the holder lives, so only the tag decides:
  # a forged one, and one keyed with the master password (bm 1.2 before the random key).
  printf 'y\n%s\n' "$mp" | ./bm keychain on --ttl 60 >/dev/null 2>&1
  hold
  echo "$hp $exp $(printf '%064d' 0)" > "$BM_TOUCHID_STATE"
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: forged cache accepted"; exit 1; fi
  echo "$hp $exp $(printf '%s' "$hp:$exp" | openssl dgst -sha256 -hmac "$mp" -r | cut -d' ' -f1)" > "$BM_TOUCHID_STATE"
  if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain: cache keyed with the master password accepted"; exit 1; fi

  # SIGTERM: the holder removes its state file. A stopped holder ignores SIGTERM, so
  # bm lock then sends SIGKILL, and it removes the state file in any case.
  kill "$hp"; sleep 1
  [[ ! -e "$BM_TOUCHID_STATE" ]] || { echo "FAIL keychain: holder left its state file on SIGTERM"; exit 1; }
  hold; kill -STOP "$hp"
  echo "$hp $exp 00" > "$BM_TOUCHID_STATE"
  ./bm lock >/dev/null; sleep 1
  kill -0 "$hp" 2>/dev/null && { echo "FAIL keychain: stopped holder survived bm lock"; exit 1; }
  [[ ! -e "$BM_TOUCHID_STATE" ]] || { echo "FAIL keychain: state file left after bm lock"; exit 1; }
  ./bm keychain off >/dev/null
  security find-generic-password -s bm -a "$BM_DB" >/dev/null 2>&1 && { echo "FAIL keychain off"; exit 1; }
  unset BM_TOUCHID_NONINTERACTIVE
fi

# Linux: no Touch ID options; the master password in the secret service (secret-tool)
# needs a session bus with a secret service, else that part is skipped.
if [[ "$os" != Darwin ]]; then
  if printf 'y\n%s\n' "$mp" | ./bm keychain on --ttl 60 >/dev/null 2>&1; then echo "FAIL keychain: --ttl accepted on Linux"; exit 1; fi
  [[ "$(./bm lock)" == *"no Touch ID"* ]] || { echo "FAIL lock on Linux"; exit 1; }
  if command -v secret-tool >/dev/null && { [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]]; } \
     && printf x | secret-tool store --label="bm test" service bm-test account "$tmp" 2>/dev/null; then
    secret-tool clear service bm-test account "$tmp"
    trap 'secret-tool clear service bm account "$BM_DB" 2>/dev/null || true; rm -rf "$tmp"' EXIT
    out="$(printf 'y\n%s\n' "$mp" | ./bm keychain on 2>&1)"
    grep -q 'D-Bus' <<<"$out" || { echo "FAIL keychain: no Linux warning: $out"; exit 1; }
    ./bm ls </dev/null | grep -q '^default$' || { echo "FAIL keychain: not read with secret-tool"; exit 1; }
    ./bm keychain off >/dev/null
    if ./bm ls </dev/null >/dev/null 2>&1; then echo "FAIL keychain off"; exit 1; fi
  else
    echo "skip: secret-tool (no session bus or secret service)"
  fi
fi

[[ "$(./bm --version)" == "bm 1.2" ]] || { echo "FAIL version"; exit 1; }

echo OK
