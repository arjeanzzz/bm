# bm

Terminal bookmark manager. Links, usernames and passwords live in a KeePass `.kdbx`
file, so the same database opens in KeePassXC, KeePassium, etc. `bm` is a Bash wrapper
around `keepassxc-cli`. It runs on macOS and Linux. On Windows use WSL: inside it,
everything is the same as on Linux.

## Requirements

### macOS

macOS 13 or later. Built in, nothing to install: `/bin/bash` 3.2, `security`,
`realpath`, `open`, `pbcopy`/`pbpaste`, `ssh`/`ssh-add`/`ssh-agent` (in `/usr/bin`),
`expect`, `nl`, `sed`, `grep`, `codesign`, `install`; `openssl` only for `test.sh`. The
Touch ID helper uses the LocalAuthentication, CryptoKit and Security frameworks.
Touch ID is optional: without it macOS asks for your login password.

To install:

- **KeePassXC** (required), the official build. `bm` runs
  `/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli`, never one from `PATH`, and
  only if it is signed by the KeePassXC team (Developer ID, team `G2S7P7J672`).
  - The official DMG from https://keepassxc.org/download/#macos (Apple Silicon or
    Intel). Drag the app to `/Applications`, then check it:
    `spctl -a -vv /Applications/KeePassXC.app` must say `Notarized Developer ID`.
  - Or Homebrew: `brew install --cask keepassxc` (the same signed build).
  - MacPorts builds KeePassXC itself, without that signature, so `bm` refuses it.
  - Optional: `sudo chown -R root:wheel /Applications/KeePassXC.app`. Then a program
    that runs as you cannot change the app at all (`bm` would refuse a changed
    `keepassxc-cli` anyway, but you may also use the app itself). Updates (also
    `brew upgrade`) then no longer work as your user: update by hand and run the
    `chown` again.
- **Command Line Tools** (`xcode-select --install`), only to build the helper from
  source.
- **plink** (PuTTY, `brew install putty`), only for `bm plink`, and **telnet**
  (`brew install telnet`, removed from macOS in 10.13), only for `bm telnet`. Both
  come from Homebrew, in `/opt/homebrew/bin`, which programs that run as you can change.

### Linux

Distro packages (Debian and Ubuntu names; other distros name them alike):

```
sudo apt install keepassxc openssh-client expect xclip xdg-utils  # wl-clipboard on Wayland
sudo apt install putty-tools telnet       # only for bm plink, bm telnet
sudo apt install libsecret-tools          # optional: bm keychain on
```

- `keepassxc` (or `keepassxc-cli`, where the distro splits it) must come from the
  distro: `bm` looks for `keepassxc-cli` only in `/usr/bin`, `/bin`, `/usr/sbin`,
  `/sbin` and `/usr/local/bin`, so the snap and Flatpak versions are not found.
- `bm pass`, `bm user` and `bm show -s` copy with `keepassxc-cli clip`, which needs a
  display and `wl-copy` (Wayland) or `xclip` (X11). Without them `bm` says so.
- Password login with `bm ssh` needs OpenSSH 8.4 or later (`SSH_ASKPASS_REQUIRE`).
  RHEL/CentOS 8 has 8.0: keys work, but ssh asks you for the password itself.
- There is no Touch ID helper on Linux.

## Install

### macOS from source

1. `xcode-select --install`, and install KeePassXC (see Requirements).
2. `git clone https://github.com/arjeanzzz/bm && cd bm`
3. Build the Touch ID helper as your user: `make`.
4. Check the files as your user: `git status` (no changes you did not make) and
   `git log` (the commits you expect).
5. Copy `bm` and the helper into `/usr/local/bin`, owned by root:

   ```
   sudo /bin/mkdir -p /usr/local/bin
   sudo /usr/bin/install -m 755 -o root -g wheel bm bm-touchid /usr/local/bin/
   ```

   Programs that run as your user cannot change these copies. sudo runs only the
   system `install`; `sudo make` would run whatever Makefile (or a planted
   `GNUmakefile`) is in this folder as root. `/usr/local` and `/usr/local/bin` must be
   owned by root (`ls -ld /usr/local /usr/local/bin`). On Intel Macs Homebrew often
   owns `/usr/local/bin`; then use another root-owned folder.
6. Create the database: `bm init`.
7. Optional: `bm keychain on [--ttl SECONDS]` (see Touch ID).

### macOS with the prebuilt helper

1. Install KeePassXC (see Requirements).
2. Download a release: `gh release download v1.2 --repo arjeanzzz/bm`. `gh` does not
   mark the files as downloaded from the internet; after a browser download run
   `xattr -d com.apple.quarantine bm-touchid`.
3. Check the files: `shasum -a 256 -c SHA256SUMS`.
4. `sudo /usr/bin/install -m 755 -o root -g wheel bm bm-touchid /usr/local/bin/`
5. `bm init`

The helper reads your master password. Building it from source lets you check what
runs; a prebuilt helper you take on trust. The Keychain access rule trusts exactly the
helper binary that ran `bm keychain on`.

### Linux

1. Install the packages (see Requirements).
2. `git clone https://github.com/arjeanzzz/bm && cd bm`, then check the files with
   `git status` and `git log`.
3. `sudo /usr/bin/install -m 755 -o root -g root bm /usr/local/bin/`
4. `bm init`

### All systems

- Remove an old link from `make install` or bm 1.1: `rm ~/.local/bin/bm`.
- `command -v bm` must print `/usr/local/bin/bm`. A folder you can write to that comes
  earlier in `PATH` (such as `~/.local/bin`) can hide it, so also add
  `alias bm=/usr/local/bin/bm` to your shell config.
- macOS: run `bm keychain on` again after every install or update of the helper.
- The less safe option: `make install` links `bm` from this folder into `~/.local/bin`
  (on macOS it builds the helper first). That is handy while you work on `bm`, but
  then any program that runs as your user can change the script.

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

bm ssh srv1                 # more arguments are the remote command: bm ssh srv2 uptime
bm telnet sw1
```

- The username comes from the entry, or from `user@` in the URL.
- `bm ssh` loads the entry's key into `ssh-agent` for `BM_KEY_TTL` seconds (default
  600). The key is never written to disk.
- If the entry has a password, `bm` gives it to ssh through `SSH_ASKPASS`. ssh tries
  keys first (the agent, `~/.ssh`), then the password. The password is not in the
  environment (ssh passes that on to `ProxyCommand` and `Match exec`): it waits in a
  file only you can read, which the first password prompt deletes (after 60 s at the
  latest). Other prompts, such as host key confirmation, a key passphrase or a second
  password try, go to you.
- `bm` puts `--` before the host, so more arguments are the remote command, not ssh
  options; put ssh options into `~/.ssh/config`. A host or port that starts with `-`
  is refused.
- `bm telnet` uses `expect`: it sends the username at the `login:` prompt and the
  password at the `Password:` prompt, then gives you the session. The password goes to
  `expect` through a pipe, not the environment.

### plink (old devices)

`bm plink <query>` connects with PuTTY `plink -ssh`. Use it for old switches that
modern OpenSSH refuses because of legacy key exchange, ciphers or host keys.

1. Install PuTTY: `brew install putty` (Linux: `putty-tools`).
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
| Linux (default) | nothing | typed every time |
| Linux, your own machine only | `bm keychain on` | secret service, no prompt |

## Touch ID (macOS)

`bm keychain on` stores the master password in the macOS login Keychain. After that,
`bm` asks for Touch ID (or the login password) instead of the master password.
`bm keychain off` removes it.

The Touch ID dialog says who asks, as macOS sees it: the program that started the
helper, and for a shell script also its arguments, for example
`unlock bookmarks for bm (/bin/bash -p /usr/local/bin/bm pass sw1)`. The program path
comes from the kernel; the arguments are whatever that program was started with. If you
did not just run that command, cancel.

The Keychain item trusts only the `bm-touchid` helper. Any other program, including
`security find-generic-password -w`, gets a macOS dialog that asks for your login
password. If you did not start such a request, click **Deny**.

By default `bm` asks for Touch ID for every command. `bm keychain on --ttl 3600` keeps
one Touch ID valid for 1 hour, or until the screen locks; add `--no-lock` to keep it
when the screen locks. `bm lock` forgets it at once: it ends the helper process that
holds the approval (with `SIGKILL` if needed) and deletes its file. To change these, run
`bm keychain on` again. They are stored in the Keychain item with the master password,
not in the environment or the config file, so another program cannot raise them. The
cached approval is signed with a random key that `bm keychain on` stores in the same
Keychain item, so a program can neither forge it nor use it to guess the master password.

- The access rule is bound to the helper's code signature. After you rebuild or
  reinstall `bm-touchid`, run `bm keychain on` again.
  Otherwise macOS asks for your login password the next time the new helper reads the item.
- Any program can delete the Keychain item. It cannot read it; `bm` then asks for the
  master password again.
- The helper uses the legacy Keychain access API (`SecAccess`, deprecated since
  macOS 10.10). A stronger, hardware-enforced variant is tracked in #3.
- The helper is signed with hardened runtime, so other programs cannot inject code
  into it (`DYLD_INSERT_LIBRARIES`) or attach a debugger.

## Secret service (Linux)

On Linux `bm keychain on` stores the master password with `secret-tool` (GNOME Keyring,
KWallet) under `service bm account <database path>`; `bm` then reads it from there
without asking. `bm keychain off` removes it. There is no Touch ID and no cache, so
`--ttl` and `--no-lock` are refused. This is a convenience only: see Limits.

## Limits

`bm` guards against programs that run as your user, such as a malicious npm or pip
install script or an AI agent, as far as a script can. It runs as `bash -p` (the
caller's `BASH_ENV`, `SHELLOPTS` and exported functions are ignored) with a fixed
`PATH`: system folders first, then `/usr/local/bin` and on macOS `/opt/homebrew/bin`;
`keepassxc-cli` gets the system folders only. A fake `keepassxc-cli`, `pbcopy` or `ssh`
in a folder you can write to is not used. What is left:

- On macOS `plink` and `telnet` come from `/opt/homebrew/bin`, which programs that run
  as you can change.
- `bm` checks the signature of `keepassxc-cli` before each use. `/Applications` is
  writable by admin users, so a program that swaps the app just between that check and
  the start could still win; one that puts back an older signed KeePassXC passes the
  check.
- A program that runs as you can change your shell config (`~/.zshrc`, aliases,
  `PATH`), so the next `bm` you type runs something else. Root-owned copies and the
  alias do not help against that.
- The rest of the environment comes from the caller (`HOME`, `SSH_AUTH_SOCK`,
  `TMPDIR`, on Linux also `LD_PRELOAD`).
- While a Touch ID approval is cached, any program that runs as your user can run `bm`
  (or `bm-touchid get`) without Touch ID. On an untrusted Mac do not use `--ttl`.
- The clipboard can be read by any program until it is cleared (`BM_CLIP_TIMEOUT`).
  On macOS Universal Clipboard can send it to your other Apple devices.
- On Linux the secret service has no per-app protection: while your keyring is
  unlocked, any program that runs as you can read the master password over D-Bus
  without a prompt. Do not use `bm keychain on` on a shared or untrusted machine.
- With `make install`, `bm` runs from a folder you can write to, so any program that
  runs as your user can change it. Install root-owned copies (see Install).
- root bypasses all of this.

### After updating from bm 1.0

Run `make install`, then `bm keychain on` again. This replaces the old Keychain item,
which `security` could read, with a new one that only the helper can read.

### Update from bm 1.1

1. Run `make`, check the files and copy them as root (see Install).
2. Remove the old link: `rm ~/.local/bin/bm`. Check that `command -v bm` prints
   `/usr/local/bin/bm`.
3. Run `bm keychain on` again, because the access rule is bound to the helper's code
   signature. Add `--ttl 3600` for the old one-hour cache. Until then `bm` asks for
   Touch ID for every command: an item from 1.1 has no cache setting and no cache key.
4. Remove `BM_TOUCHID_TTL` and `BM_TOUCHID_LOCK` from `~/.config/bm/config`. `bm`
   ignores them there (with a warning) and in the environment.
5. The config file is no longer run as Bash code, see Settings.
6. `bm` ignores your `PATH`: KeePassXC must be the signed build in `/Applications`, see
   Requirements. ssh options after the query are no longer passed to ssh, see SSH.

## Settings

Set these in the environment or in `~/.config/bm/config` (one `NAME=value` per line).
The config file wins over the environment.

The config is data, not code: `bm` does not run it as Bash. Blank lines and `#`
comments are skipped. Values are taken literally (no `$VAR`, no `$(...)`), one pair of
surrounding quotes is removed, and a leading `~/` means your home folder. Other names
and malformed lines are ignored with a warning. Windows line ends are fine.

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

`make test` (or `./test.sh`) runs a smoke test on a temporary database, on macOS and
Linux. It uses the system clipboard for a few seconds. It runs `ssh`, `plink` and
`telnet` as fakes, through a copy of `bm` whose `PATH` starts with the fakes.

- macOS: it cannot show a Touch ID dialog, so it checks only that the helper refuses:
  no Touch ID, forged or old cache files, and that `bm lock` ends the holder. A working
  cache needs a real Touch ID and is not tested: after changes to the helper, check by
  hand that `bm keychain on --ttl 60`, then two `bm ls`, ask for Touch ID only once,
  and that the dialog names the command.
- Linux: the clipboard checks need a display with `wl-copy`/`wl-paste` or `xclip`, the
  secret service checks a D-Bus session bus with a secret service. Without them those
  parts are skipped with a message.
