# Drag-tap spike (Zones feasibility)

A throwaway prototype, **not part of the app target and not shipped**. It answers one question for the Zones module: can Cala watch a window drag and swallow a right-click in the middle of it, with which permission, and what does detection cost?

The real implementation is in `Sources/Cala/Zones/` (see [docs/zones.md](../../../docs/zones.md)). This folder is kept as the evidence behind its design and as the tool for the one test that could not be automated.

## What it does

While you drag a window of **another app** with the left button:
- a right-click toggles "zones mode" and is **swallowed** (the app under the pointer never sees it, so no context menu);
- holding Shift is logged as the alternative gesture (nothing is swallowed for it);
- on release in zones mode it only logs that a snap would happen. It never moves a window.

Only the right button is ever swallowed, only during a confirmed foreign window drag; everything else passes through. Its tap runs on its own thread with an O(1) callback, and is re-enabled at once if macOS disables it. It exits by itself after at most 60 s.

## Build and run

```bash
cd scripts/prototypes/drag-tap
./build.sh                                    # builds build/DragTapProbe.app
open build/DragTapProbe.app --args --probe    # permissions report only, then exits
open build/DragTapProbe.app                   # live mode, exits by itself after 60 s
tail -f /tmp/drag-tap-probe.log               # everything is logged here (and to stdout)
```

Options: `--log <path>` (default `/tmp/drag-tap-probe.log`), `--seconds <n>` (maximum 60).

`build.sh` produces a small ad-hoc-signed app with bundle id `local.cala.tapprobe` and a fixed designated requirement. macOS therefore treats it as its **own** identity (instead of inheriting the Terminal's permissions), and a grant survives rebuilds. `build/` is git-ignored.

## What it logs

- `PROBE`, `AXIsProcessTrusted`, `CGPreflightListenEventAccess`, `CGPreflightPostEventAccess`: the identity and permissions it sees.
- `tapCreate active mouse`, `listen mouse`, `active keys`, `listen keys`: `OK` or `nil (FAILED)`.
- `cost ...`: median and maximum time of a full on-screen `CGWindowList` query, a single-window bounds query and one Accessibility hit-test.
- Live mode: `DRAG START pid=… win=…` once a foreign window actually moves (at least 3 pt, same size), `ZONES MODE ON/OFF (right click swallowed)`, `SHIFT held during drag`, `DRAG END → SNAP would happen (zones mode ON)`, `TAP re-enabled after timeout|user input`, `ACTIVE TAP FAILED: grant Accessibility to … and relaunch` and `---- exit (…)`.

## Results

**Measured** (macOS 26, Apple silicon):
- With no permission, an **active** (`.defaultTap`) session tap is refused (`nil`) for both mouse and keyboard masks. With Accessibility it is created. Input Monitoring is not needed, because Shift and ⌘ ride in the flags of every mouse event.
- A **listen-only** tap is *created* with no permission. Creation is all that was measured; macOS documents that keystrokes are withheld from listen taps without Input Monitoring.
- `CGWindowList` queries: about 0.1 to 0.3 ms median, spikes near 9 ms. One Accessibility hit-test: about 0.3 ms median, a 28 ms spike (and it can block for seconds if the target app hangs). Neither belongs inside a tap callback.
- Window bounds, owner pid and window number come from `CGWindowList` **without any permission**, for every app (including Electron and Chrome), and a window *move* is recognised by its effect: origin changed, size unchanged. Resizes (including left and top edges) are excluded by the size check.
- The tap installs on a dedicated run-loop thread, exits cleanly on timeout and on SIGINT, and leaves nothing running.

**Documented, not measured:** Accessibility is what allows an active tap in practice (Rectangle, Hammerspoon and Cala's own window switcher rely on it); Input Monitoring alone does not.

**Not measured — the single open go/no-go item:** whether the window server keeps a left-button window drag alive, and still delivers the left-button-up normally, when a right-click is swallowed in the middle of it. It could not be tested because the automated environment was a background login session, which receives no mouse input (synthetic events never reached any window). Theory and other tools say it works, because the swallowed event never reaches the window server's routing or the app, but it is unproven. Until the manual test below passes, the Zones default is `both` (Shift always works). If it fails, Shift becomes the only gesture.

## Manual test (needs someone at the Mac's own screen)

Run it from the account that is logged in at the console and looking at the screen; a session running in the background gets no input.

1. `./build.sh`, then `open build/DragTapProbe.app --args --probe` and `cat /tmp/drag-tap-probe.log`. Expect `AXIsProcessTrusted=false` and the active taps `nil`.
2. System Settings → Privacy & Security → **Accessibility** → `+` → add `scripts/prototypes/drag-tap/build/DragTapProbe.app` (full path) and enable it. Do **not** grant Input Monitoring (that confirms it is not needed).
3. `open build/DragTapProbe.app --args --probe` again. Expect `AXIsProcessTrusted=true`, `tapCreate active mouse: OK` and `CGPreflightListenEventAccess=false`.
4. `rm -f /tmp/drag-tap-probe.log; open build/DragTapProbe.app; tail -f /tmp/drag-tap-probe.log`. You have 60 s:
   a. Drag a Finder or TextEdit window by its title bar. Expect `DRAG START`. Mid-drag, right-click. Expect `ZONES MODE ON (right click swallowed)`. **Check that no context menu appears and the window keeps following the pointer.** Right-click again for `ZONES MODE OFF`. Right-click once more and release: expect `DRAG END → SNAP would happen (zones mode ON)`, and that the release ended the drag normally.
   b. Repeat with a Chrome or other Electron window dragged by its tab strip or custom title bar.
   c. Drag-select text in TextEdit and right-click with the button held. Expect **no** `DRAG START` and the normal context menu.
   d. Resize a window from its left edge. Expect no `DRAG START`.
   e. Drag a window while holding Shift. Expect `SHIFT held during drag`.
   f. Drag a window in Mission Control. Expect no `DRAG START`.
5. Report: did the window keep moving after the swallowed right-click, did releasing still end the drag, did any context menu flash, and how soon after the drag began did `DRAG START` appear (it should feel immediate).
6. Optional: remove the probe from the Accessibility list afterwards.

The same test can be done with the real feature instead of the probe: see the manual checklist in [docs/zones.md](../../../docs/zones.md#manual-test-checklist-for-the-owner).
