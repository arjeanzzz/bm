# bm

Terminal bookmark manager. Links, usernames and passwords live in a KeePass `.kdbx`
file, so the same database opens in KeePassXC, KeePassium, etc. `bm` is a Bash wrapper
around `keepassxc-cli`.

## Install

1. Install KeePassXC into `/Applications`: `brew install --cask keepassxc`. `bm` runs
   `/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli`, never one from `PATH`.
2. Build the Touch ID helper as your user: `make`.
3. Copy `bm` and the helper into `/usr/local/bin`, owned by root: `sudo make install-system`.
   Programs that run as your user cannot change these copies. For another place use
   `sudo make install-system PREFIX=/opt/bm`. Its `bin` folder must be owned by root and
   writable only by root, otherwise `make` refuses it (on Intel Macs Homebrew often owns
   `/usr/local/bin`).
4. Make sure no other `bm` comes earlier in `PATH`: `command -v bm` must print
   `/usr/local/bin/bm`. A folder you can write to (such as `~/.local/bin`) earlier in
   `PATH` could hide the root-owned copy.
5. Create the database: `bm init`.

`make install` instead links `bm` from this folder into `~/.local/bin`. That is handy
while you work on `bm`, but then any program that runs as your user can change the script.

`bm` ignores your `PATH`: it runs its tools from `/usr/bin:/bin:/usr/sbin:/sbin`, then
`/usr/local/bin` and `/opt/homebrew/bin` (for `plink` and `telnet`), and keepassxc-cli
from the system folders only. A fake `keepassxc-cli` or `pbcopy` in a folder you can
write to is not used. It runs as `bash -p`, so `BASH_ENV`, `SHELLOPTS` and exported
functions from the caller do not reach it. `/opt/homebrew/bin` is writable by you, so
a program that runs as you can still replace `plink` and `telnet`.

## Usage

```
bm add https://example.com/login -g work -u bob -p   # -p asks for the password
bm ls                       # list entries
bm find example             # search
bm open example             # open in the browser
bm url example              # print the URL
bm show example             # fields and attachments, password shown as PROTECTED
bm show -s example          # asks, then shows the password and copies it
bm pass example             # copy the password, clipboard clears after 20 s
bm user example             # copy the username
bm edit example --url https://example.org
bm rm example               # moves to the KeePass recycle bin
```

When a query matches several entries, `bm` shows a numbered list and asks you to choose.

## SSH and telnet

```
bm add ssh://root@srv1.lan:2222 -p              # password
bm add ssh://deploy@srv2.lan -k ~/.ssh/id_srv2  # private key as attachment "ssh-key"
bm add ssh://web@srv3.lan -p -k ~/.ssh/id_web   # key, then password as fallback
bm add telnet://sw1.lan:23 -u admin -p

bm ssh srv1                 # extra arguments go to ssh: bm ssh srv2 uptime
bm telnet sw1
```

- The username comes from the entry, or from `user@` in the URL.
- `bm ssh` loads the entry's key into `ssh-agent` for `BM_KEY_TTL` seconds (default
  600). The key is never written to disk.
- If the entry has a password, `bm` gives it to ssh through `SSH_ASKPASS`. ssh tries
  keys first (the agent, `~/.ssh`), then the password. Other prompts, such as host key
  confirmation, still go to you.
- `bm telnet` uses `expect`: it sends the username at the `login:` prompt and the
  password at the `Password:` prompt, then gives you the session.

### plink (old devices)

`bm plink <query>` connects with PuTTY `plink -ssh`. Use it for old switches that
modern OpenSSH refuses because of legacy key exchange, ciphers or host keys.

1. Install PuTTY: `brew install putty`.
2. Connect: `bm plink sw-old` or `bm plink -d 10.0.0.7`.

- plink takes the key from `ssh-agent`, the same as `bm ssh`.
- plink reads the password from a pipe (`-pwfile /dev/fd/N`). The password is not in
  argv and not on disk.
- When the device offers a weak cipher, plink asks you to confirm it. Answer `y`.

### Default entry

`bm ssh -d`, `bm plink -d` and `bm telnet -d` connect to a server
that has no entry. They use the username, key and password of the root entry `default`:

```
bm add ssh://default -t default -u ops -p -k ~/.ssh/id_ops
bm ssh -d 10.0.0.5:2200
bm ssh -d admin@10.0.0.5    # user@ overrides the username of "default"
```

When no entry matches the query, `bm ssh|plink|telnet <query>` works as `-d <query>`.
If there is no `default` entry either, it connects without saved credentials.

## Modes

| Mode | Setup | Master password |
|---|---|---|
| Untrusted Mac (default) | nothing | typed every time |
| Untrusted Mac, with Touch ID | `bm keychain on` | Keychain, Touch ID for every command |
| Trusted Mac | `bm keychain on --ttl 3600` | Keychain, one Touch ID per hour |

## Touch ID

`bm keychain on` stores the master password in the macOS login Keychain. After that,
`bm` asks for Touch ID (or the login password) instead of the master password.
`bm keychain off` removes it.

The Keychain item trusts only the `bm-touchid` helper. Any other program, including
`security find-generic-password -w`, gets a macOS dialog that asks for your login
password. If you did not start such a request, click **Deny**.

By default `bm` asks for Touch ID for every command. `bm keychain on --ttl 3600` keeps
one Touch ID valid for 1 hour, or until the screen locks; add `--no-lock` to keep it
when the screen locks. `bm lock` forgets it at once. To change these, run
`bm keychain on` again. They are stored in the Keychain item with the master password,
not in the environment or the config file, so another program cannot raise them. The
cached approval is signed with the master password, so a program cannot forge it.

Limits:

- While an approval is cached, any program that runs as your user can run `bm`
  (or `bm-touchid get`) without Touch ID. On an untrusted Mac do not use `--ttl`.
- The access rule is bound to the helper's code signature. After you rebuild or
  reinstall `bm-touchid` (`make`, `make install-system`), run `bm keychain on` again.
  Otherwise macOS asks for your login password the next time the new helper reads the item.
- With `make install`, `bm` runs from a folder you can write to, so any program that
  runs as your user can change it. Use `sudo make install-system`.
- Any program can delete the Keychain item. It cannot read it; `bm` then asks for the
  master password again.
- The helper uses the legacy Keychain access API (`SecAccess`, deprecated since
  macOS 10.10). A stronger, hardware-enforced variant is tracked in #3.
- The helper is signed with hardened runtime, so other programs cannot inject code
  into it (`DYLD_INSERT_LIBRARIES`) or attach a debugger.

### After updating from bm 1.0

Run `make install`, then `bm keychain on` again. This replaces the old Keychain item,
which `security` could read, with a new one that only the helper can read.

### Update from bm 1.1

1. Run `make`, then `sudo make install-system` (see Install).
2. Remove the old link: `rm ~/.local/bin/bm`. Check that `command -v bm` prints
   `/usr/local/bin/bm`.
3. Run `bm keychain on` again, because the access rule is bound to the helper's code
   signature. Add `--ttl 3600` for the old one-hour cache. Until then `bm` asks for
   Touch ID for every command: an item from 1.1 has no cache setting.
4. Remove `BM_TOUCHID_TTL` and `BM_TOUCHID_LOCK` from `~/.config/bm/config`. `bm`
   ignores them there (with a warning) and in the environment.
5. The config file is no longer run as Bash code, see Settings.

## Settings

Set these in the environment or in `~/.config/bm/config` (one `NAME=value` per line).
The config file wins over the environment.

The config is data, not code: `bm` does not run it as Bash. Blank lines and `#`
comments are skipped. Values are taken literally (no `$VAR`, no `$(...)`), one pair of
surrounding quotes is removed, and a leading `~/` means your home folder. Other names
and malformed lines are ignored with a warning.

```
# ~/.config/bm/config
BM_DB=~/Documents/bookmarks.kdbx
BM_CLIP_TIMEOUT=30
```

| Variable          | Default                                    |
|-------------------|--------------------------------------------|
| `BM_DB`           | `~/.config/bm/bookmarks.kdbx`              |
| `BM_KEYFILE`      | none                                       |
| `BM_CLIP_TIMEOUT` | `20` (seconds)                             |
| `BM_KEY_TTL`      | `600` (seconds in ssh-agent)               |
| `BM_CONFIG`       | `~/.config/bm/config` (environment only)   |

The Touch ID cache is not a setting: use `bm keychain on --ttl` (see Touch ID).

## Test

`make test` runs a smoke test on a temporary database. It uses the system clipboard
for a few seconds.
