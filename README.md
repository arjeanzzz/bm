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
bm pass example             # copy the password, clipboard clears after 20 s
bm user example             # copy the username
bm edit example --url https://example.org
bm rm example               # moves to the KeePass recycle bin
```

When a query matches several entries, `bm` shows a numbered list and asks you to choose.

## Touch ID

`bm keychain on` stores the master password in the macOS login Keychain. After that,
`bm` asks for Touch ID (or the login password) instead of the master password.
`bm keychain off` removes it.

Limit: Touch ID is checked by the `bm-touchid` helper, not by a Keychain access rule.
It protects against a person at your unlocked Mac. It does not protect against
malware that runs as your user, because such a program can read the Keychain item
through `security` directly. If that matters, do not use `bm keychain on`.

## Settings

| Variable          | Default                           |
|-------------------|-----------------------------------|
| `BM_DB`           | `~/.config/bm/bookmarks.kdbx`     |
| `BM_KEYFILE`      | none                              |
| `BM_CLIP_TIMEOUT` | `20` (seconds)                    |

## Test

`make test` runs a smoke test on a temporary database. It uses the system clipboard
for a few seconds.
