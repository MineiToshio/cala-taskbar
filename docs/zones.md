# Zones

Zones is one of Cala's four modules. While you drag a window, bring up the zones on that monitor and drop the window into one to give it the zone's position and size. Zones works with or without the bar. [Module architecture](architecture.md#modules)

Contents: [Using it](#using-it) · [Overlap and several zones](#overlap-and-several-zones) · [What gets moved](#what-gets-moved) · [Layouts](#layouts) · [Coordinates and the usable area](#coordinates-and-the-usable-area) · [Storage](#storage-zonesjson) · [Monitors](#monitors) · [Editor](#editor) · [Settings keys](#settings-keys) · [Permissions](#permissions) · [Threads and cost](#threads-and-cost) · [Drag-gesture prototype](#drag-gesture-prototype-and-the-right-click-verification) · [Known limitations](#known-limitations) · [Manual test checklist](#manual-test-checklist-for-the-owner)

## Using it

1. Turn Zones on: Settings → **Zones** (or answer "What do you want to use?" in the welcome). With Accessibility granted it starts at once, no restart.
2. Drag a window by its title bar (or any area the app lets you drag it from).
3. While the left button is still down, bring the zones up:
   - **Right-click** (once to show, again to hide), or
   - **Hold Shift** (zones show while Shift is held).
4. Move over a zone: it fills strongly and its outline shows exactly where the window will land. Release the mouse over it and the window snaps.

`zonesActivation` chooses which gesture counts: `rightClick`, `shift` or `both` (default `both`).

**Trackpad:** you can’t right-click while holding a drag. Hold **Shift** while dragging. In *Settings → Zones → Activate zones with*, choose **Hold Shift** or leave **Either gesture** selected. In Spanish, the labels are *Configuración → Zonas → Activar zonas con → Mantener Mayús* or *Cualquiera de los dos*.

**Learning it.** The gesture is taught outside the drag, always the same: the welcome shows a **How to use Zones** card when Zones is chosen, and Settings → Zones has the same three steps near the gesture setting. They follow the configured gesture (right-click, Shift or both): (1) drag a window and right-click (or hold Shift), then drop it on a zone; (2) hold ⌘ to cover several neighbouring zones; (3) move over **Change layout** at the top of the screen to switch layouts (with the strip off, step 3 points to Settings and the menu-bar icon instead).

**Cancelling.** Right-click a second time (zones off), release Shift, or release the mouse outside every zone: the window simply stays where you dropped it. There is no Esc: the tap only sees the mouse (see [Permissions](#permissions)).

**What the overlay shows.** One click-through panel per monitor that has a layout, covering that monitor's usable area ([below](#coordinates-and-the-usable-area)), above normal windows and above Cala's bar. Every zone has a thin outline; the zone that will receive the window is filled strongly with a 3 pt border in the theme accent (the macOS accent colour with the System theme); other zones under the pointer get a soft tint. The panels fade in and the highlight moves in 120 ms; with **Reduce Motion** on there is no animation. A pointer over the menu bar, Cala's bar strip or the Dock picks the nearest point of the usable area, so a window grabbed by its top edge still picks a zone. Monitors showing "Off" get no overlay.

**Switching the layout while dragging (layout strip).** In zones mode, a pill appears at the top centre of the monitor under the pointer, just below the menu bar, above the zones. It always looks the same and says what it is: the current layout's small picture, its name, **Change layout** (*Cambiar distribución*) and a down chevron, for example `▦ Dev · Change layout ⌄` (12 pt, themed; "Off" with a no-entry sign on a monitor without zones). Nothing about it changes over time or with use. Move the pointer onto the pill and it opens into a row of that monitor's layouts, each pictured at the monitor's shape with its name, the current one ringed in the accent colour (the same list as the **Change layout…** picker in Settings → Zones, without Off; up to nine are shown, smaller on a narrow screen, centred on the current one when there are more). Rest the pointer on another layout for about 0.35 s (a small ring fills up) and it becomes that monitor's layout: it is saved like a choice in Settings, the zones crossfade to the new ones, its name shows briefly under the strip, and zones mode stays on, so you go on and drop the window into one of the new zones. Moving between pictures takes 0.1 s to count (no flicker on their edges), the current layout never fires, and a picture fires only once until the pointer leaves it. Leaving the strip or releasing the button cancels the wait. While the pointer is inside the open strip no zone is highlighted and a release there snaps nothing (the window stays). The closed pill never blocks the zones under it (picking goes on there as if it were not drawn); only the pill itself, not its surroundings, opens the strip. Everything runs on the main thread from the pointer position the drag already sends; the strip is a click-through panel that never takes the mouse. Turn it off with **Show layouts while dragging** in Settings → Zones (`zonesLayoutStrip`).

**Right-click is swallowed only during a confirmed window drag.** At mouse-down, Cala finds the topmost normal window under the pointer, including its own Settings window. A window must move at least 3 pt at a stable size to count as a drag. For Cala windows, AppKit also checks eligibility on the main thread before Zones can activate. Resizing, selecting text and dragging a slider leave right-clicks with the app. A swallowed right-button-down also consumes its matching up. An ordinary right-button-down clears any pending swallow from an earlier click. An unconfirmed probe expires after three seconds or resets on left-button release, so a pending probe cannot hold onto the next drag. Cala passes the raw `CGWindowID` to the CoreGraphics bounds lookup. The debug log records probe timeouts and why a detected drag has no target overlay.

When a tab detaches in an app that turns it into a live window right away (Chrome, Brave, Edge, Arc, Vivaldi, Opera and other Chromium or Electron apps), its source window can stay in place while a new window follows the pointer. This is not tied to a list of apps: a press in the upper 100 pt of any window can trigger an on-screen window list recheck on pointer movement, at most once every 40 ms. The same new window from that app's process must keep its upper band near the pointer in two consecutive samples and move with it at a stable size. If several windows qualify, Zones waits for an unambiguous sample and right-clicks still reach the browser. After a drop on a zone, Cala starts checking the adopted window's exact ID in Accessibility after 40 ms and retries about every 40 ms for up to half a second after the release is handled. A new left-button press or a cancelled gesture ends the search.

**Dragging a snapped window out restores its size.** Cala remembers each window's size from before its first snap (in memory only, up to 200 windows, forgotten when Cala or the module stops). When you drag a window that is still exactly where it was snapped (within 2 pt), it gets its original size back at once, keeping the grab point under the pointer horizontally. If you had resized it by hand since, nothing is restored. If the app refuses a size change in the middle of the drag, Cala retries on mouse-up.

**Gap.** `zonesGap` (0 to 40 pt, default 8) is the space around each snapped window. A zone edge on the screen's usable boundary is inset by the full gap and an edge shared with another zone by half, so two neighbours end up one gap apart and the screen margin equals the gap. If a zone is too small for the gap, the inset shrinks so at least 40 pt remain. The overlay draws the gapped rectangle, so it previews exactly what you get. Picking always uses the real (ungapped) zone, so the gap is never a dead area under the pointer.

## Overlap and several zones

Zones may overlap (a small "picture-in-picture" zone over a big one is fine).

- **Which zone wins** when the pointer is over several: the **smallest** zone (by area); on a tie, the **most recently created** one. Creation order is stored per zone (`seq`), so it does not depend on the clock and survives duplicating a layout.
- **Hold ⌘ to span.** Zones mode remembers the zone that was chosen when ⌘ went down (or the first one chosen after it). While ⌘ stays down, the target becomes the **bounding rectangle** of that anchor zone and the zone under the pointer, and every zone that lies inside that rectangle is highlighted with it. The span only counts when the zones are contiguous (overlapping or sharing an edge; a shared corner alone does not connect them); if they are not, the zone under the pointer is used alone. Release ⌘ to go back to one zone; moving to another monitor clears the anchor. The gap is applied once to the bounding rectangle.
- A span is a plain target: the snapped window keeps no memory of which zones it covers.

## What gets moved

Cala moves other apps' windows through Accessibility (`AXPosition` and `AXSize`). It moves its own normal windows, including Settings, with AppKit's `NSWindow.setFrame` on the main thread. Both paths use the same zones and drag-out size memory.

Ignored windows:
- Cala's zone editor, utility panels and windows with an attached sheet.
- Full-screen windows.
- Sheets (`AXSheet`), system dialogs (`AXSystemDialog`) and windows with an unknown subrole. Ordinary app dialogs (`AXDialog`) are movable.
- Windows whose position cannot be set.
- Windows of macOS UI processes: Dock, SystemUIServer, Control Center, Notification Center, loginwindow, SecurityAgent, CoreServicesUIAgent, Spotlight, WindowManager (Stage Manager) and the screenshot UI. Normal system apps (Finder, Safari, Notes...) work like any other app.
- External windows with no Accessibility entry. The log reports `zones: ignoring drag ...`.

How the window is placed:
- **Resizable:** for external windows, set size, position and size again, then read back. Some apps clamp the first resize to the current monitor. For Cala windows, constrain the size to the window's limits and set the frame in one call.
- **Bigger than the zone** (the app has a minimum size): the window keeps its size, starts at the zone's top-left corner and is kept inside the usable area.
- **Smaller or rounded** (terminals snap to character cells): the size is accepted and the zone's corner kept.
- **Not resizable** (position only): centred in the zone, kept inside the usable area.
- Chromium and Electron apps animate and fight frame changes while `AXEnhancedUserInterface` is on, so Cala switches it off around the move and puts it back.

Ordinary snaps happen about 40 ms after the mouse is released, giving the app and the window server time to finish the drag. For an ordinary external window, Cala checks Accessibility eligibility after detecting movement, so a right-click can be swallowed before the eligibility check finishes. Drags are ignored while the zones editor is open and while the module is off.

## Layouts

A **layout** is a named set of zones. The first start with no `zones.json` creates one editable layout per template, named in the current interface language. Built-in names follow language changes until you rename the layout:

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

You can create as many layouts of your own as you like (the editor's **+**: a blank layout), duplicate one (the copy is named "… copy", numbered if that name is taken), rename it and delete it. The last remaining layout cannot be deleted. Templates are only starting points: after the first start they are ordinary layouts you can edit or delete. An edited built-in can get its original zones back (**Restore original zones** in its picture's context menu), and a deleted one can be added back from the **+** button (it becomes a menu while any built-in is missing).

Every layout is shown as a **picture of its zones at the monitor's shape** (an ultrawide gets flat pictures, a portrait screen tall ones) wherever you choose one: the editor's gallery, Settings → Zones and the menu-bar icon's layout menus. One renderer draws them all; the geometry (`ZoneThumbnails`: fit to the screen's aspect, inset, gap between neighbours, pixel alignment, larger zones painted first) is pure and checked.

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

`~/Library/Application Support/Cala/zones.json`. It is a separate file from `config.json` so that a damaged zones file can never cost you your bar settings, and nested arrays do not fit the flat per-field recovery `config.json` uses. Written atomically, pretty-printed with sorted keys, and only when something is committed (editor Save, a layout choice, duplicate, delete); each change is written before it goes live. The scalar preferences (`zonesEnabled`, `zonesActivation`, `zonesGap`, `zonesEditorGrid`, `zonesLayoutStrip`, `zonesStatusItem`) stay in `config.json`.

```json
{
  "activeByDisplay": { "793B322E-9748-43CF-8A63-BA18283C7D7F": "5C0E3774-32DE-4E02-8708-215EFC1C0137", "A1B233B6-438D-48FA-8D83-C9E73E5BBA68#2": "off" },
  "defaultLayout": "5C0E3774-32DE-4E02-8708-215EFC1C0137",
  "layouts": [
    {
      "id": "5C0E3774-32DE-4E02-8708-215EFC1C0137",
      "name": "Two columns",
      "nextSeq": 2,
      "template": "two-columns",
      "mode": "linked",
      "zones": [
        { "id": "DDC3C8D8-001C-4172-88D6-EF298BBAE8A6", "seq": 0, "rect": { "x": 0,   "y": 0, "w": 0.5, "h": 1 } },
        { "id": "06FC8D22-8BEA-4E42-AF8C-7B8D5722B2C2", "seq": 1, "rect": { "x": 0.5, "y": 0, "w": 0.5, "h": 1 } }
      ]
    }
  ],
  "version": 1
}
```

- `activeByDisplay`: monitor key → layout id, or `"off"`. A monitor with no entry uses `defaultLayout`.
- `seq`/`nextSeq`: creation order, used only to break ties between equal-size overlapping zones. `template` identifies the originating template used for localized names and restoring original geometry. The optional `isNameCustomized` records whether to keep the user’s name across language changes.
- `mode`: how the editor edits the layout, `"linked"` (Tiles in the editor: the zones tile the usable area) or `"free"` (Free). A file without it (older versions) or with an unknown value gets it inferred from the zones: Tiles when they tile the screen (no overlaps, no holes), Free otherwise. A Tiles layout that no longer tiles (edited by hand) is repaired to Free.
- The module loads the file at startup. With Zones off, Settings → Zones reads without saving when opened. Changing a layout there or opening the editor can open a writable store. The developer snapshot also reads without saving.
- **Repair on load:** rectangles that are not finite numbers are dropped; the rest are clamped into the screen with a minimum size of 5 %; duplicate layout or zone IDs keep the first entry. Missing or null IDs get deterministic UUIDs that avoid collisions with explicit IDs. A malformed explicit UUID causes a decode failure. Assignments pointing at a missing layout are removed, valid assignment UUIDs are normalized, `"off"` is kept, empty layout lists are reseeded and a missing default becomes the first layout.
- **Damaged file:** if it cannot be decoded it is moved to the first free backup path (`zones.json.bad`, then `zones.json.bad.1`, `zones.json.bad.2`, and so on). Existing entries, including dangling symlinks, are preserved. Cala then writes freshly seeded templates. If the backup move itself fails, the store keeps the original file, exposes seeded templates in memory and refuses saves. If `zones.json` cannot be loaded at all, the module logs `zones: could not load zones.json` and does not start.
- The uninstaller deletes the whole support folder, so it needs no special case.

## Monitors

- **Identity.** A monitor is keyed by its CoreGraphics display UUID (the same key `alignments` uses in `config.json`), or the numeric display id if macOS gives no UUID. **Identical monitors** that report the same UUID get a `#2`, `#3`... suffix, ordered by position left to right then top to bottom. That order is stable only while the arrangement does not change (known limitation).
- **Names.** A monitor is shown by its own name when that name is unique. Monitors that share a name (two identical models, or several reported as "(AirPlay)", which macOS only numbers "(1)", "(2)") or have none are named by position instead: **Left / Middle / Right display**, **Top / Bottom display**, else **Display N**; the size in points is shown next to it (`ZoneMonitorNames`, checked). The same names are used in Settings, the menu-bar icon and the editor.
- **Per-monitor choice.** Each monitor has its own active layout, or **Off** (no overlay and no snapping there). Choose it from the menu-bar icon (*monitor*: *current layout* → a menu of pictured layouts, "Off on this display" and "Edit zones on this display…"), from Settings → Zones → Layout per display (one compact row per monitor: its current layout pictured at its shape, name and size, **Change layout…** opening, below the row, an anchored gallery with every layout as a picture plus **Off** (names on up to two lines), and **Edit Zones…** for that monitor), or by clicking a layout in the editor's gallery.
- **Disconnect.** The assignment stays in the file, like icon alignment. If zones mode is active and its monitor goes away, zones mode is cancelled and the window stays; any other screen change rebuilds the overlay in place.
- **Connect.** A known monitor gets its stored layout; an unknown one gets the default layout (nothing is written until you choose).
- Mirrored displays are one screen with one key. A Space change does not cancel zones mode (it fires whenever the pointer carries a window onto another monitor, and an edge push to a neighbouring Space carries the window along): the overlay panels join every Space, are brought back to the front, and the target is recomputed from the pointer.

## Editor

Open it from the menu-bar icon (**Zones editor…**, on the monitor under the pointer, or **Edit zones on this display…** in a monitor's layout menu) or **Edit zones…** at the top of Settings → Zones. With several monitors, each display row also has its own editor button. It works even with the Zones module off: it loads `zones.json` on its own and a Save writes the file, which the module reads when it starts. With the module on, a Save is live at once.

It is a borderless window that covers the chosen monitor, above everything including the bar. The working area (the usable rectangle) is drawn on a dimmed screen, so what is outside it (menu bar, Dock, Cala's bar strip) is visibly excluded. It takes the first click even when Cala was not active, so the click that brings it forward already draws, grabs or presses a button.

There is one concept, the **layout**, and one panel at the top in three bands (collapsible to a small pill that keeps **Save**):
- **Which layout:** its **name**, editable in place (click it; Return goes back to the canvas); on the right, the **Monitor** picker, a **…** menu with the quieter commands (Rename, Duplicate Layout, Restore Original Zones for an edited built-in, Delete Layout… with confirmation and staged until Save, Undo **⌘Z**, Redo **⇧⌘Z**, Snap to a 12 × 12 Grid), **?** (an anchored help panel with every mouse and keyboard shortcut in one grid, by mode) and the collapse chevron. The Monitor picker shows only with more than one monitor ("Left display — 3840 × 1080").
- Zone numbers and sizes are centred in the part of each zone the panel does not cover, so the panel never hides them.
- **Gallery:** every layout as a picture at this monitor's shape, the one on the canvas ringed and scrolled to the middle; soft edges show when more pictures are out of sight, and a thin line separates them from **+**. **Clicking a picture shows that layout on the canvas and makes it the one this monitor uses** (on Save); there is no separate layout picker or "use on this monitor" step. **+** (always visible at the start) adds a layout and puts the cursor in its name; while a built-in layout is missing it is a menu that can also add it back. Each picture's context menu: Rename, Duplicate, Restore original zones (edited built-ins), Delete.
- **How to edit it, and finishing:** the layout type (**Tiles | Free**, in Spanish **Mosaico | Libre**) with a one-line summary ("Zones cover the screen without overlapping." / "Place zones anywhere; they can overlap.") and a one-line hint for what to do next (everything else is in **?**); **Add Zone** in Free; then **Cancel** (reads **Close** when nothing changed) and **Save**, the largest button at the bottom right, filled with the system accent colour (a shade darker, so its white text keeps at least 4.5:1 contrast in light and dark). Short notes (why something did not happen) replace the hint for a few seconds. If zones are off on this monitor, the ring is dashed and "Off on this monitor" (⊘) shows next to the buttons.
- **Selection bar:** the selected zone's actions float at the bottom of the selection on the canvas (just below it when the zone is short), so nothing depends on knowing about right-click. Tiles: **Split** (⇧ the other way), **Size…**, **…** (split left/right or top/bottom, Equal Widths, Equal Heights), **Delete**. Free: **Size…**, **Duplicate**, **…** (Center Horizontally/Vertically, Equal Widths/Heights), **Delete**. **Delete** is red only when it can act; disabled it is grey and its tooltip says why. With two or more zones selected: **Merge** (and "not a rectangle" when they cannot be merged) and **Deselect**. Right-click a zone offers the same actions. The bar hides while dragging.

**Two types, one per layout** (after FancyZones' Grid and Canvas editors). The stored value is `linked` for Tiles and `free` for Free.
- Every built-in layout, and any layout whose zones tile the screen, opens as **Tiles**; a layout with overlaps or holes opens as **Free**. A new layout (**+**) starts as Tiles with one zone covering the screen.
- Tiles → Free is instant. Free → Tiles only when the zones already tile the screen; otherwise a message explains that they overlap or leave gaps and how to fix it (make them meet edge to edge in Free, snapping helps, or start a new layout). There is no automatic "snap to tiles": it would move zones unpredictably.
- Each split, merge, divider drag, swap, delete and type change is one undo step.

**Tiles** (the zones always tile the usable area: no overlaps, no holes; `ZoneTiling`, checked):
- **Select** a zone by clicking it. **Split:** with a zone selected, the pointer over it shows a dashed cut and "Click to split · ⇧ turns the cut" (the tip flips sides near the screen edge and always stays on screen); clicking splits it there. The cut follows the zone's longer side on screen (⇧ the other way) and snaps to the zone's middle, the grid and other zones' edges. So: first click selects, a click on the selected zone splits; a drag never splits. **Split** in the selection bar (and its **…** or right-click → Split into Left and Right / Top and Bottom) cuts the selected zone at its middle along its longer side (⇧-click the button for the other way). Parts are never smaller than the minimum.
- **Dividers:** drag an edge shared with other zones. Every edge at the same position that is joined to it through overlapping spans moves with it (three columns: the divider resizes both; 2 × 2 grid: only the dragged row; a tall zone next to two stacked ones: the whole divider), stopping where a zone involved would get smaller than the minimum. Edges on the screen's border are not dividers.
- **Merge:** ⇧-click zones to select two or more, then **Merge** in the selection bar (or right-click → Merge Selected Zones). Enabled only when together they make a rectangle; the tooltip says why otherwise.
- **Delete zone** gives the zone's space to a neighbour that shares a whole side with it (the smallest such neighbour). If none does, it is disabled and a note explains (merge or split first).
- **Swap:** drag a zone onto another and drop it: they trade places (a closed hand while dragging). Zones do not move otherwise: dropping on nothing changes nothing and, once per session, a note says "In Tiles, zones resize with the lines between them. Drop a zone on another to swap them, or switch to Free to place zones anywhere."
- Exact size (**Size…**) moves the zone's right (else left) and bottom (else top) dividers, so neighbours give way; Equal Widths/Heights apply only when the result still tiles. Drawing, arrow-key nudges, centring and duplicating are Free-only.

**Free** (rectangles anywhere, overlaps allowed):
- **Add zone** puts a zone a third of the screen wide and half as tall in the middle of the largest empty space (shrunk to fit it); with no empty space, it is cascaded a twenty-fourth down and right from the newest zone. It is selected at once.
- **Draw:** drag on an empty area, or hold **⇧** to draw over existing zones. An empty layout says "Drag on the screen to draw a zone". ⇧-click (without dragging) adds a zone to the selection for Merge.
- **Move:** drag a zone. **Resize:** drag one of the selected zone's eight handles (corners and edge midpoints) or any zone's border. The cursor shows what a drag will do (crosshair, open hand, resize arrows).
- **Delete** or **Forward Delete** removes the selected zone; **⌘D** duplicates it. **Arrow keys** move it 8 pt, or a twelfth of the screen with **⇧**. Double-click a zone to type its exact size (it keeps its centre).
- **Right-click a zone** (or use the selection bar): Size…, Center Horizontally, Center Vertically, Merge Selected Zones, Equal Widths in This Row (zones with the same top and height share the row's width evenly, keeping its outer edges and gaps), Equal Heights in This Column, Duplicate, Delete.

**Both:**
- Zones cannot leave the screen, and cannot be smaller than the larger of 5 % of the usable size and 80 pt.
- **Sizes:** under each zone's number, its width × height in the monitor's points (the size macOS and Settings show for the monitor, e.g. a 3840 × 1080 display; edges are rounded first, so zones that share an edge add up exactly). It updates live while dragging, and a width or height equal to the selected zone's is shown in green, so two side zones are easy to make the same.
- **Snapping:** within 8 pt, an edge snaps to another zone's edges, the screen's edges and its centre line (½); with **Grid** on, also to the twelfths of a 12 × 12 grid. A moved zone's **centre** snaps to the screen's centre on either axis (dash-dotted guide). A resized or drawn zone snaps to the **same width or height as another zone** (green guide, and the matching size turns green). Active snap lines show as dashed guides. Hold **⌥ (Option)** to turn snapping off while dragging. The grid choice is remembered (`zonesEditorGrid`).
- Overlapping zones use the same "smallest wins" rule to decide which one you grab.

Edits happen on a draft. **Save** (button, **⌘S** or **Return**) writes everything in one atomic write. **Cancel**, **Esc** or closing the window asks "Discard changes to zones?" only if something changed. Saving merges the draft into the live state, so a layout changed elsewhere while you were editing is not overwritten. **Drags are ignored the whole time the editor is open**, so a window dragged at that moment never triggers zones.

`Cala --snapshot <dir>` also renders the editor (`zones-editor-en.png`, `zones-editor-es.png`) offscreen, without starting any module.

## Settings keys

All in `config.json`; full reference in [configuration.md](configuration.md#modules-and-zones).

| Key | Default | Meaning |
|---|---|---|
| `zonesEnabled` | `false` | The Zones module is on |
| `zonesActivation` | `"both"` | `rightClick`, `shift` or `both`. Anything else becomes `both` |
| `zonesGap` | `8` | Space around snapped windows, 0 to 40 pt (clamped) |
| `zonesEditorGrid` | `false` | The editor's 12-division snapping |
| `zonesLayoutStrip` | `true` | Show the layout strip during a zones drag ([above](#using-it)) |
| `zonesStatusItem` | `true` | Show Cala's icon in the menu bar (**Show the icon in the menu bar** in Settings → Zones). Only with the taskbar on; without it the icon always shows |

Settings → **Zones** shows the module switch, its status and an **Enable Zones** action when off, followed by **Edit zones…**, one layout picker per display, the gesture picker, gap slider, layout strip switch, and macOS tiling help. Layout choices and the editor are available while Zones is off.

## Permissions

**Accessibility only.** It is needed to move and resize windows, and an *active* event tap (one that can swallow an event) is only granted to an Accessibility-trusted process. This was measured in the prototype: without it, creating an active tap is refused for both mouse and keyboard masks.

Not needed:
- **Input Monitoring.** The tap listens to mouse buttons only (left down, up and dragged; right down and up) and never sees keystrokes. Shift and ⌘ are read from the flags every mouse event already carries.
- **Screen Recording.** Zones never captures anything.

When you use Zones on its own, Accessibility is the only permission it needs. The welcome and the Zones page explain why and offer a button to grant access. Without it the module still starts (menu-bar icon, layouts and the editor work) and waits: every 3 seconds, and sooner when macOS announces an Accessibility change, it tries to install the tap, so zones come alive the moment you grant it, with no restart. Revoking Accessibility removes the tap.

## Threads and cost

An active event tap sits in the path of **every** mouse click on the Mac, so the design keeps it harmless:

| Thread | Owns | Rules |
|---|---|---|
| Tap thread (`Cala.zones.tap`, own run loop) | The `CGEventTap` and its callback | O(1): updates a small state machine under an unfair lock and hands off with `async`. No Accessibility, no `CGWindowList`, no logging or file I/O. A stall in Cala's UI can never delay system mouse input |
| Worker (`Cala.zones.worker`, serial queue) | Window-list probes, candidate selection, Accessibility calls and snap records | Coalesced move checks by window ID. Full rechecks are reserved for possible tab drags. The Accessibility messaging timeout is 0.25 s. Press generations discard stale results |
| Main | Overlay panels, the store, the editor, the status menu, session start and end, AppKit window eligibility and placement | Eligibility checks, coalesced overlay updates and the layout strip dwell timer can run during AppKit's event-tracking loop |

If macOS disables the tap (timeout or user input) it is re-enabled at once, the current gesture is cancelled and the overlay is hidden (also when the periodic check, not the callback, finds the tap disabled), so a missed mouse-up cannot leave zones mode or a click-through overlay stuck; the mouse-up of an already confirmed drag is still reported, so a drag-out size restore finishes; the periodic check also rebuilds a dead tap. When the module stops, the tap is disabled and invalidated, its thread ends, the worker's queued work is cancelled, snap records are dropped and every overlay panel is closed and released.

## Drag-gesture prototype and the right-click verification

Before building the module a spike ([`scripts/prototypes/drag-tap/`](../scripts/prototypes/drag-tap/README.md), commit `d9b42bc`) measured what could be measured on a development Mac:

- **Measured:** an active (`.defaultTap`) session tap is refused (`nil`) without Accessibility, for mouse and keyboard masks; a listen-only tap is created without any permission (but macOS withholds keystrokes from listen taps without Input Monitoring, which is why Zones does not rely on keys). `CGWindowList` queries cost about 0.1 to 0.3 ms (median) with spikes near 9 ms; an Accessibility hit-test is about 0.3 ms with a 28 ms spike. That is why neither runs inside the tap callback.
- **Verified by the owner on 2026-11-24**, live on the real app: a right-click **swallowed in the middle** of a window drag keeps the drag alive (the window goes on following the pointer), the left-button-up arrives normally, no context menu appears, and the layout strip works in the same gesture. The spike could not measure this itself (it ran in a background Fast User Switching session that receives no input).

Consequence: **right-click is a clean primary gesture.** The default activation stays `both` (right-click, or hold Shift, which needs no swallowing).

## Known limitations

- **A trackpad drag can use Shift.** For a drag that fails to activate either gesture, inspect `zones:` entries in the debug log.
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

**0. The integrated feature in the real app** (covers the mouse and trackpad workflows).
- [ ] Build: `./build.sh` (produces `build/Cala.app`), or `./install.sh` to use the shared `/Applications/Cala.app` (preferred: grants are tied to the path, see [setup.md](setup.md)). Run it from the **console** session.
- [ ] System Settings → Privacy & Security → **Accessibility** → add and enable that Cala (no Screen Recording or Input Monitoring needed for Zones alone). Cala notices without a restart; the debug log shows `zones: event tap active (mouse only, mask 0x5e)`.
- [ ] Settings → General → What Cala does → turn **Zones** on. Settings → Zones shows one layout picker per monitor (default: Two columns).
- [ ] Gestures: drag a window, right-click (zones appear, no context menu, window keeps following), right-click again (hide), hold Shift (show while held), **⌘** over two adjacent zones (combined rectangle), release over a zone (snap with the gap), release outside (window stays), second right-click then release (window stays).
- [ ] Drag the snapped window out: its old size returns. Change *Activate zones with* to **Right-click** and to **Hold Shift** and check that the other gesture stops working.
- [ ] Editor: menu-bar icon → **Zones editor…** or Settings → Zones → Edit zones…; draw, move, resize, guides, grid, Save; the new layout works immediately without restarting.
- [ ] Welcome and migration **without touching your real settings**. Cala's data folder does not depend on the bundle id, so a separate id alone is not enough; also redirect the home folder:
  ```bash
  CALA_BUNDLE_ID=local.cala.dev ./build.sh            # own defaults domain and own Accessibility identity
  # Quit your real Cala first (Settings → Help and diagnostics → Advanced options → Quit Cala → Quit…). Never run both at once.
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

**1. Right-click gesture** (passed by the owner on 2026-11-24; repeat after changes to the tap). Settings → Zones → *Activate zones with* → **Right-click**.
- [ ] Drag a Finder or TextEdit window by its title bar, right-click mid-drag: the zones appear, **no context menu**, and the window **keeps following the pointer**.
- [ ] Right-click again: zones hide, window still follows. Right-click once more and release over a zone: the window snaps.
- [ ] Same with a Chrome or other Electron window dragged by its tab strip.
- [ ] Drag Cala's Settings by its title bar, right-click and drop it into a zone. Drag it out again to check size restore.
- [ ] During a drag of Cala's Settings, open the layout strip and hold the pointer still on another layout until it switches. Drop in a zone from the new layout.
- [ ] In Chrome and in Brave (or another Chromium browser), pull one tab out of a window with multiple tabs. Once the detached window follows the pointer, right-click and drop it into a zone. The detached window snaps and the source window stays in place.
- [ ] Release the button while zones are showing, over empty space: the window stays, and the next click behaves normally (the left-up was not lost).
- If any of these ever fail: set *Activate zones with* to **Hold Shift** and report it.
- Optional isolated probe, with the same checks and its own log: see [scripts/prototypes/drag-tap/README.md](../scripts/prototypes/drag-tap/README.md).

**2. Things that must not trigger zones** (right-click must still open the app's context menu):
- [ ] Select text in TextEdit with the button held and right-click.
- [ ] Select text in the body of a Chrome page or drag a control there and right-click while holding the left button.
- [ ] With a sheet attached to Cala's Settings, try moving Settings and right-clicking during the drag. The click reaches AppKit and the overlay stays hidden.
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
- [ ] Click each picture in the gallery: the canvas shows it at once and, after Save, the monitor uses it.
- [ ] Draw on empty space, ⇧-draw over a zone, Add zone; move, resize from all eight handles; zones cannot leave the screen; ⌥ disables snapping; dashed guides show; the grid toggle works and is remembered.
- [ ] Tiles (a built-in): click a zone, click it again to split at the dashed line (⇧ turns it); Split button; drag a divider, the neighbour shrinks; ⇧-click two zones and Merge (disabled when they do not make a rectangle); Delete gives the space to a neighbour; drop a zone on another, they swap; dragging a zone onto nothing shows the note once. Free: Add zone lands in the largest gap; zones overlap; Free → Tiles refuses with a message while zones overlap.
- [ ] Sizes show under the numbers and equal ones turn green; centre snap, Size… (double-click), Equal Widths, arrows and ⌘Z / ⇧⌘Z work.
- [ ] + (blank layout, name ready to type), duplicate, rename in place, delete with confirmation (the last one cannot be deleted); delete a built-in and add it back from +; edit a built-in and restore its original zones.
- [ ] Settings → Zones and the menu-bar icon show the layouts as pictures per monitor, and two monitors with the same name read as Left / Right display.
- [ ] Cancel with changes asks to discard; Save keeps them; dragging a window while the editor is open does nothing.
- [ ] With Zones off, the editor still opens from the menu-bar icon and its Save is used when Zones is turned on.

**7. Modules and permissions**
- [ ] Zones only (Bar off): no bar, no reserved space, the Dock and menu bar are as macOS has them; the menu-bar icon offers Settings…, Zones editor…, one layout menu per monitor and Quit.
- [ ] Turn Zones off (Bar on): the menu-bar icon disappears, `debug.log` shows `modules: apply ...` and no `zones:` lines afterwards, and clicks and right-clicks behave exactly as before.
- [ ] Revoke Accessibility while Zones runs, then grant it again: zones stop and then come back without restarting Cala.
