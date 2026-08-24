```
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║                 ██╗   ██╗ ███╗   ██╗ ██╗                  ║
║                 ██║   ██║ ████╗  ██║ ██║                  ║
║                 ██║   ██╗ ██╔██╗ ██║ ██║                  ║
║                 ██║   ██╗ ██║╚██╗██║ ██║                  ║
║                 ╚██████╔╝ ██║ ╚████║ ██║                  ║
║                  ╚═════╝  ╚═╝  ╚═══╝ ╚═╝                  ║
║                                                           ║
║ ═════════════════════════════════════════════════════════ ║
║                 University Grades Watcher                 ║
║ ═════════════════════════════════════════════════════════ ║
╚═══════════════════════════════════════════════════════════╝
```

<div align="center">

[![Bash](https://img.shields.io/badge/made%20with-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84?style=flat-square&logo=android&logoColor=white)](#)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

*A tiny Termux script that logs into your university's portal, watches your grades, and pings your phone the second a new mark lands.*

</div>

---

## 📲 Installation

### 1 — Get the apps from F-Droid

Tap the badges below to install both apps from F-Droid. Don't use the Play
Store builds — they're outdated and broken. **Termux** is the terminal;
**Termux:API** is what lets the script talk to Android (notifications, wake
locks).

<div align="center">

| [![Termux](https://fdroid.gitlab.io/artwork/badge/get-it-on.png)](https://f-droid.org/en/packages/com.termux/) | [![Termux:API](https://fdroid.gitlab.io/artwork/badge/get-it-on.png)](https://f-droid.org/en/packages/com.termux.api/) |
|:---:|:---:|
| **Termux** | **Termux:API** |

</div>

### 2 — Install the packages

Open Termux and run:

```bash
pkg install -y git curl jq openssl-tool termux-api
```

<details>
<summary>Packages Purpose</summary>
| Package | What it's for |
|---|---|
| `git` | clones this repo |
| `curl` | talks to the API |
| `jq` | parses the JSON |
| `openssl-tool` | encrypts your saved credentials |
| `termux-api` | notifications + wake lock |
</details>

### 3 — Clone the repo

```bash
git clone https://github.com/GhostasDead/grades-watch.git
cd grades-watch
chmod +x grades-watch.sh
./grades-watch.sh --test-notify   # verifies the notification setup
```

---

## 🚀 Usage

```bash
./grades-watch.sh --host uni-api.example.com
```

[`--host` is the **only required parameter**](#-finding-your---host) — everything else has a sane
default. On first run the script asks for your username and password, saves
them **encrypted** in `~/.grades-watch/`, and never asks again.

**You can close the Termux app and turn the screen off while it's checking** —
the script holds a wake lock, so polling continues in the background and
notifications still pop up. (If your Android build is aggressive about killing
apps, also tap *Acquire wakelock* in the Termux notification.)

While it runs, one line live-refreshes on screen:

```
[20:43:06] check #57: You'll get a notification once new marks get submitted
```

…and when a mark lands, you get:

> **علامة جديدة للسنة 3**
> اتصالات رقمية و تشابهية 25 نظري + 20 عملي = 45

<details>
<summary>Optional flags</summary>

| Flag | Default | What it does |
|---|---|---|
| `--interval SECONDS` | `300` (5 min) | polling interval |
| `--once` | — | single check, then exit |
| `--test-notify` | — | send a sample notification, then exit |
| `-h`, `--help` | — | usage help |

</details>

Reset everything (forget credentials + remembered grades):

```bash
rm -rf ~/.grades-watch
```

---

## 🔎 Finding your `--host`

1. On a PC, go to your uni's website and log in.
2. Press <kbd>F12</kbd>, go to the **Network** tab, then press <kbd>F5</kbd>.
3. Right-click on the columns bar and pick **Domain**.
4. Look for a domain that has `uni-api` in it.
5. Type that domain next to the `--host` parameter in Termux.

---

## ✨ Features

- 🔐 **Login once** — username & password stored AES-256 encrypted; the token
  refreshes itself automatically when it expires
- 🛡️ **Host pinning** — the script refuses to log in to any host that doesn't
  match a SHA-256 hash baked into it, so a typo (or a sketchy mirror) can
  never leak your credentials
- 👤 **Knows who you are** — prints your student profile on startup
- 🗜️ **gzip-aware** requests, timeouts, and a magic-byte decompression fallback
- ⚡ **CRC32 fast path** + per-course diffing — only *actual* mark changes
  trigger a notification, not API noise
- 🔔 Notifications arrive on a dedicated channel, with icon and sound
- 🌙 Survives screen-off via wake lock
- 🎨 Colored, single-line live status + a banner, because terminal apps
  deserve love too

---

## 🤝 Credits

This was a two-brain build: **one human** (the idea, reverse-engineering the
university app's API, and every design call — the notification wording, the
colors, the banner, the host pin) and **one AI** (the bash itself, a mock-server
test rig, 20+ automated tests, and the patience of a saint while decoding the
requirements below).

Requirements were relayed mostly by vibes, which produced the following
historic moments of confusion (all mine 👇):

- I once wrote `25 + 20 = 55` in an example. It's 45. The AI checked it three
  times, flagged it, and implemented the *correct* math anyway.
- *"i swapped `$t` and `$s`"* — the script had neither a `$t` nor an `$s` at
  that point. Translation: show the theoretical mark before the practical one.
- I demanded dependency checks that grep `pkg list-all` because "openssl is
  installed by openssl-tool". The AI built the whole thing. I then decided I
  liked the simple one-liner better and asked to revert it — prefaced with
  *"don't take my words literally."*
- *"make the checking log check on a single line (flush whatever)"* — after
  careful forensic analysis this turned out to mean: one flushed status line
  per check.
- My instructions for finding the host were numbered 1, 2, 4, 4, 5.
- I kept hand-editing the script and reporting fragments of the diff,
  turning version control into archaeology.

Despite all that, it shipped. Use it well.

---

## 📄 License

This project is licensed under the **GNU General Public License v3.0** — see
[LICENSE](LICENSE).

---

## ⚠️ Disclaimer

**Use wisely.** This script exists to check *your own* grades on *your own*
university's portal, and it polls gently — once every 5 minutes by default.
Keep it that way. **I am not responsible if you misuse this tool to put
pressure on any server**, get your account flagged, or otherwise land in
trouble with your institution. You run it, you own it.
