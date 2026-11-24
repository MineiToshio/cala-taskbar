# Zones

Zones is one of Cala's four modules (see [architecture.md](architecture.md#modules)). While you drag a window of another app, you bring up a set of rectangles ("zones") on that monitor and drop the window into one: the window takes that zone's position and size. Zones works with or without the bar; someone who only wants zones turns the Bar off and Cala lives in the menu bar.

Contents: [Using it](#using-it) · [Overlap and several zones](#overlap-and-several-zones) · [What gets moved](#what-gets-moved) · [Layouts](#layouts) · [Coordinates and the usable area](#coordinates-and-the-usable-area) · [Storage](#storage-zonesjson) · [Monitors](#monitors) · [Editor](#editor) · [Settings keys](#settings-keys) · [Permissions](#permissions) · [Threads and cost](#threads-and-cost) · [Drag-gesture prototype](#drag-gesture-prototype-and-what-is-still-unmeasured) · [Known limitations](#known-limitations) · [Manual test checklist](#manual-test-checklist-for-the-owner)

## Using it

1. Turn Zones on: Settings → General → **What Cala does** → Zones (or answer "What do you want to use?" in the welcome). With Accessibility granted it starts at once, no restart.
2. Drag a window by its title bar (or any area the app lets you drag it from).
3. While the left button is still down, bring the zones up:
   - **Right-click** (once to show, again to hide), or
   - **Hold Shift** (zones show while Shift is held).
4. Move over a zone: it fills strongly and its outline shows exactly where the window will land. Release the mouse over it and the window snaps.

`zonesActivation` chooses which gesture counts: `rightClick`, `shift` or `both` (default `both`, so Shift always works).

**Cancelling.** Right-click a second time (zones off), release Shift, or release the mouse outside every zone: the window simply stays where you dropped it. There is no Esc: the tap only sees the mouse (see [Permissions](#permissions)).

**What the overlay shows.** One click-through panel per monitor that has a layout, covering that monitor's usable area ([below](#coordinates-and-the-usable-area)), above normal windows and above Cala's bar. Every zone has a thin outline; the zone that will receive the window is filled strongly with a 3 pt border in the theme accent (the macOS accent colour with the System theme); other zones under the pointer get a soft tint. The panels fade in and the highlight moves in 120 ms; with **Reduce Motion** on there is no animation. A pointer over the menu bar, Cala's bar strip or the Dock picks the nearest point of the usable area, so a window grabbed by its top edge still picks a zone. Monitors showing "Off" get no overlay.

**The right-click is swallowed only during a confirmed window drag.** A drag is confirmed when, at mouse-down, the topmost window under the pointer is a normal window of another app (not Cala's own, not the menu bar, Dock or a panel), and it then moves at least 3 pt while its size stays the same (this check uses only the window list, so it is confirmed at once; the Accessibility details follow right after). Resizing from an edge, selecting text, dragging a slider or drag-and-drop inside an app are therefore never window drags, and a right-click there reaches the app as usual (context menus keep working). The matching right-button-up is swallowed too, so the app never sees an orphan "up". The reverse also holds: a right-button-down that is *not* swallowed clears any pending swallow, so an "up" lost upstream (a remapper, a dropped Bluetooth link) can never eat a later, ordinary right-click.

**Dragging a snapped window out restores its size.** Cala remembers each window's size from before its first snap (in memory only, up to 200 windows, forgotten when Cala or the module stops). When you drag a window that is still exactly where it was snapped (within 2 pt), it gets its original size back at once, keeping the grab point under the pointer horizontally. If you had resized it by hand since, nothing is restored. If the app refuses a size change in the middle of the drag, Cala retries on mouse-up.

**Gap.** `zonesGap` (0 to 40 pt, default 8) is the space around each snapped window. A zone edge on the screen's usable boundary is inset by the full gap and an edge shared with another zone by half, so two neighbours end up one gap apart and the screen margin equals the gap. If a zone is too small for the gap, the inset shrinks so at least 40 pt remain. The overlay draws the gapped rectangle, so it previews exactly what you get. Picking always uses the real (ungapped) zone, so the gap is never a dead area under the pointer.

## Overlap and several zones

Zones may overlap (a small "picture-in-picture" zone over a big one is fine).

- **Which zone wins** when the pointer is over several: the **smallest** zone (by area); on a tie, the **most recently created** one. Creation order is stored per zone (`seq`), so it does not depend on the clock and survives duplicating a layout.
- **Hold ⌘ to span.** Zones mode remembers the zone that was chosen when ⌘ went down (or the first one chosen after it). While ⌘ stays down, the target becomes the **bounding rectangle** of that anchor zone and the zone under the pointer, and every zone that lies inside that rectangle is highlighted with it. The span only counts when the zones are contiguous (overlapping or sharing an edge; a shared corner alone does not connect them); if they are not, the zone under the pointer is used alone. Release ⌘ to go back to one zone; moving to another monitor clears the anchor. The gap is applied once to the bounding rectangle.
- A span is a plain target: the snapped window keeps no memory of which zones it covers.

## What gets moved

Cala moves a window through the Accessibility API (`AXPosition` and `AXSize`); it never injects clicks or drags.

Ignored (the window is never offered zones). Cala decides this a few milliseconds after the drag starts, because a right-click must be swallowed from the first instant of a real window drag; once it has found the window cannot be placed it stops swallowing, so only a right-click in that very first moment is lost, and later right-clicks reach the app normally:
- Cala's own windows, including the zones editor.
- Full-screen windows.
- Sheets (`AXSheet`), system dialogs (`AXSystemDialog`) and windows with an unknown subrole. Ordinary app dialogs (`AXDialog`) are movable.
- Windows whose position cannot be set.
- Windows of macOS UI processes: Dock, SystemUIServer, Control Center, Notification Center, loginwindow, SecurityAgent, CoreServicesUIAgent, Spotlight, WindowManager (Stage Manager) and the screenshot UI. Normal system apps (Finder, Safari, Notes...) work like any other app.
- Windows with no Accessibility entry (an app that exposes no `AXWindows`). The log says why: `zones: ignoring drag ...`.

How the window is placed:
- **Resizable:** size, then position, then size again (some apps clamp the size to the monitor the window was on before the move), then read back.
- **Bigger than the zone** (the app has a minimum size): the window keeps its size, starts at the zone's top-left corner and is kept inside the usable area.
- **Smaller or rounded** (terminals snap to character cells): the size is accepted and the zone's corner kept.
- **Not resizable** (position only): centred in the zone, kept inside the usable area.
- Chromium and Electron apps animate and fight frame changes while `AXEnhancedUserInterface` is on, so Cala switches it off around the move and puts it back.

The snap happens about 40 ms after the mouse is released, so the app and the window server finish their own drag first. Drags are ignored while the zones editor is open and while the module is off.

## Layouts

A **layout** is a named set of zones. The first start with no `zones.json` creates one editable layout per template, named in the current interface language:

| Template id | Zones (x, y, w, h as fractions) |
|---|---|
| `two-columns` — Two columns (default layout) | (0, 0, ½, 1) · (½, 0, ½, 1) |
| `three-columns` — Three columns | three vertical thirds |
| `grid-2x2` — 2 × 2 grid | four quarters |
| `main-side` — Main + side | (0, 0, ⅔, 1) · (⅔, 0, ⅓, 1) |
| `side-main` — Side + main | (0, 0, ⅓, 1) · (⅓, 0, ⅔, 1) |
| `two-rows` — Two rows | (0, 0, 1, ½) · (0, ½, 1, ½) |
| `main-two-stacked` — Main + two stacked | (0, 0, ½, 1) · (½, 0, ½, ½) · (½, ½, ½, ½) |
| `wide-center` — Wide center | (0, 0, ¼, 1) · (¼, 0, ½, 1) · (¾, 0, ¼, 1) |

You can create as many layouts of your own as you like (from the editor: blank, or from any template), duplicate one (the copy is named "… copy"), rename it and delete it. The last remaining layout cannot be deleted. Templates are only starting points: after the first start they are ordinary layouts you can edit or delete.

There is one **default layout** (starts as Two columns). A monitor with no choice of its own uses it. Deleting a layout sends the monitors that used it back to the default; if the default itself is deleted, the first remaining layout becomes the default.

## Coordinates and the usable area

**Decision.** Zones are stored as **fractions (0 to 1) of the monitor's usable area, with the origin at the top-left and y growing down** (`x`, `y`, `w`, `h`). They are not stored in points.

Why fractions:
- A layout still makes sense when a monitor changes resolution or scaling, and when it is shared between monitors of different sizes (the same "Main + side" works on a laptop and an ultrawide).
- Top-left fractions match how people describe zones ("top half") and make the templates readable in `zones.json`. The single flip to macOS's bottom-left origin lives in one function.
- Adjacent zones share an exact edge: each endpoint is converted on its own, so a boundary shared by two zones becomes the same coordinate and no hairline gap appears.

**Usable area.** `usable = visibleFrame`, which already excludes the macOS menu bar (taller on notched screens) and a Dock that is currently showing, **minus Cala's bar strip when the bar is running and does not auto-hide**.
- The bar is a floating panel and does not change `visibleFrame`, so it is subtracted explicitly: the strip is `iconSize + 20` pt from the bottom of **every** monitor (there is a bar on each one). A snapped window therefore never sits under Cala's bar.
- With **auto-hide** on (the default) the bar only appears when you touch the bottom edge and overlays windows by design, exactly as it does for any maximized window, so the usable area is the whole `visibleFrame`. Subtracting a permanent strip would leave an empty band.
- With the Bar module off there is no strip.
- The usable area is **never cached**: it is recomputed whenever zones mode starts and whenever the editor opens or the screens change. If you toggle the Dock's auto-hide, Cala's auto-hide or the Bar module, zones rescale accordingly (a snapped window already in place is not moved).

**Coordinate spaces** (a source of subtle bugs): AppKit uses a bottom-left origin at the **primary** screen (the one with the menu bar, not `NSScreen.main`); event and Accessibility coordinates use a top-left origin at that same screen. All geometry runs in AppKit space; the tap point is flipped once on the way in and the target rectangle once on the way out. A screen is found with half-open containment; a point in a gap between monitors goes to the nearest monitor.

## Storage: `zones.json`

`~/Library/Application Support/Cala/zones.json`. It is a separate file from `config.json` so that a damaged zones file can never cost you your bar settings, and nested arrays do not fit the flat per-field recovery `config.json` uses. Written atomically, pretty-printed with sorted keys, and only when something is committed (editor Save, a layout choice, duplicate, delete); each change is written before it goes live. The scalar preferences (`zonesEnabled`, `zonesActivation`, `zonesGap`, `zonesEditorGrid`) stay in `config.json`.

```json
{
  "activeByDisplay": { "793B322E-9748-43CF-8A63-BA18283C7D7F": "5C0E…", "A1B2…#2": "off" },
  "defaultLayout": "5C0E…",
  "layouts": [
    {
      "id": "5C0E…",
      "name": "Two columns",
      "nextSeq": 2,
      "template": "two-columns",
      "zones": [
        { "id": "…", "seq": 0, "rect": { "x": 0,   "y": 0, "w": 0.5, "h": 1 } },
        { "id": "…", "seq": 1, "rect": { "x": 0.5, "y": 0, "w": 0.5, "h": 1 } }
      ]
    }
  ],
  "version": 1
}
```

- `activeByDisplay`: monitor key → layout id, or `"off"`. A monitor with no entry uses `defaultLayout`.
- `seq`/`nextSeq`: creation order, used only to break ties between equal-size overlapping zones. `template` is informational.
- **Read only when the module starts** (and when the editor opens with Zones off). With Zones off, nothing reads this file.
- **Repair on load:** rectangles that are not finite numbers are dropped; the rest are clamped into the screen with a minimum size of 5 %; duplicate layout or zone ids are dropped; assignments pointing at a missing layout are removed; with no layouts left the templates are seeded again; a missing default becomes the first layout.
- **Damaged file:** if it cannot be decoded it is moved to `zones.json.bad` (replacing an older `.bad`), the templates are seeded and a new file is written. If the move itself fails, saving is disabled for that run so the original is not overwritten (same policy as `config.json`). If `zones.json` cannot be loaded at all, the module logs `zones: could not load zones.json` and does not start.
- The uninstaller deletes the whole support folder, so it needs no special case.

## Monitors

- **Identity.** A monitor is keyed by its CoreGraphics display UUID (the same key `alignments` uses in `config.json`), or the numeric display id if macOS gives no UUID. **Identical monitors** that report the same UUID get a `#2`, `#3`... suffix, ordered by position left to right then top to bottom. That order is stable only while the arrangement does not change (known limitation).
- **Per-monitor choice.** Each monitor has its own active layout, or **Off** (no overlay and no snapping there). Choose it from the menu-bar icon (Layout · *monitor* → pick a layout, or "Off on this display"), from Settings → Zones → Layout per monitor, or with "Use on this monitor" in the editor.
- **Disconnect.** The assignment stays in the file, like icon alignment. If zones mode is active and its monitor goes away, zones mode is cancelled and the window stays; any other screen change rebuilds the overlay in place.
- **Connect.** A known monitor gets its stored layout; an unknown one gets the default layout (nothing is written until you choose).
- Mirrored displays are one screen with one key. A Space change does not cancel zones mode (it fires whenever the pointer carries a window onto another monitor, and an edge push to a neighbouring Space carries the window along): the overlay panels join every Space, are brought back to the front, and the target is recomputed from the pointer.

## Editor

Open it from the menu-bar icon (**Zones editor…**, on the monitor under the pointer) or Settings → Zones → **Edit zones…** (with a monitor picker when there is more than one monitor). It works even with the Zones module off: it loads `zones.json` on its own and a Save writes the file, which the module reads when it starts. With the module on, a Save is live at once.

It is a borderless window that covers the chosen monitor, above everything including the bar. The working area (the usable rectangle) is drawn on a dimmed screen, so what is outside it (menu bar, Dock, Cala's bar strip) is visibly excluded.

On the canvas:
- **Draw:** drag on an empty area. The **Draw zone** button turns drawing on everywhere, including over existing zones (for overlap).
- **Move:** drag a zone. **Resize:** drag one of its eight handles (corners and edge midpoints) or its border.
- **Select** a zone by clicking it. **Delete** or **Forward Delete** removes it; **⌘D** duplicates it.
- Zones cannot leave the screen, and cannot be smaller than the larger of 5 % of the usable size and 80 pt.
- **Snapping:** within 8 pt, an edge snaps to another zone's edges, the screen's edges and its centre line (½); with **12×12 grid** on, also to the twelfths. Active snap lines show as dashed guides. Hold **⌥ (Option)** to turn snapping off while dragging. The grid choice is remembered (`zonesEditorGrid`).
- Overlapping zones use the same "smallest wins" rule to decide which one you grab.

The top panel (collapsible) holds: **Monitor** picker (moves the editor to that monitor), **Layout** picker, layout name, **New layout** (blank or from any template), **Duplicate**, **Delete layout**, the grid checkbox, **Use on this monitor** (or the "In use on this monitor" badge), **Cancel** and **Save**.

Edits happen on a draft. **Save** (button, **⌘S** or **Return**) writes everything in one atomic write. **Cancel**, **Esc** or closing the window asks "Discard changes to zones?" only if something changed. Deleting a layout is staged and takes effect on Save. Saving merges the draft into the live state, so a layout changed elsewhere while you were editing is not overwritten. **Drags are ignored the whole time the editor is open**, so a window dragged at that moment never triggers zones.

## Settings keys

All in `config.json`; full reference in [configuration.md](configuration.md#modules-and-zones).

| Key | Default | Meaning |
|---|---|---|
| `zonesEnabled` | `false` | The Zones module is on |
| `zonesActivation` | `"both"` | `rightClick`, `shift` or `both`. Anything else becomes `both` |
| `zonesGap` | `8` | Space around snapped windows, 0 to 40 pt (clamped) |
| `zonesEditorGrid` | `false` | The editor's 12-division snapping |

Settings → **Zones** has the module switch, the gesture picker, the gap slider, one layout picker per monitor, **Edit zones…**, and a note about macOS's own edge tiling.

## Permissions

**Accessibility only.** It is needed to move and resize windows, and an *active* event tap (one that can swallow an event) is only granted to an Accessibility-trusted process. This was measured in the prototype: without it, creating an active tap is refused for both mouse and keyboard masks.

Not needed:
- **Input Monitoring.** The tap listens to mouse buttons only (left down, up and dragged; right down and up) and never sees keystrokes. Shift and ⌘ are read from the flags every mouse event already carries.
- **Screen Recording.** Zones never captures anything.

If only Zones is on, the welcome and Settings ask for Accessibility with a Zones-specific reason, and nothing else. Without it the module still starts (menu-bar icon, layouts and the editor work) and waits: every 3 seconds, and sooner when macOS announces an Accessibility change, it tries to install the tap, so zones come alive the moment you grant it, with no restart. Revoking Accessibility removes the tap.

## Threads and cost

An active event tap sits in the path of **every** mouse click on the Mac, so the design keeps it harmless:

| Thread | Owns | Rules |
|---|---|---|
| Tap thread (`Cala.zones.tap`, own run loop) | The `CGEventTap` and its callback | O(1): updates a small state machine under an unfair lock and hands off with `async`. No Accessibility, no `CGWindowList`, no logging or file I/O. A stall in Cala's UI can never delay system mouse input |
| Worker (`Cala.zones.worker`, serial queue) | Every `CGWindowList` and Accessibility call: finding the window under the press, confirming it moves, resolving its AX element, snapping, restoring | Per-element Accessibility timeout 0.25 s; stale results are dropped by a press generation counter |
| Main | Overlay panels, the store, the editor, the status menu, session start and end | Receives the pointer position as one coalesced update, not one per event |

If macOS disables the tap (timeout or user input) it is re-enabled at once, the current gesture is cancelled and the overlay is hidden (also when the periodic check, not the callback, finds the tap disabled), so a missed mouse-up cannot leave zones mode or a click-through overlay stuck; the mouse-up of an already confirmed drag is still reported, so a drag-out size restore finishes; the periodic check also rebuilds a dead tap. When the module stops, the tap is disabled and invalidated, its thread ends, the worker's queued work is cancelled, snap records are dropped and every overlay panel is closed and released.

## Drag-gesture prototype and what is still unmeasured

Before building the module a spike ([`scripts/prototypes/drag-tap/`](../scripts/prototypes/drag-tap/README.md), commit `d9b42bc`) measured what could be measured on a development Mac:

- **Measured:** an active (`.defaultTap`) session tap is refused (`nil`) without Accessibility, for mouse and keyboard masks; a listen-only tap is created without any permission (but macOS withholds keystrokes from listen taps without Input Monitoring, which is why Zones does not rely on keys). `CGWindowList` queries cost about 0.1 to 0.3 ms (median) with spikes near 9 ms; an Accessibility hit-test is about 0.3 ms with a 28 ms spike. That is why neither runs inside the tap callback.
- **Not measured (pending the owner's manual test):** whether the window server keeps a window drag alive, and still delivers the left-button-up normally, when a right-click is **swallowed in the middle** of that drag. The automated environment was a background Fast User Switching session, which receives no input, so a synthetic drag could not reach any window. Other tools and the documented behaviour say it works, because the swallowed event never reaches the window server's routing or the app, but it is not proven here.

Consequence: the default is `both`. **Shift always works and needs no swallowing**; the right-click is the FancyZones-style extra. If the manual test (step 1 below) fails, because the drag stops following the pointer, the button-up is lost or a context menu flashes, Shift becomes the only gesture (set `zonesActivation` to `shift` and make that the default).

## Known limitations

- **The right-click gesture is unproven** (above). Use Shift if a drag misbehaves.
- **macOS 15+ has its own edge tiling** ("Drag windows to screen edges to tile", System Settings → Desktop & Dock → Windows). Dropping a window near an edge can make macOS tile it as well. Zones cannot turn that off; Settings → Zones says whether it is on and has a button that opens Desktop & Dock. Cala also logs it once at start.
- **Pausing Cala in a debugger with Zones on freezes mouse input** until macOS disables the stalled tap (an active tap blocks events while its callback is not running). Stop the module first (Settings → Zones off) when debugging.
- **Apps with a minimum size** end up larger than the zone (placed at its top-left); **non-resizable windows** are only centred in it; some apps (terminals) round to cell sizes. Apps that fight Accessibility frame changes may need a second try.
- **Identical monitors with the same UUID** are told apart by arrangement; rearranging them can swap their layouts.
- **Zones rescale** when the usable area changes (a Dock that shows, the bar's auto-hide, the Bar module). macOS may also inset `visibleFrame` by a few points even for an auto-hidden Dock; Cala does not compensate. Windows already snapped are not moved when this happens.
- **Windows on other Spaces, full-screen windows and Mission Control** are not offered zones. Stage Manager's strip is not treated as a window.
- **Snap memory** (the original size to restore) is in memory only: gone after quitting Cala or turning the module off.
- **No keyboard or VoiceOver navigation in the editor** (the canvas is announced as one element with its zone count and help text) and **no Esc to cancel zones mode**. Both are on the [roadmap](roadmap.md).
- The module works only with a mouse or trackpad drag; there are no keyboard shortcuts to move windows.

## Manual test checklist (for the owner)

Do this from the **console** session (a background Fast User Switching session receives no input), with Accessibility granted to Cala.

**0. The integrated feature in the real app** (do this first; it also covers the go/no-go below).
- [ ] Build: `./build.sh` (produces `build/Cala.app`), or `./install.sh` to use `~/Applications/Cala.app` (preferred: grants are tied to the path, see [setup.md](setup.md)). Run it from the **console** session.
- [ ] System Settings → Privacy & Security → **Accessibility** → add and enable that Cala (no Screen Recording or Input Monitoring needed for Zones alone). Cala notices without a restart; the debug log shows `zones: event tap active (mouse only, mask 0x5e)`.
- [ ] Settings → General → What Cala does → turn **Zones** on. Settings → Zones shows one layout picker per monitor (default: Two columns).
- [ ] Gestures: drag a window, right-click (zones appear, no context menu, window keeps following), right-click again (hide), hold Shift (show while held), **⌘** over two adjacent zones (combined rectangle), release over a zone (snap with the gap), release outside (window stays), second right-click then release (window stays).
- [ ] Drag the snapped window out: its old size returns. Change *Activate zones with* to Right-click only and to Shift only and check that the other gesture stops working.
- [ ] Editor: menu-bar icon → **Zones editor…** or Settings → Zones → Edit zones…; draw, move, resize, guides, grid, Save; the new layout works immediately without restarting.
- [ ] Welcome and migration **without touching your real settings**. Cala's data folder does not depend on the bundle id, so a separate id alone is not enough; also redirect the home folder:
  ```bash
  CALA_BUNDLE_ID=local.cala.dev ./build.sh            # own defaults domain and own Accessibility identity
  # Quit your real Cala first (Settings → Advanced → Quit). Never run both at once.
  DEVHOME=$(mktemp -d); mkdir -p "$DEVHOME/Library/Application Support/Cala"
  echo '{ "relaunchOnCrash": false, "hideNativeDock": false, "hideMenuBar": false }' > "$DEVHOME/Library/Application Support/Cala/config.json"
  defaults delete local.cala.dev 2>/dev/null            # new-user scenario (omit for an existing user: defaults write local.cala.dev onboardingCompleted -bool true)
  open -n --env CFFIXED_USER_HOME="$DEVHOME" build/Cala.app
  tail -f "$DEVHOME/Library/Application Support/Cala/debug.log" | grep -E "modules:|module |zones:|onboarding"
  ```
  `relaunchOnCrash: false` matters: the crash watchdog reopens Cala without that environment, against your real data. The redirect covers `config.json`, `zones.json` and `debug.log` but **not** UserDefaults (hence the separate bundle id), the Dock and menu-bar system settings (keep the two hide options off), the Keychain or login items (untick "Open Cala at login" in that welcome). Grant Accessibility to this dev build separately.
  - New user: the log shows `modules: active=none off=bar,switcher,tray,zones source=provisional (waiting for onboarding)` and nothing but the menu-bar icon is on screen until "What do you want to use?" is answered, with both boxes unchecked. Quit before answering, relaunch: the welcome shows again.
  - Choose only Zones: no bar, only the Accessibility page, then `modules: apply active=zones ...` and `zones: event tap active`. Choose Bar: bar, tray and Option+Tab, no `zones:` lines.
  - Existing user (`onboardingCompleted` set, with a config where `switcherEnabled` is false): `source=migrated`, Bar and Tray on, Switcher off, Zones off, no welcome.
  - Cleanup: quit it, `defaults delete local.cala.dev`, `tccutil reset All local.cala.dev`, `rm -rf "$DEVHOME"`.
- **Debugging warning:** pausing Cala in a debugger with Zones on freezes mouse input for the whole Mac until macOS disables the stalled tap. Turn Zones off (Settings) before attaching a debugger or setting breakpoints in the tap or drag code.

**1. Go/no-go for the right-click gesture** (the one unmeasured item). Settings → Zones → *Activate zones with* → **Right-click**.
- [ ] Drag a Finder or TextEdit window by its title bar, right-click mid-drag: the zones appear, **no context menu**, and the window **keeps following the pointer**.
- [ ] Right-click again: zones hide, window still follows. Right-click once more and release over a zone: the window snaps.
- [ ] Same with a Chrome or other Electron window dragged by its tab strip.
- [ ] Release the button while zones are showing, over empty space: the window stays, and the next click behaves normally (the left-up was not lost).
- If any of these fail: set *Activate zones with* to **Hold Shift**, and make Shift the default.
- Optional isolated probe, with the same checks and its own log: see [scripts/prototypes/drag-tap/README.md](../scripts/prototypes/drag-tap/README.md).

**2. Things that must not trigger zones** (right-click must still open the app's context menu):
- [ ] Select text in TextEdit with the button held and right-click.
- [ ] Resize a window from its left edge, then from a corner.
- [ ] Drag a window in Mission Control.
- [ ] Hold Shift while dragging text or files in Finder (no window moves).

**3. Snapping**
- [ ] Shift: zones show only while held; releasing Shift before the mouse cancels.
- [ ] Drop into a zone: the window matches the overlay rectangle, gap included.
- [ ] ⌘ across two adjacent zones snaps to their combined rectangle; across two non-adjacent zones it uses one zone.
- [ ] Overlapping zones: the smaller one is chosen; with equal sizes, the newer one.
- [ ] Drag the snapped window out: it returns to its previous size under the pointer.
- [ ] A fixed-size window (System Settings) is centred; a window with a large minimum size starts at the zone's corner.
- [ ] Full-screen windows and sheets do not offer zones.

**4. Usable area**
- [ ] Bar on with auto-hide **off**: no zone reaches under the bar. Auto-hide **on**: zones use the full height and the bar overlays.
- [ ] Bar off: zones fill the visible area; no bar, no reserved space.
- [ ] Dock visible at the bottom or side: zones stop at it.

**5. Monitors** (with two or more)
- [ ] Each monitor can have a different layout and **Off**; both are remembered after a restart.
- [ ] Unplug and replug a monitor: its layout comes back; a new monitor gets the default.
- [ ] Unplug the monitor under the pointer mid-drag: zones mode cancels and the window stays.

**6. Editor**
- [ ] Draw, move, resize from all eight handles; zones cannot leave the screen; ⌥ disables snapping; dashed guides show; the grid toggle works and is remembered.
- [ ] New layout (blank and from a template), duplicate, rename, delete (the last one cannot be deleted).
- [ ] Cancel with changes asks to discard; Save keeps them; dragging a window while the editor is open does nothing.
- [ ] With Zones off, the editor still opens from the menu-bar icon and its Save is used when Zones is turned on.

**7. Modules and permissions**
- [ ] Zones only (Bar off): no bar, no reserved space, the Dock and menu bar are as macOS has them; the menu-bar icon offers Settings…, Zones editor…, one layout menu per monitor and Quit.
- [ ] Turn Zones off (Bar on): the menu-bar icon disappears, `debug.log` shows `modules: apply ...` and no `zones:` lines afterwards, and clicks and right-clicks behave exactly as before.
- [ ] Revoke Accessibility while Zones runs, then grant it again: zones stop and then come back without restarting Cala.
