# bm

Terminal bookmark manager. Links, usernames and passwords live in a KeePass `.kdbx`
file, so the same database opens in KeePassXC, KeePassium, etc. `bm` is a Bash wrapper
around `keepassxc-cli`.

## Install

1. Install KeePassXC: `brew install --cask keepassxc`.
2. Build the Touch ID helper and link `bm` into `~/.local/bin`: `make install`.
3. Make sure `~/.local/bin` is in `PATH`.
4. Create the database: `bm init`.

## Usage

```
bm add https://example.com/login -g work -u bob -p   # -p asks for the password
bm ls                       # list entries
bm find example             # search
bm open example             # open in the browser
bm url example              # print the URL
bm show example             # fields and attachments, password shown as PROTECTED
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

## Touch ID

`bm keychain on` stores the master password in the macOS login Keychain. After that,
`bm` asks for Touch ID (or the login password) instead of the master password.
`bm keychain off` removes it.

One Touch ID stays valid for 1 hour, or until the screen locks. `bm lock` forgets it
at once. Change this with `BM_TOUCHID_TTL` (seconds, `0` = ask every time) and
`BM_TOUCHID_LOCK=0` (keep the approval when the screen locks).

Limit: Touch ID is checked by the `bm-touchid` helper, not by a Keychain access rule.
It protects against a person at your unlocked Mac. It does not protect against
malware that runs as your user, because such a program can read the Keychain item
through `security` directly. If that matters, do not use `bm keychain on`.

## Settings

Set these in the environment or in `~/.config/bm/config` (one `NAME=value` per line).
The config file wins over the environment.

```
# ~/.config/bm/config
BM_TOUCHID_TTL=1800
BM_TOUCHID_LOCK=1
```

| Variable          | Default                           |
|-------------------|-----------------------------------|
| `BM_DB`           | `~/.config/bm/bookmarks.kdbx`     |
| `BM_KEYFILE`      | none                              |
| `BM_CLIP_TIMEOUT` | `20` (seconds)                    |
| `BM_KEY_TTL`      | `600` (seconds in ssh-agent)      |
| `BM_TOUCHID_TTL`  | `3600` (seconds, `0` = no cache)  |
| `BM_TOUCHID_LOCK` | `1` (`0` = survive screen lock)   |
| `BM_CONFIG`       | `~/.config/bm/config`             |

## Test

`make test` runs a smoke test on a temporary database. It uses the system clipboard
for a few seconds.
