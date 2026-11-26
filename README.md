<div align="center">

<img src="branding/logo.svg" width="96" alt="Cala">

# Cala

**A taskbar for your Mac.** Your apps at the bottom with up to six window previews per app, and on the right Wi‑Fi, sound, battery, disk, calendar and a panel that tells you why your Mac is slow.

**Cala is a set of modules you switch on separately:** the bar and its tray, the Option+Tab window switcher, and **Zones**, which snaps the windows you drag into layouts. Zones and the switcher can run without the bar. The tray requires the bar.

Free · Source available · No Cala account required · macOS 14 or later · Apple silicon and Intel

### [⬇︎ Download the latest version](https://github.com/MineiToshio/cala-taskbar/releases/latest)

**English** · [Español](README.es.md)

<img src="docs/images/bar.jpg" alt="The Cala bar" width="100%">

</div>

---

## What it does

<table>
<tr>
<td width="50%" valign="top">

**Your apps, at the bottom.** Click to switch apps, hover to see window previews, right-click to pin, open a new window or quit.

**Option + Tab** shows up to 20 windows, including minimized ones. Type to search them. Outside search, press W to close one, Q to quit its app, or M to minimize or restore it.

**The tray on the right** has Wi‑Fi, Bluetooth, sound, brightness, battery, disk, keyboard, Downloads, Trash, and a clock with your upcoming events and a button to join the video call.

**Your mail, in the tray.** An envelope with the unread count of your Gmail, iCloud or Yahoo accounts; read, archive or delete without opening a browser. See [Mail](#mail).

**Why is my Mac slow?** The CPU and memory panel tells you which app weighs the most and recommends a restart when it is worth it.

**Zones.** Drag a window, right-click or hold Shift, and drop it into a zone: halves, thirds, a grid or a layout you draw, with a different layout on each monitor. It works with or without the bar. See [Zones](#zones).

</td>
<td width="50%" valign="top">
<img src="docs/images/system-panel.jpg" alt="System panel" width="100%">
</td>
</tr>
</table>

---

## Install

### Option 1: one command (recommended, no macOS warnings)

Open **Terminal** (find it with Spotlight: ⌘ + Space, "Terminal"), paste this line and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/MineiToshio/cala-taskbar/main/scripts/get-cala.sh | bash
```

It downloads the latest version, checks that the file is the one published here (SHA-256), installs Cala in `/Applications` when writable (otherwise in `~/Applications`) and opens it. Because it does not go through the browser, macOS does not block it. It also **updates** Cala, and your settings are kept. You can [read the script](scripts/get-cala.sh) before running it. Then follow Cala's welcome window.

### Option 2: download the file

1. **Download** `Cala-x.y.z.dmg` from [Releases](https://github.com/MineiToshio/cala-taskbar/releases/latest).
2. **Open it** and drag **Cala** to the **Applications** folder.
3. **Open it the first time.** Cala is free and not signed by Apple (that costs 99 USD a year), so macOS blocks it **once**:

   **macOS 15 (Sequoia) or later**
   1. Double-click **Cala** in Applications. You see *"Apple could not verify…"*: press **Done**.
   2. Open **System Settings → Privacy & Security** and scroll to the bottom.
   3. Next to *"Cala was blocked"*, press **Open Anyway** and enter your password.
   4. Open Cala again and choose **Open Anyway**.

   **macOS 14 (Sonoma)**: in Applications, right-click **Cala → Open**, then **Open** again.

   After that, Cala opens normally for good. (Option 1 skips this step.)

4. **Follow the welcome.** A few short steps. It first asks **what you want to use** (the bar, Zones or both) and then asks only for the permissions that choice needs.

<details>
<summary>Prefer Terminal? One command does the same as step 3</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Cala.app
```
</details>

> **Is it safe?** All the code is in this repository: you can read it and build it yourself (see [Build from source](#build-from-source)). The macOS warning only means the app did not go through Apple's paid program, not that something is wrong with it.

---

## Mail

Click the envelope in the tray to see the latest emails in your inbox, with filter chips when you have two or more accounts. Open one to read it inside Cala with its real formatting, then **Archive**, **Delete** or **Open in Gmail / iCloud Mail / Yahoo Mail**. Opening an email in Cala marks it as read on the server, and new mail arrives in real time.

**Providers:** Gmail (also Google Workspace, if your company admin allows IMAP and app passwords), iCloud and Yahoo. Outlook and Hotmail are not supported: Microsoft requires an OAuth sign-in.

**Connect an account:** *Settings → Integrations → Mail* guides you step by step, with buttons to the right pages of your provider. Cala signs in with an **app password**: a code your provider generates just for Cala. It is **not** your normal email password. Gmail needs 2-Step Verification turned on to create one.

**Images:** remote images in emails load by default. Turn that off in *Settings → Integrations → Mail* if you prefer to block them: when images load, the sender can tell you opened the email. No JavaScript runs in emails, and links open in your browser.

---

## Zones

Zones lets you place windows without resizing them by hand. Turn it on in the welcome or in *Settings → Zones*.

1. **Drag a window** by its title bar.
2. **While you hold the button, right-click** (or **hold Shift**). Your zones appear on that monitor.
3. **Move over a zone and release.** The window takes its position and size.

To use another layout, move over the **Change layout** pill at the top of the screen while the zones show and rest on the one you want. Hold **⌘** to cover several neighbouring zones at once. Right-click again, release Shift, or release outside every zone to cancel: the window stays where you dropped it. Drag a snapped window out and it gets its old size back.

- **Layouts:** eight templates and as many custom layouts as you like. Open *Settings → Zones → Edit zones…* or the Cala menu-bar icon. In **Tiles**, split and merge zones or drag their shared edges. In **Free**, draw, move and resize zones with snap guides and an optional 12-division grid. Choose a layout or **Off** for each display.
- **Without the bar:** turn the bar off in *Settings → General* and Cala lives in the menu bar, with no taskbar and no reserved space. The Dock and menu bar stay as macOS has them.
- **With the bar:** zones never go under the bar when it is always visible.
- **Permission:** only **Accessibility**. Zones never records the screen or reads the keyboard.
- **macOS 15 and later** can also tile a window dropped near a screen edge. If that gets in the way, turn off *Drag windows to screen edges to tile* in *System Settings → Desktop & Dock → Windows* (*Settings → Zones* has a button).
- On a trackpad you can’t right-click while holding a drag. Hold **Shift** while dragging. In *Settings → Zones → Activate zones with*, choose **Hold Shift** or leave **Either gesture** selected (the default).

More in [docs/zones.md](docs/zones.md).

---

## Permissions

<img src="docs/images/permissions.jpg" alt="Permissions in the welcome window" width="380" align="right">

Cala asks for each permission with a sentence on what it is for and a button that opens the exact pane of **System Settings**. Cala detects Accessibility changes live. For Screen Recording, follow any macOS prompt to quit and reopen.

| Permission | What for | If you skip it |
|---|---|---|
| **Accessibility** | See, focus, minimize and close windows; Option+Tab; move windows into zones | The bar still opens your apps, without managing windows; Zones cannot move windows |
| **Screen Recording** | Window thumbnails | No thumbnails. Cala never records or sends your screen |
| Calendar | Upcoming events and the Join button | The clock shows no events |
| Location | macOS only reveals Wi‑Fi network names with this permission | No network names |
| Bluetooth | See and connect your devices | They are not listed |
| Control Finder | Count and empty the Trash, restart | Those actions are unavailable |
| Notifications | Claude or Codex quota alerts | No alerts |

For **Accessibility** and **Screen Recording**, macOS opens a list: turn on **Cala** (it asks for Touch ID or your password). If macOS offers **Quit & Reopen** after Screen Recording, accept it.

Only the permissions of the modules you use are requested: **Zones alone needs just Accessibility**. Said no to something? Everything else keeps working. Turn it on whenever you like in **Settings → Permissions** (right-click an empty part of the bar → Settings…, or the Cala icon in the menu bar).

<br clear="right">

### The Keychain prompt (Mail)

Once, after the update that brings Cala's Keychain helper, macOS may show **up to two windows** for each mail account saved by an earlier version: *"cala-keychain wants to access key "Cala Mail" in your keychain."* (buttons *Always Allow*, *Deny*, *Allow*) and one asking *"To allow this, enter the "login" keychain password."*, which is your **Mac password**. Choose **Always Allow** in both. That password goes to macOS only: Cala never sees it. Cala is free and not signed with a paid Apple Developer ID, so macOS trusts a program by its exact fingerprint. Only the small helper `cala-keychain` inside Cala.app touches the Keychain, and it stays identical across updates. After reading an old entry it copies the password into its own entry (same "Cala Mail" service, account `v2:<your email>`), which macOS trusts without asking, so later launches and updates do not ask again. Accounts you add afterwards go straight into the helper's entry. Only an update that has to replace the helper (rare) asks once more.

The old entry (account = your email, without `v2:`) is left in place, because macOS does not let the helper delete it. You can delete it yourself in **Keychain Access** (search "Cala Mail") once the `v2:` entry exists, and also after removing an account in Cala. If the windows keep coming back on every launch, open that old entry in Keychain Access → **Access Control** → **+** and add `/Applications/Cala.app/Contents/Helpers/cala-keychain` (⌘⇧G to type the path), then **Save Changes**.

---

## Everyday use

- **Settings**: right-click an empty part of the bar → *Settings…*, or click the Cala icon in the menu bar (shown when the bar is off or Zones is on), or open Cala again from Applications.
- **Modules**: *Settings → General → What Cala does* shows switches, status and direct links for Zones, Taskbar, Window switcher and Tray. The same pages stay available when modules are off and offer an **Enable** action. Open **Integrations** for Mail, Calendar and Claude & Codex.
- **Tray:** drag a handle within or between **In the bar**, **In More** and **Hidden** to set order and placement. Drop at the top of a group or into an empty one. The rows for CPU and memory, Disk, Mail and Claude & Codex open a detail with a back button when you click their chevron or anywhere outside the handle.
- **Open at login**: chosen in the welcome or in *Settings → General*. It shows up in *System Settings → General → Login Items*.
- **Language**: English or Spanish, following your Mac by default. Change it in *Settings → General → Language*.
- **Taskbar**: *Settings → Taskbar* holds Dock and menu bar hiding, icon size, transparency, previews and alignment per display. To change the shared theme, open *General → Cala theme*.
- **Window switcher**: *Settings → Window switcher* shows whether Option + Tab is ready, including when thumbnails are unavailable, plus the Command + Tab option and search instructions.
- **Update**: run the Option 1 command again, or download the new DMG and replace Cala in Applications. Each account keeps its own settings. Accounts using `/Applications/Cala.app` share the installed copy. Other sessions already running that copy relaunch into a newer build when active and free of blockers such as an open Settings window or an ongoing drag.

## Uninstall

*Settings → Help and diagnostics → Advanced options → **Uninstall Cala → Uninstall…*** puts the Dock and menu bar back as they were, removes the login item, deletes Cala's settings and tries to move the app to the Trash. Removing the shared copy affects all accounts.

Permissions stay listed in *System Settings → Privacy & Security*; you can remove them there. Without opening the app: [`scripts/uninstall.sh`](scripts/uninstall.sh).

## Privacy

Cala’s window and layout features run locally. Connected integrations use your existing accounts. Claude and Codex usage can query their providers, and Mail connects to the provider’s IMAP server and can load remote images. *Report a problem* previews the message, optional contact email and any text attachments. Cala redacts your home folder, user name, Mac name and email addresses from technical text. When sending through Cala, the report also includes structured context such as macOS version, Mac model and permission status. If the version you downloaded has no reporting destination set up, you can **copy the report** and paste it in an [issue](https://github.com/MineiToshio/cala-taskbar/issues).

**Mail:** app passwords are stored in the macOS Keychain (service "Cala Mail"), and the content of your emails stays on your Mac. You can revoke access at any time by deleting the app password in your Google, Apple or Yahoo account.

## Troubleshooting

- **"Cala can't be opened" / "Apple could not verify…"**: that is the one-time block; see step 3 of [Install](#install), or install with the Option 1 command, which avoids it.
- **No thumbnails**: turn on Screen Recording in *Settings → Permissions*.
- **Zones does nothing**: it needs Accessibility (*Settings → Permissions*); it starts by itself once you allow it. Check that Zones is on in *Settings → General → What Cala does*.
- **The Dock disappeared**: Cala only hides it if you asked. Turn off **Hide the macOS Dock** in *Settings → Taskbar*.
- **macOS says "cala-keychain wants to access key "Cala Mail" in your keychain."**: it is expected once, up to two windows per account; see [The Keychain prompt](#the-keychain-prompt-mail). Choose **Always Allow** in both (type your Mac password if asked); it goes to macOS, not to Cala. If it asks on every launch, use the manual fix in that section.
- **Mail says "Restart Cala to refresh its Keychain access."**: Cala was updated or replaced while it kept running. Quit Cala and open it again. **"macOS couldn't confirm that the Keychain request came from Cala"** (Developer ID builds only): restart your Mac; if it keeps happening, reinstall Cala.
- **Something is wrong**: open *Settings → Help and diagnostics → Report a problem → Report…*, use **Report a Problem…** in the bar’s right-click menu, or open an [issue](https://github.com/MineiToshio/cala-taskbar/issues).

## Build from source

You need the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/MineiToshio/cala-taskbar.git && cd cala-taskbar
./install.sh            # builds, installs to /Applications for all accounts and opens Cala
```

`./build.sh` and `./scripts/make-dmg.sh` produce the universal `.app` and the DMG. More in [docs/](docs/README.md) and, for publishing versions, [docs/release.md](docs/release.md).

---

License: [PolyForm Noncommercial 1.0.0](LICENSE). Cala is free to download, use and modify for personal and other noncommercial purposes. Selling it or using its code commercially requires the author's permission.
