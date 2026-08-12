<div align="center">

<img src="Resources/icon-1024.png" width="128" alt="LidAwake" />

# LidAwake

**Close the lid. Keep working.**

English · [简体中文](README.md)

A native macOS menu bar utility for anyone running long tasks — AI agents, builds,
training runs, downloads, syncs. **Works on battery alone**, no external display or
keyboard required.

[![Release](https://img.shields.io/github/v/release/NeoSpecies/LidAwake?color=blue)](https://github.com/NeoSpecies/LidAwake/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](Package.swift)

</div>

---

## The problem

Close a MacBook's lid and it sleeps: **SSH drops, API connections die, whatever was
running stops halfway through.**

In the age of AI agents this stings. Your agent is 3 minutes into a 20-minute task,
you close the lid to walk into a meeting, and you come back to find it frozen at
minute 3.

LidAwake keeps the machine awake and online with the lid closed, so the work finishes.

## Why not `caffeinate`, and why not Amphetamine

Almost every recipe you'll find online fails at this specific scenario:

| Approach | Survives lid close? | Why |
|---|---|---|
| `caffeinate -disu -t 3600` | ❌ **No** | `-d/-i/-u` create **idle** assertions. Closing the lid is a **forced sleep**, which bypasses every idle assertion. This is the most widely repeated bad advice. |
| `caffeinate -s` | ⚠️ Only on AC power | `PreventSystemSleep` is only honored while plugged in |
| Amphetamine | ⚠️ Needs **one of**: AC power, external display, or external keyboard/mouse | It's a sandboxed Mac App Store app, so it can't get root and is limited to the assertion layer — that limit is documented by its own author |
| **LidAwake** | ✅ **Yes, including battery-only** | Assertion layer **plus** the system-level `SleepDisabled` setting (one-time authorization for a privileged helper) |

Covering "battery only, no peripherals, lid closed" requires setting the system-wide
`SleepDisabled` flag, and that requires root. That's why LidAwake installs a small
background service — and it's exactly the capability the alternatives can't offer.

## Measured evidence

Not "feels fine" — measured with `mach_continuous_time() - mach_absolute_time()`.
**That delta only grows while the system is asleep**, so "how long did it sleep" is a
hard number, not an inference.

| | Control (LidAwake off) | Treatment (LidAwake on) |
|---|---|---|
| Environment | Battery only, no peripherals | Battery only, no peripherals |
| Lid closed for | 69 s | **138 s** |
| **Total sleep** | **61.52 s** ❌ | **0.00 s** ✅ |
| Max sampling gap | 62.03 s (process frozen) | **0.51 s** (= the sampling interval; never froze) |
| Wi-Fi IPv4 | — | present in **all 325 samples** ✅ |

Hardware: MacBook Pro (M5 Max) / macOS 26.5. Full data in [docs/RESULTS.md](docs/RESULTS.md)
(Chinese).

The verification is shipped as a tool, so you can reproduce it on your own machine:

```bash
lidawake on
lidawake-probe start        # now close the lid for 60 seconds, then open it
lidawake-probe report --expect awake
```

## Features

- **Genuinely works on battery** — two layers: `IOPMAssertion` + system-level `SleepDisabled`
- **Authorize once** — after install, toggling never asks for a password again
- **Safety brakes** — releases automatically on low battery, critical thermals, or session timeout
- **No idle footprint** — with no session and no connected client the daemon exits itself
  (zero processes); launchd brings it back on demand in milliseconds
- **Zero polling** — power/battery/thermal via system notifications, UI via reverse XPC push.
  Measured: **0.04 s** of CPU time over 20 s of an active session
- **Scriptable** — full CLI with parseable `--json` output, built for agents and CI
- **Fail-safe** — a crash is picked up by launchd and state restored from disk; uninstall,
  shutdown and `launchctl bootout` all release `SleepDisabled` immediately
- **Shows you who else is draining power** — `lidawake doctor` lists every third-party
  process currently blocking sleep
- **Zero dependencies** — pure Swift + AppKit + IOKit

## Install

### Homebrew (fastest)

```bash
brew tap NeoSpecies/tap
brew trust NeoSpecies/tap        # newer Homebrew requires trusting third-party taps
brew install --cask lidawake
```

### Installer package

Download the `.pkg` from [Releases](https://github.com/NeoSpecies/LidAwake/releases/latest):

```bash
sudo installer -pkg LidAwake-1.1.0.pkg -target /
```

> The package is currently **unsigned and un-notarized** (no Apple Developer ID yet).
> The command above bypasses Gatekeeper friction; to install via double-click you'll need
> **right-click → Open**. See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

### From source

Only Xcode Command Line Tools are needed — **no full Xcode**:

```bash
git clone https://github.com/NeoSpecies/LidAwake.git
cd LidAwake
./scripts/install.sh     # build + test + install app + one-time service authorization
```

## Usage

### Menu bar

Click the icon: Enable (indefinite) / Enable with timer (15 min – 8 h / custom) / Disable,
plus Safety Policies, Diagnostics, Self-test, and Launch at Login.

### Command line

```bash
lidawake on                       # enable (indefinite, still bounded by the max-session guard)
lidawake on --for 2h              # timed (accepts 30s / 15m / 2h / 1h30m / 1d)
lidawake on --for 2h --origin ci  # tag the caller, so you can tell who turned it on
lidawake off
lidawake status                   # human readable
lidawake status --json            # machine readable
lidawake doctor                   # diagnostics: is the mechanism complete, who blocks sleep
lidawake guards --battery-floor 30 --max 4h --require-ac on
```

For agents and build scripts:

```bash
lidawake on --for 2h --origin build.sh && make -j && lidawake off
```

Exit codes: `0` ok · `1` usage error · `2` service unavailable · `3` blocked by a safety
guard (use this to detect "not enough battery").

## Bonus: Menu Bar Fold

Too many menu bar icons, so macOS truncates them and you can't find or click them?
Hit `⌥⌘B` for a grid panel:

- **🟠 orange dot** = truncated by the system, not visible on screen at all — sorted first
- **Click a tile** = LidAwake presses the real menu bar item for you, and that app's own
  menu opens, untouched
- Live CPU / memory / disk / network at the bottom (**no permissions needed**)
- Optionally fold a chosen group of icons away (⌘-drag the boundary marker to pick the group)

**Off by default.** Enable from LidAwake → "菜单栏折叠". Listing and clicking icons needs
**Accessibility** (the same permission Raycast / Rectangle ask for); folding and the system
stats need **no permission at all**.

Details, permission boundaries, and why another app's icon *image* is simply not obtainable:
[docs/MENUBAR.md](docs/MENUBAR.md) (Chinese).

## ⚠️ Important caveats — please read

### 1. The battery still drains with the lid closed

**This matters most.** LidAwake only prevents sleep; the machine keeps running at full
speed — CPU working, Wi-Fi associated, memory refreshing. **A closed lid is not low power.**

- The display is off (that part genuinely saves power), but total system draw is still significant
- Under heavy load (compiles, model inference) the battery drops fast — hours, not days
- That's why the default is **auto-off at ≤ 20% battery (on battery power)** — leave it on
- For long tasks, **plug in**

### 2. Thermals get worse with the lid closed

The keyboard deck is one of the main heat paths, and closing the lid restricts it.
Heavy load + closed lid + a soft surface (bed, couch, inside a bag) is the risky combination.
**Auto-off on critical thermal pressure is enabled by default** — leave it on. Note that
critical pressure means it's *already* hot: this is a last-resort brake, not prevention.

### 3. It needs one admin authorization and installs a root daemon

`SleepDisabled` can only be set by root; there's no way around it. Everything installed
is listed below, and the uninstaller removes all of it:

```
/Applications/LidAwake.app
/Library/PrivilegedHelperTools/lidawaked            (root:wheel 0755)
/Library/LaunchDaemons/com.cogito.lidawaked.plist   (root:wheel 0644)
/Library/Application Support/LidAwake/state.json    (root:wheel 0600)
/usr/local/bin/lidawake, /usr/local/bin/lidawake-probe
/var/log/lidawaked.log
```

The daemon does exactly one thing: toggle system sleep. Its XPC protocol can express
**only** `off` / `indefinite` / `until(seconds)` — there is no field capable of carrying a
path, a command, or shell arguments. Even if authorization were bypassed, the worst an
attacker gets is "this Mac won't go to sleep."

### 4. Don't forget to turn it off

`SleepDisabled` is a persistent system setting: it survives the process that set it.
Three safeguards: the menu bar icon is **filled/highlighted** while active, sessions are
capped at **12 hours** by default, and the **20% battery floor** is on by default.
`lidawake doctor` always shows the real system value.

### 5. Known limitations

- Currently ad-hoc signed, so XPC can only verify "caller is root or in the admin group",
  not the caller's code signature. This tightens up with a Developer ID —
  ready-to-use code is in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)
- If the daemon is `kill -9`'d *and* launchd cannot restart it (e.g. the plist was deleted
  by hand), `SleepDisabled` stays at 1. Mitigations: unconditional reset at boot, explicit
  reset on uninstall, and `doctor` surfacing the real value
- **It cannot ship on the Mac App Store** (sandbox rules) — reasons and three viable
  distribution routes in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)

## How it works

```
LidAwake.app (menu bar, LSUIElement)  ─┐
lidawake (CLI, for scripts/agents)    ─┼─ NSXPCConnection ──▶ lidawaked (root, launchd)
                                                                ├─ IOPMAssertion layer (L1)
                                                                ├─ SleepDisabled layer (L2)
                                                                ├─ battery/thermal guards
                                                                └─ pure-function decision engine
```

- **L1, assertions**: `PreventUserIdleSystemSleep` + `PreventSystemSleep`. No root needed,
  visible in `pmset -g assertions`. Used as a clearly-labelled degraded fallback when the
  daemon isn't installed
- **L2, system setting**: `IOPMSetSystemPowerSetting("SleepDisabled", true)` — the same thing
  `pmset -a disablesleep 1` does. Requires root, and **this is why battery-only works**.
  Resolved via `dlsym` with automatic fallback to the `pmset` binary if the symbol is gone
- **The decision engine is a pure function** — no clock reads, no IOKit, no file I/O; all
  environment facts are injected. That's how 85 unit tests can lock down semantics that are
  impossible to reproduce in CI
- **Every "on" state is verified by reading the system back**, never assumed optimistically

## Testing

| Layer | Scope | Result |
|---|---|---|
| L1 unit | engine priority, boundary equality, codecs, invalid input, auth policy | ✅ 85/85 |
| L2 integration | real apply/read-back, idempotency, timer expiry, `kill -9` recovery, `bootout` fail-safe, guard trips, idle exit, energy | ✅ 31/31 |
| L3 lid-close E2E | control (should sleep) + treatment (should not), judged by mach clock delta | ✅ both PASS |

```bash
./scripts/run-tests.sh                 # L1
sudo ./scripts/integration-test.sh     # L2
lidawake-probe start && lidawake-probe report --expect awake   # L3
```

CLT ships neither `XCTest` nor `swift-testing`, so L1 uses a small purpose-built harness —
the core logic is pure functions, which is enough.

## Uninstall

```bash
./scripts/uninstall.sh
```

Quits the app, removes the login item, unloads the service, **resets `SleepDisabled`**,
and deletes every installed file.

## Roadmap

Next three things (full list in [ROADMAP.md](ROADMAP.md), Chinese):

1. **`lidawake while -- <command>`** — bind the session to a process lifetime, so it turns
   itself off when the command exits. No more guessing how long the job will take
2. **Battery runway estimate** — show "≈ 2h10m left at current draw" in the menu bar and
   record session history, turning "how much battery does a closed-lid hour cost" into real
   numbers from your own machine
3. **Full i18n, Homebrew cask, CI** — make it easier for other people to actually use

## ⭐ If it helped

LidAwake solves one specific, genuinely annoying problem: **close the lid, lose the work.**

If it ever saved you a run, a star is the most useful thanks — it helps the next person
searching for "macbook keep running lid closed" find the answer faster.

Missing something? [Open an issue](https://github.com/NeoSpecies/LidAwake/issues) — the
roadmap ordering is largely driven by that.

## Contributing

```bash
./scripts/run-tests.sh                 # required (85 unit assertions)
sudo ./scripts/integration-test.sh     # required when touching the daemon / XPC / engine
```

- **PRs that touch the mechanism layer must include a lid-close E2E report**:
  `lidawake-probe start` → close the lid 60 s → `lidawake-probe report --expect awake`.
  It's the only way to actually prove a change didn't break the core capability
- Keep decision logic in `Engine` as pure functions (no clock, no IOKit, no file I/O) and
  add tests alongside
- **Do not widen the XPC protocol.** It can express only `off` / `indefinite` /
  `until(seconds)`, with no field able to carry a path, command, or shell argument. That is
  the project's most important security property

---

<div align="center">

### 👋 Follow the author

**Cogito** ([@NeoSpecies](https://github.com/NeoSpecies))

WeChat Official Account · Douyin · WeChat Channels — all named **顽皮的程序员**

[![Website](https://img.shields.io/badge/Website-neospecies.ai-000000?style=for-the-badge&logo=safari&logoColor=white)](https://www.neospecies.ai)
[![GitHub](https://img.shields.io/badge/GitHub-NeoSpecies-121011?style=for-the-badge&logo=github&logoColor=white)](https://github.com/NeoSpecies)
[![Email](https://img.shields.io/badge/Email-neospecies@outlook.com-D14836?style=for-the-badge&logo=maildotru&logoColor=white)](mailto:neospecies@outlook.com)

</div>

## License

[MIT](LICENSE)
