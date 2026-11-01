# TouchAnywhere

**Touch-native macOS from any remote client — wherever you are.**
Swipe to scroll, tap to click, press-and-hold to drag, grab a title bar to move a window — the way an iPad feels when it drives a Mac over Sidecar, but through *any* remote-desktop app, on any network.

[简体中文](README.zh-CN.md)

> Not affiliated with Apple. macOS and Sidecar are trademarks of Apple Inc.

## How I use it

My Mac sits at home. I drive it from a **Samsung Galaxy Z Fold** (unfolded, touch only) through **Jump Desktop**, with TouchAnywhere running on the Mac — from the office, a café, another country. Swiping scrolls, dragging moves windows, tapping hits small buttons. I do web coding, writing and day-to-day work that way.

In my own daily use it feels better to me than Sidecar does — not because Sidecar's touch is bad, but because I can use it from anywhere, and because I kept tuning the details (when a gesture is a scroll and when it is a drag, how far a fingertip may miss a button) until they stopped getting in my way. That is a personal impression, not a benchmark; try it and see.

## The problem

Apple's Sidecar gives an iPad real touch control of a Mac, but it only works close to the Mac, on the same local network. Away from home, you reach the Mac through a remote-desktop app — Jump Desktop, Sunlogin/AweSun, RustDesk, VNC, and so on — and the touch experience falls apart:

- Your finger arrives at the Mac as a **mouse**. One finger can only drag; scrolling needs two fingers.
- Tapping a 14-pixel window button or toolbar icon with a fingertip has to be pixel-perfect.
- The client has no idea what is under your finger, so it cannot tell "scroll this page" from "move this window".

## What TouchAnywhere does

A small menu-bar helper that runs **on the Mac you are controlling**. It watches the mouse events coming from the remote client and rewrites them:

| You do | What happens |
|---|---|
| Swipe with one finger on content | Scrolls, with momentum after you lift off |
| Tap | Click (double-tap = double-click) |
| Tap *near* a small button | Snaps to the nearest small control (window buttons, toolbar icons, checkboxes, tabs) and clicks its centre |
| Rest your finger ~0.2 s, then move | A real drag — select text, move things |
| Swipe starting on a title bar, toolbar strip, scrollbar, slider, menu or window edge | Stays a normal drag, so moving and resizing windows works |
| Hold ⌘ ⌥ ⌃ or ⇧ | Never touched |

Local mouse and trackpad input is left alone by default (only input that comes from another process is translated).

It does not replace your remote-desktop client. It makes whatever client you use behave as if the Mac were a touch device.

## Status

Early (v0.1), written by one person for their own daily use, then cleaned up for sharing.

- Developed and used on Apple silicon with **macOS 27**, driven from an **iPad** and a **Samsung Galaxy Z Fold** through **Jump Desktop**. It builds for macOS 13+, but I have not tested older systems.
- Other clients (Sunlogin/AweSun, RustDesk, VNC viewers, …) should work if they inject input as ordinary mouse events from their own process, but **I have not tested them**. Reports welcome.
- Only the Mac side. It cannot help a client that never sends your finger as a mouse drag.

## Install

You need the Swift compiler from the Xcode Command Line Tools (`xcode-select --install`). No full Xcode, no dependencies, no network.

```bash
git clone https://github.com/n486888108-hue/touch-anywhere-mac.git
cd touch-anywhere-mac
bash build.sh --install
```

Then allow it in **System Settings → Privacy & Security → Accessibility**. It starts working as soon as you do — no restart needed. A small hand icon appears in the menu bar.

If you rebuild later, the Accessibility permission survives (the build signs the app with an identifier-only requirement). If a switch looks on but nothing happens, remove TouchAnywhere from the list with “−” and add it back with “+”.

## Settings (menu-bar icon)

- **Translate finger swipes** — master switch.
- **Only remote input** — leave the local mouse alone (default on).
- **Momentum after release**, **Reverse direction**.
- **Scroll vs. drag** — how long a resting finger counts as "drag": 0.15 s / 0.22 s (default) / 0.35 s.
- **Tap snapping** — Off / 14 / 24 (default) / 36 points.
- **Diagnostic log** — `~/Library/Logs/TouchAnywhere.log` records, for every touch, what was under the finger and why it was treated as scroll or drag.

## How it works

1. A `CGEventTap` sees left-button down / drag / up events. Events posted by the helper itself carry a tag and are ignored.
2. By default only events whose source process is not the hardware (`eventSourceUnixProcessID != 0`) are handled — that is how remote clients deliver input.
3. On finger-down the event is held back. The Accessibility API says what is under the finger (`HitTest.swift`): title-bar/toolbar strip, scrollbars, menus, window edge, …
4. `TouchEngine.swift` is a small pure state machine — it decides *scroll / click / drag / pass-through* and returns the events to post, without touching the system. That makes it unit-testable.
5. Scrolls are posted as continuous pixel scroll events with begin/change/end phases, plus synthetic momentum.

Everything is plain Swift and AppKit; about 800 lines.

## Self-tests

```bash
~/Applications/TouchAnywhere.app/Contents/MacOS/TouchAnywhere --selftest     # decision rules, touches nothing
~/Applications/TouchAnywhere.app/Contents/MacOS/TouchAnywhere --scrolltest   # opens a small window, checks scroll direction
~/Applications/TouchAnywhere.app/Contents/MacOS/TouchAnywhere --snaptest     # checks tap snapping on a real window's traffic-light buttons
~/Applications/TouchAnywhere.app/Contents/MacOS/TouchAnywhere --dragtest     # simulates a finger drag on a title bar
~/Applications/TouchAnywhere.app/Contents/MacOS/TouchAnywhere --hit 600 500  # what is at this point, scrollable or not
```

## Known limits

- **Multi-finger gestures are invisible.** Remote clients flatten them: in my tests a three-finger swipe arrived as an ordinary horizontal scroll, with no gesture event. So three-finger desktop switching cannot be done from the Mac side alone.
- Dragging inside content (selecting text, drag-and-drop) needs a brief press-and-hold first — that is the price of making plain swipes scroll.
- The hit-test uses the Accessibility API; an app that does not answer in time is treated as "scrollable".
- Code comments are mostly in Chinese; translations are welcome.

## Ideas

Edge-swipe or on-screen strip for switching Spaces, pinch-to-zoom (⌘+scroll), per-app rules, a signed/notarised release build. Issues and pull requests are welcome.

## License

MIT — see [LICENSE](LICENSE).
