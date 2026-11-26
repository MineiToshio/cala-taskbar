# In-app updates: design (v1)

Status: design, not implemented. Decided:
- The repository is public.
- The installed bundle belongs to the user (group `admin`, group-writable). Cala never asks for elevated privileges.
- The release key is an encrypted file on the maintainer's Mac.
- Cala checks for updates by default. Installing on its own is off by default.

The design below was red-teamed. Each finding is answered where it applies, with a code reference.

Goal: about once a day Cala checks GitHub for a newer release and shows its version and notes. One click downloads it, verifies it, replaces `/Applications/Cala.app` and relaunches. No browser and no password are involved. A discreet indicator leads straight to the install. Nothing is touched until the download has passed verification. If the update fails at any step, or the new build crashes at launch, the previous Cala ends up installed and running.

## 1. Why a custom updater, not Sparkle 2

Sparkle would have to be embedded by hand in the bundle that `build.sh` assembles. That means a framework, XPC services and `Autoupdate`, each re-signed inside-out ([docs](https://www.sparkle-project.org/documentation/sandboxing)). With ad-hoc signing and the hardened runtime, library validation can refuse the framework ([docs](https://sparkle-project.org/documentation/)), which would force `disable-library-validation` on every build. Its UI would bypass `tx()`, the bar indicator and Cala's "don't restart mid-task" blockers. It also can't be tested by the `Checks/*` scripts.

Now that installs need no privileges, the custom version is small. It verifies one Ed25519 signature over exact bytes, checks a SHA-256, compares versions, and swaps directories atomically with `renameatx_np`. Sparkle's main extras, delta updates and appcast tooling, are not needed for a DMG of a few MB.

## 2. Ownership and who can update (no privilege escalation)

- `install.sh` publishes the bundle as `<installing user>:admin` with mode `u+rwX,g+rwX,o-w`, i.e. 775/664. Before this change it was `root:admin` 755 (`install.sh:44-46`).
  - `install.sh` keeps using `sudo` for its publish step. Moving an existing root-owned `Cala.app` into a staging folder needs write access to that directory (for `..`), and so does deleting the old root-owned tree. A user can do neither.
  - From the second install on, everything is group-writable.
- `/Applications` is `root:admin` 775 with no sticky bit (verified with `ls -ld`). So any admin account can rename entries in it, and with group write on the bundle any admin account's Cala can update the shared copy.
  - After every in-app install, the updater sets the new bundle to `<self>:admin`, `g+w`, `o-w`.
  - A DMG drag or `get-cala.sh` produces `<user>:admin` 755: new entries take the group of their parent folder. Updating such a copy works for its owner, and the update then adds `g+w`.
- **Install path** (`UpdateRules.installPath`, pure):
  - `.ready`: the bundle is in `/Applications` or `~/Applications`, not translocated, not running from the disk image (`AppLocation`, `Lifecycle.swift:107-121`). The user can write the bundle folder, its `Contents` and the parent folder (`access(W_OK)`).
  - `.needsAdmin`: anything else, for example a standard account or a copy owned by another user without group write. The UI says "Ask an administrator to install this update, or install it by hand" and links to the release page. Cala never escalates.
  - `.unsupported`: not in an Applications folder.
- **Other accounts.** When one account installs, another account's Cala that is still running sees a higher build on disk. The existing `BundleUpdateMonitor` relaunches it when its session becomes active (`BundleUpdateMonitor.swift:60-118`). This is unchanged.

## 3. Feed

- **URL:** `https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json`.
  - The `latest/download` link is documented for release assets ([GitHub](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)).
  - It only follows published releases, never drafts or prereleases ([GitHub](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)), so publishing the draft is the rollout.
  - It is not `api.github.com`, so the unauthenticated limit of 60 requests per hour ([GitHub](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)) should not apply. That is inferred, so Cala backs off anyway (§7).
- **`latest.json`:** at most 64 KB, with exactly two fields. No unsigned field changes behaviour (finding 5).

```json
{ "manifest": "<base64 of the manifest bytes>", "signature": "<base64 Ed25519 signature>" }
```

- **What is signed:** `"cala-update-manifest-v1\n" + manifestBytes`. Exact bytes mean no JSON canonicalization. The prefix separates this from any other use of the key.
- **Verification:** Cala tries each embedded public key, at most two (primary and recovery). Nothing in the manifest is read before the signature passes.

Manifest (signed):

```json
{
  "schema": 1, "bundleId": "local.cala", "version": "1.1.0", "build": 131,
  "minimumSystemVersion": "14.0", "publishedAt": "2026-12-01T10:00:00Z",
  "dmg": { "url": "https://github.com/MineiToshio/cala-taskbar/releases/download/v1.1.0/Cala-1.1.0.dmg",
           "size": 6123456, "sha256": "<64 hex>" },
  "app": { "unpackedSize": 21000000, "keychainHelperSHA256": "<64 hex>" },
  "notes": { "en": "…", "es": "…" },
  "notesURL": "https://github.com/MineiToshio/cala-taskbar/releases/tag/v1.1.0"
}
```

**Rules** (`UpdateRules.evaluate`, pure, each with a positive and a negative test):
- **Schema:** `schema != 1` → `.manualInstall`. The UI offers the release page, so an old updater never guesses at a newer format.
- **App identity:** `bundleId` must equal the running bundle's.
- **Which is newer (finding 10).** `CFBundleVersion` is the git commit count, and `install.sh:20-28` bumps it past whatever is installed. A developer's local builds therefore outrank releases by build number. So the comparison is:
  - the marketing version first (numeric `x.y.z`, the `VERSION` file and the tag);
  - the build only when the versions are equal.
  - It is offered only if it is newer than the running copy. Anything else is `.upToDate`, never an error.
- **Freshness:** Cala remembers the highest version it has seen and ignores a manifest below it. An attacker can still replay an older signed manifest that is newer than the running copy, or withhold the feed. That only delays updates, and is accepted.
- **Blocked or skipped:** a `version+build` in `blockedBuilds` (§6) is never offered or installed. `skippedVersion` hides the indicator and turns off auto-install for that version, but **Check for updates** still shows it.
- **macOS version:** `minimumSystemVersion` must be at or below the current macOS, otherwise `.needsNewerMacOS`.
- **URLs:** `dmg.url` must start with `https://github.com/MineiToshio/cala-taskbar/releases/download/`, and every redirect must stay on `https`. Test builds also allow `http://127.0.0.1:<port>/` (§4). Size and hash are signed, so the URL rule is hygiene, not integrity.
- **Limits:** `size` at most 200 MB, each note at most 8 KB. Notes render as plain text with inline Markdown only.
- **Feed errors (finding 1):**
  - HTTP 404, 401, or 403 without a rate-limit header → `.feedUnavailable` ("Update information isn't available right now"). It is not `.upToDate`: a missing, private or broken feed must be visible, not silent.
  - 429, or 403 with `Retry-After` or `X-RateLimit-Remaining: 0` → backoff.
  - A transport error → `.offline`.

## 4. Keys (finding 6)

**Key file.** The private key exists only in `~/.config/cala/update-signing-key.json` (folder 700, file 600) and in the maintainer's password manager. It never enters the repo or any build. The scheme uses Apple frameworks only:
- **Key:** Ed25519 (CryptoKit `Curve25519.Signing.PrivateKey`), stored as the 32-byte `rawRepresentation`.
- **Passphrase:** read from `/dev/tty` with `readpassphrase(3)` (no echo, never argv or env), at least 12 characters, typed twice when generating.
- **Key derivation:** PBKDF2-HMAC-SHA256 (CommonCrypto `CCKeyDerivationPBKDF`), 600,000 iterations, a random 16-byte salt (`SecRandomCopyBytes`), giving a 32-byte key.
- **Encryption:** AES-256-GCM (CryptoKit `AES.GCM.seal`) with a random 12-byte nonce. The AAD is the UTF-8 of `cala-update-key-v1|<iterations>|<salt b64>|<publicKey b64>`, so changing the header or the public key breaks decryption.
- **File format:**

  ```json
  {"format":"cala-update-key-v1","kdf":"pbkdf2-sha256","iterations":600000,"salt":"…","nonce":"…","ciphertext":"…","tag":"…","publicKey":"…"}
  ```

**Generating it (the maintainer runs this in their own Terminal; agents never do):**

```bash
swift scripts/update-sign.swift generate --out ~/.config/cala/update-signing-key.json
```

The command refuses to overwrite an existing file. It prints the public key and the line to add to `packaging/update-public-keys`, which is committed. It reminds the maintainer to save the file and its passphrase in the password manager. Optionally, the same command with `--out ~/Desktop/update-recovery-key.json` makes a recovery key: its public key is committed too, the file goes into the password manager, and the local copy is deleted. If the primary key is lost, the next release is signed with the recovery key and ships a new pair.

**Other subcommands of `scripts/update-sign.swift`:**

| Subcommand | What it does |
|---|---|
| `sign --key FILE --manifest M --out latest.json` | Asks for the passphrase interactively. `release.sh` calls it |
| `verify --keys packaging/update-public-keys --feed latest.json [--dmg D]` | Checks the signature, and the DMG's size and SHA-256 when given |
| `testkey DIR` | Writes an *unencrypted* throwaway pair marked `"format":"cala-update-testkey-v1"`, for E2E only. It is deleted after the run, and `release.sh` cannot use it: verification against the committed keys fails |
| `selftest` | Round-trips with an in-memory key, rejects a flipped byte, a wrong passphrase and a changed AAD |

**Embedding the public keys.**
- `build.sh` copies the committed keys into Info.plist as `CalaUpdatePublicKeys`, and the feed URL as `CalaUpdateFeedURL`.
- An empty key file means no updater: the Settings row says "This build can't update itself".
- A build with `CALA_UPDATE_TEST=1` is compiled with `-Xswiftc -DCALA_UPDATE_TEST`. Only such a binary accepts:
  - `CALA_UPDATE_PUBLIC_KEYS` and `CALA_UPDATE_FEED_URL` values that differ from the committed ones;
  - `http://127.0.0.1` URLs;
  - the `CalaUpdateTest*` Info.plist keys for faults and timings (§10).
  
  Such a build also gets `CalaUpdateTest=true`. A release binary ignores all of these.

## 5. Installing (in-process, background queue)

All the work runs on `DispatchQueue(label: "Cala.update", qos: .utility)`. URLSession uses a background delegate queue, and subprocesses wait through their `terminationHandler` with timeouts (hdiutil 60 s, ditto 120 s). The main thread only receives state changes through `main.async`. It never waits. The Switcher's keyboard tap runs on the main run loop (`Switcher.swift:221-227`) and so does the SIGTERM handler (`main.swift:49-64`), so blocking main would stall Cmd/Option+Tab (finding 3).

**Tools (finding 2).** `/usr/bin/lipo` is an `xcrun` shim (78 hard links to one binary) and fails on Macs without the Command Line Tools. The install path uses only:
- **Real OS binaries:** `/usr/bin/hdiutil` and `/usr/bin/ditto`. Both are Mach-O with one link each (verified with `ls -l` and `file`). They run with an environment containing only `PATH=/usr/bin:/bin` and `DEVELOPER_DIR=/var/empty`.
- **Frameworks:**
  - Signature checks: Security (`SecStaticCodeCreateWithPath`, `SecStaticCodeCheckValidity` with `kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`, `SecCodeCopyDesignatedRequirement`).
  - Info.plist reads: `PropertyListSerialization`.
  - Architectures: `Bundle(url:).executableArchitectures`.
  - Quarantine: `removexattr` instead of `/usr/bin/xattr`.
- The `lipo` in `build.sh` is build-time, on the maintainer's machine, and stays.

**Steps** (`UpdateInstaller`):
1. **Download.** `URLSessionDownloadTask` into `~/Library/Caches/local.cala/Updates/<version>-<build>/`.
   - Before starting, `volumeAvailableCapacityForImportantUsage` of the target volume must be at least `size + 2 × unpackedSize + 100 MB`, else `.diskFull`.
   - If the connection drops, `resumeData` is kept in memory for **Try again**.
   - The timeout is 300 s.
2. **Verify the file.** Opened with `O_NOFOLLOW`. Size and SHA-256 must match the signed manifest, else `.verificationFailed` and the file is deleted. No partial file is ever used.
3. **Stage privately (finding 4).**
   - Open the target's parent folder: `dirfd = open(parent, O_DIRECTORY | O_NOFOLLOW)`.
   - Record the target's `(st_dev, st_ino)` with `fstatat(dirfd, "Cala.app", AT_SYMLINK_NOFOLLOW)` and refuse if it is a symlink.
   - Create `mkdtemp("<parent>/.cala-update.XXXXXXXX")`. It is mode 700 and owned by this user, so other accounts cannot enter it.
   - Lock: `openat(dirfd, ".cala-update.lock", O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0664)` plus `flock(LOCK_EX | LOCK_NB)`. If another account is installing, the result is `.busy`.
   - Under the lock, re-read the installed version and build. If they are already at or above the manifest, the result is `.upToDate` (a success).
4. **Mount and copy.**
   - `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <stage>/mnt <verified file>`
   - `ditto <stage>/mnt/Cala.app <stage>/new/Cala.app`
   - Detach, with a forced detach on timeout. `ENOSPC` gives `.diskFull`.
5. **Check the staged app:**
   - The code signature is valid (the Security calls above).
   - Bundle id, `CFBundleShortVersionString` and `CFBundleVersion` equal the manifest's, and `CFBundleExecutable` is `Cala`.
   - Its architectures include this Mac's.
   - `LSMinimumSystemVersion` is at or below the current macOS.
   - Its designated requirement string equals the installed one (`identifier "local.cala"`), which keeps TCC grants ([TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements.md)).
   - **Keychain helper, depending on how the installed copy is signed (finding 13; `build.sh:90` re-signs the helper in Developer ID mode):**
     - Ad-hoc (no Team ID): `Contents/Helpers/cala-keychain` must have the same SHA-256 as the installed helper and as `keychainHelperSHA256`. Partitions trust it by cdhash ([forum](https://developer.apple.com/forums/thread/845980)).
     - Team ID: same Team ID and identifier `local.cala.keychain`.
6. **Normalize.**
   - `removexattr("com.apple.quarantine")` recursively. URLSession files are not quarantined anyway ([Eclectic Light](https://eclecticlight.co/2020/10/29/quarantine-and-the-quarantine-flag/)).
   - Set the group to `admin` when this user belongs to it, then `chmod u+rwX,g+rwX,o-w` recursively.
   - `fsync` the stage folder.
   - In test builds, `CalaUpdateTestFault=before-swap` aborts here.
7. **Swap.**
   - Check the target's `(st_dev, st_ino)` again; if it changed, `.busy`.
   - `renameatx_np(stagefd, "new/Cala.app", dirfd, "Cala.app", RENAME_SWAP)`. It is atomic: there is always a complete bundle at the path. `EPERM` or `EACCES` gives `.blockedByMacOS` (App Management) and leaves the target as it was.
   - The previous bundle is now at `<stage>/new/Cala.app`. Rename it to `<stage>/previous/Cala.app` and keep it for the rollback (§6).
   - In test builds, `CalaUpdateTestFault=after-swap` aborts here.
8. **After the swap (finding 14).** Failures here are warnings in `debug.log`. The result is still `.installed`, for example if the mount can't be removed or the cache can't be cleaned.

The UI shows **Restart now** only when a blocker is open (step 9 below). Otherwise the app relaunches:
- If the user started the install and the only blocker is Settings, the update window or the updater itself, Cala runs `Relaunch.open` right away. This is the existing `NSApp.terminate` path (`Lifecycle.swift:165-193`), with the clean-exit marker and the Dock and menu bar restored. Never `kill`.
- If the Zones editor, onboarding or a modal is open, the UI says "Installed. Cala restarts when you close <x>." It relaunches when that blocker clears, through a call from `UpdateService`. This cannot go through `BundleUpdateMonitor`: with a developer build number it may never see the release as newer.
- Between the swap and the relaunch, the Keychain helper refuses the old process with exit 77 (`MailService.swift:142,920`). While `UpdateService.pendingRestart` is set, Mail shows "Restarting to finish the update" instead of an error.

## 6. Crash at launch: rollback, blocked builds, skip (findings 7, 8)

The old process writes `~/Library/Application Support/Cala/update-pending.json` before relaunching:

```json
{"from":"1.0.0+120","to":"1.1.0+131","previous":"<stage>/previous/Cala.app","deadline":"<now+120 s>"}
```

`Relaunch.openAfterTermination` then starts the **previous** bundle's helper, which is known to work, instead of the plain `open` script:

```
<stage>/previous/Cala.app/Contents/Helpers/cala-update watch --pending <file> --pid <old pid> --target /Applications/Cala.app
```

`cala-update` is a tiny standalone CLI. It has no NSApplication and never touches the Dock, so it is not a second Cala.
1. It waits for the old process to exit.
2. It runs `/usr/bin/open -g <target>`.
3. It waits up to 120 s (test builds: `CalaUpdateTestUpTimeout`) for `update-up-<version>+<build>`. The new Cala writes that file 20 s after `applicationDidFinishLaunching` has started its modules, and only if `update-pending.json` names its own version and build.
4. **If the marker appears:** it deletes `<stage>` and `update-pending.json`. Done.
5. **If the deadline passes:**
   - Create `update-rollback`. The watchdog script exits without relaunching while that file exists; that check is a new line in `Watchdog.swift`'s script.
   - If a Cala from the target path is still running for this user, send it SIGTERM. Cala turns that into `NSApp.terminate` (`main.swift:49-64`). Wait up to 10 s. **It never uses SIGKILL**: if Cala is still alive it gives up, logs, and leaves things as they are.
   - Check that `previous` has the expected bundle id and a valid signature.
   - `renameatx_np(..., RENAME_SWAP)` it back into place.
   - Add `"1.1.0+131"` to `update-blocked.json`.
   - `open` the previous Cala, remove `update-rollback`, and record the failure for the UI ("Cala 1.1.0 didn't start, so 1.0.0 was restored. It won't be offered again.").
   - The previous Cala adopts the Dock again through its normal launch path (`DockControl.swift:63-94`).
6. **If the helper itself is killed** (for example at logout): on the next launch, Cala finds `update-pending.json`.
   - If it names Cala's own version, the update worked: Cala writes the marker and deletes the stage itself.
   - Otherwise Cala deletes the stale file.

Cala merges `update-blocked.json` into `blockedBuilds` at launch. The installer refuses those builds too, not only the checker.

## 7. Schedule and deferral

- **When:** checks run only with `updateChecks` on and `installPath == .ready || .needsAdmin`. The first check is 2–10 minutes after launch (random), then every 24 h ± 2 h, and again on wake if one is overdue.
- **Backoff:** after a failure, 1 h, then 2 h, 4 h … up to 24 h, and never sooner than a `Retry-After`. **Check for updates** works at any time, at most once a minute.
- **Network:** an ephemeral URLSession with no cookies. Background requests set `allowsConstrainedNetworkAccess = false`. The User-Agent is `Cala/<version>`.
- **Blocker:** new `UpdatePolicy.Blocker.updater` ("update in progress"). It is set while the window is open, a download runs or an install runs, so `BundleUpdateMonitor` never relaunches in the middle of one.
- **Automatic install:** off by default. When on, it needs all of the following (`UpdateRules.autoInstall`, pure):
  - Path `.ready`, not skipped, not blocked.
  - Every `UpdatePolicy` blocker clear.
  - Idle for at least 10 minutes: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)`.
  - No `PreventUserIdleDisplaySleep` assertion held by another process (`IOPMCopyAssertionsStatus`), which means no video or presentation running.
  - Then it downloads, installs and relaunches through §5 and §6.

## 8. UI (all strings `tx("en","es")`)

**Indicators.** At least one is always visible, because the status item shows whenever the bar is off (`ModulePlan.swift:75`). They appear when an update is available and not skipped.
- **Bar:** `UpdateButton` with `arrow.down.circle.fill` in the accent color, 26 pt. It sits right after the `Spacer`, before the Join pill, tray and clock (`BarView.swift:61-67`), so it does not need the Tray module. Its frame id is `updateID = "__update"`, and the click handler in `BarModule.swift:425-445` opens `UpdateWindowController`. Accessibility label: "Cala \(v) update available" / "Actualización de Cala \(v) disponible".
- **Bar right-click menu** (`BarModule.swift:592`) and **status item menu** (`StatusItem.swift:40`): the first item is "Install Cala \(v)…" / "Instalar Cala \(v)…".
- **Status item glyph:** gets a small dot, composited and still a template image.
- **Settings sidebar:** a dot after "Help and diagnostics" (`SettingsWindow.swift:315-338`).

**Update window** (about 420×380). It is shared with the Settings card.
- Title: "Cala \(v) is available" / "Cala \(v) está disponible".
- Subtitle: "You have \(cur)." / "Tienes la \(cur).".
- The notes in the current language, then "Full release notes" / "Notas completas".
- Buttons: "Skip this version" / "Omitir esta versión", "Later" / "Más tarde", and the default button "Download and install" / "Descargar e instalar".
- Caption: "Cala restarts by itself. It takes a few seconds." / "Cala se reinicia sola. Tarda unos segundos."

**Settings → Help and diagnostics, first card** (`SupportSettings.swift:36-45`). The "Cala version" row stays. The "Updates" link row becomes:

| State | Text (en / es) | Action |
|---|---|---|
| idle | Not checked yet / Aún no se ha revisado | Check for updates / Buscar actualizaciones |
| checking | Checking… / Buscando… | — |
| upToDate | Cala is up to date. Checked at \(t). / Cala está al día. Revisado a las \(t). | Check for updates |
| available | Cala \(v) is available. / Cala \(v) está disponible. (+ notes) | Download and install / Descargar e instalar |
| skipped | You skipped Cala \(v). / Omitiste Cala \(v). | Download and install |
| downloading | Downloading… \(p)% / Descargando… \(p)% | Cancel / Cancelar |
| verifying / installing | Verifying… / Verificando… · Installing… / Instalando… | — |
| pendingRestart | Installed. Cala restarts when you close \(x). / Instalada. Cala se reinicia cuando cierres \(x). | Restart now / Reiniciar ahora |
| rolledBack | Cala \(v) didn't start, so \(cur) was restored. / Cala \(v) no arrancó, así que se restauró la \(cur). | — |
| offline | Couldn't reach GitHub. Cala will try again later. / No se pudo conectar con GitHub. Cala lo intentará más tarde. | Try again / Reintentar |
| feedUnavailable | Update information isn't available right now. / La información de actualizaciones no está disponible ahora. | Try again |
| verificationFailed | The download didn't pass the security check, so nothing was installed. / La descarga no pasó la verificación de seguridad, así que no se instaló nada. | Try again |
| diskFull | Not enough free space (needs \(n)). / No hay espacio suficiente (necesita \(n)). | Try again |
| busy | Another account is installing this update. / Otra cuenta está instalando esta actualización. | Try again |
| blockedByMacOS | macOS blocked the update. Allow Cala in System Settings › Privacy & Security › App Management. / macOS bloqueó la actualización. Permite Cala en Ajustes del Sistema › Privacidad y seguridad › Gestión de apps. | Open System Settings / Abrir Ajustes del Sistema |
| needsAdmin | Ask an administrator to install it, or install it by hand. / Pide a un administrador que la instale, o instálala a mano. | Open release page / Abrir la página |
| needsNewerMacOS | Cala \(v) needs macOS \(m) or later. / Cala \(v) necesita macOS \(m) o posterior. | — |
| manualInstall | This version must be installed by hand. / Esta versión se instala a mano. | Open release page |
| unsupported | Updates work when Cala is in Applications. / Las actualizaciones funcionan cuando Cala está en Aplicaciones. | — |
| unavailable | This build can't update itself. / Esta versión no puede actualizarse sola. | View releases online (existing link) |

Two switches follow the status row:
- **Check for updates automatically / Buscar actualizaciones automáticamente:** on by default. The caption is honest (finding 15): "Once a day Cala asks GitHub whether there is a new version. GitHub sees your IP address and Cala's version, as with any download." / "Una vez al día Cala pregunta a GitHub si hay una versión nueva. GitHub ve tu dirección IP y la versión de Cala, como en cualquier descarga."
- **Install updates automatically / Instalar actualizaciones automáticamente:** off by default, and disabled while checks are off or the path isn't `.ready`. Caption: "When you're away from the Mac, Cala installs the update and restarts. When it's off, you install with one click." / "Cuando no estás usando la Mac, Cala instala la actualización y se reinicia. Si está apagado, la instalas con un clic."

## 9. Persistence

- **`Config`:** `updateChecks = true` and `updateAutoInstall = false`, owned by `Settings/SupportSettings.swift`.
  - `scripts/check-settings.sh` adds both to that file's list, changes the counts at line 63 to `(44, 3, 12, 59)` and updates the PASS message.
  - Finding 12: `check-settings.sh:68-73` also compares a gitignored local file, `build/settings-audit/inventory.md`, when it exists. So the check can pass in a fresh worktree and fail in a checkout that has the file. After merging, the main session adds the two keys to that local file (§11 E0), or deletes it if it is obsolete.
- **UserDefaults key `update.state`:** last attempt and success, failure count, `retryNotBefore`, the highest version seen, `skippedVersion`, `blockedBuilds`, the last envelope (shown offline, re-verified when loaded), the downloaded file, the last result. This is machine-local state, not preferences. It resets with `defaults delete local.cala update.state`.
- **Files in `~/Library/Application Support/Cala/`:** `update-pending.json`, `update-up-*`, `update-blocked.json` and `update-rollback` are written by the helper and by Cala (§6).

## 10. Release pipeline (existing scripts, documented in `docs/release.md`)

**`build.sh`**
- Build the `cala-update` target and combine its architectures with build-time `lipo`, like `Cala`. Copy it to `Contents/Helpers/cala-update` and sign it before the app: ad-hoc with `--options runtime --identifier local.cala.update`, or the identity in Developer ID mode.
- Write `CalaUpdatePublicKeys` and `CalaUpdateFeedURL` into Info.plist. With `CALA_UPDATE_TEST=1`, also write the test overrides: `CalaUpdateTest`, `CalaUpdateTestFault`, `CalaUpdateTestUpTimeout`, `CalaUpdateTestIdleSeconds`, `CalaUpdateTestCrashAtLaunch`. They are baked into the plist because environment variables don't reach an app started with `open` (finding 11).
- Add `CALA_BUILD_DIR` (default `build`), so test fixtures are never built into `build/`.
- The test variables, which `build.sh` accepts only together with `CALA_UPDATE_TEST=1`, map to plist keys: `CALA_UPDATE_TEST_FAULT` → `CalaUpdateTestFault` (`before-swap` or `after-swap`), `CALA_UPDATE_TEST_UP_TIMEOUT` → `CalaUpdateTestUpTimeout`, `CALA_UPDATE_TEST_IDLE_SECONDS` → `CalaUpdateTestIdleSeconds`, and `CALA_UPDATE_TEST_CRASH_AT_LAUNCH` → `CalaUpdateTestCrashAtLaunch`, which aborts at the start of `applicationDidFinishLaunching`, before the Watchdog and the modules start.
- `cala-keychain` stays byte-identical.

**`make-dmg.sh`:** honors `CALA_BUILD_DIR`.

**`release.sh`**
- Refuses to run with any `CALA_UPDATE_*` variable set.
- Refuses a `VERSION` at or below the highest `v*` tag (finding 10).
- Requires `docs/releases/<version>.en.md` and `.es.md`.
- After the DMG:
  1. Writes the manifest.
  2. Runs `update-sign.swift sign`, which asks for the passphrase.
  3. Runs `update-sign.swift verify --keys packaging/update-public-keys --dmg …`.
  4. Mounts the DMG read-only and checks the app inside: `CalaUpdatePublicKeys` equals the committed keys, `CalaUpdateFeedURL` is the default, no `CalaUpdateTest*` key is present, the version and build equal the manifest's, and the `cala-keychain` SHA-256 equals `keychainHelperSHA256` (finding 9).

**`publish-github.sh`**
- Checks again that `latest.json` verifies against the committed keys and matches the DMG it uploads.
- Uploads `latest.json` with the DMG and `.sha256`, and uses the two notes files in the body. The release stays a draft.

**After publishing the draft (finding 1, G0):** from a machine that is not logged in, run

```bash
curl -fsSL https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json -o /tmp/l.json
swift scripts/update-sign.swift verify --keys packaging/update-public-keys --feed /tmp/l.json
```

**`install.sh`:** publishes as `$USER:admin` with `g+w` (§2). It still uses `sudo` and still swaps atomically.

**`scripts/make-update-fixture.sh` (new, test only):** `--out DIR --version V --build N --keys DIR [--corrupt sig|sha|size] [--crash-at-launch]`. It builds with `CALA_UPDATE_TEST=1 CALA_BUILD_DIR=DIR/app` into a DMG and a test-signed `latest.json` in `DIR`, and refuses an output folder inside the repository.

**Bootstrap:** 1.0.0 installs have no updater. The first release with it is installed by hand once.

## 11. End-to-end plan: the fixture ladder

The rules: one Cala instance only, `build/Cala.app` is never opened, and only the main session runs this after merging. Marketing versions put the fixtures *below* the real `VERSION`, so the final `./install.sh` is never outranked and every fixture outranks the previous one. `$T` is a temporary folder outside the repo, deleted at the end. The owner's Terminal is needed for **[sudo]** steps (`install.sh`) and for watching for dialogs.

| Step | Who | Command / action | Expected |
|---|---|---|---|
| E0 | agent | `scripts/check-*.sh`, `swift build -c release`. Add the two keys to the local inventory if present | All pass |
| E1 | agent | `swift scripts/update-sign.swift testkey "$T/keys"` | Test pair written |
| E2 | agent | Fixtures: `scripts/make-update-fixture.sh --out "$T/f2" --version 0.0.2 --build 2 --keys "$T/keys"`; same for `f3 0.0.3 --crash-at-launch`, `f4 0.0.4 --corrupt sig`, `f5 0.0.5 --corrupt sha`, `f6 0.0.6 --corrupt size`, `f7 0.0.7` (clean), and `f1 0.0.1` (equal to the old build) | `latest.json` and DMG per folder |
| E3 | agent | `mkdir "$T/serve"`, then `python3 -m http.server 8765 --bind 127.0.0.1 -d "$T/serve"` in the background. To serve fixture N, copy its `latest.json` and DMG into `serve/` (the manifest's URL points at `127.0.0.1:8765`) | — |
| E4 | owner **[sudo]** | Record `defaults read com.apple.dock autohide-delay` first. Then `CALA_VERSION=0.0.1 CALA_UPDATE_TEST=1 CALA_UPDATE_PUBLIC_KEYS="$(cat $T/keys/public)" CALA_UPDATE_FEED_URL=http://127.0.0.1:8765/latest.json ./install.sh` | Old build 0.0.1 running. `stat -f '%Su:%Sg %Sp' /Applications/Cala.app` shows `<user>:admin drwxrwxr-x` |
| E5 | owner | Serve f1, then Settings → Check for updates | upToDate |
| E6 | owner | Stop the server, then Check | offline. Then serve an empty folder (404): feedUnavailable |
| E7 | owner | Serve f4, Check | verificationFailed before any download (signature) |
| E8 | owner | Serve f5, then f6, Download and install | verificationFailed after download. Inode of `/Applications/Cala.app` unchanged (`stat -f %i`). No `.cala-update.*` left in `/Applications` |
| E9 | owner | Serve f2, Download and install | **No password dialog.** Relaunch as 0.0.2. One process (`pgrep -x Cala \| wc -l` = 1). Group admin, g+w. `codesign -d -r- /Applications/Cala.app` gives `identifier "local.cala"`. `scripts/verify-keychain-helper.sh /Applications/Cala.app/Contents/Helpers/cala-keychain --cdhash` passes. Dock autohide-delay is unchanged. Stage folder gone after the marker appears. This is the **App Management gate**: if the swap returns blockedByMacOS, stop and report |
| E10 | owner | Serve f3, install | f3 aborts at launch, before modules start. Within the test timeout 0.0.2 is back. Settings shows rolledBack. `update-blocked.json` contains 0.0.3. Check again: not offered. Dock autohide-delay unchanged |
| E11 | owner | Serve f7, press Skip this version | Indicator gone, Settings shows skipped, and the install from Settings still works → 0.0.7 |
| E12 | owner **[sudo]** | Faults: reinstall an old build as in E4, adding `CALA_UPDATE_TEST_FAULT=before-swap` (build.sh bakes it into the plist). Install f2: target inode unchanged. Repeat with `after-swap`: new build in place, its stage removed at the next launch | As stated |
| E13 | owner | Auto-install: in the E12 build, also set `CALA_UPDATE_TEST_IDLE_SECONDS=30`. Turn **Install updates automatically** on, serve f7, leave the Mac idle. Repeat with a video playing, and with the Zones editor open | It installs while idle, and waits while the video plays or the editor is open |
| E14 | owner | Second admin account: log into the other admin account while the first one's Cala is on 0.0.2. Serve f7 there and install | Works without a password. Back in the first session, its Cala relaunches as 0.0.7 once the session is active |
| E15 | owner | **Permissions and Keychain after each install** (E9, E11, E14): `grep 'launch:' ~/Library/Application\ Support/Cala/debug.log \| tail -1`. This needs a new log line, `launch: version=… accessibility=… screenRecording=…`, from `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`. Settings → Permissions is all green. A hover preview shows a thumbnail. Option+Tab works. In Mail, Refresh shows **no** "cala-keychain wants to access" dialog, and `debug.log` has no `keychainDenied` or `(77)` after the relaunch | Accessibility and Screen Recording both `true`. No Keychain dialog |
| E16 | owner **[sudo]** | Restore production: `./install.sh`. Stop the server and `rm -rf "$T"` (deletes the test key) | `PlistBuddy -c 'Print :CalaUpdateTest' /Applications/Cala.app/Contents/Info.plist` fails, `CalaUpdatePublicKeys` equals the committed keys, `defaults delete local.cala update.state` |

Password prompts: three or four `sudo` prompts in all (E4, E12 once or twice, E16), plus logging into the second account. The in-app updates never ask.

## 12. Implementation shards

Three code shards plus docs, with disjoint files. Workers build and run checks only. They never run `install.sh`, launch Cala, run `--snapshot`, or open `build/Cala.app`.

**Order:** A and B run in parallel. C starts at the same time, against A's frozen contract, and its acceptance runs after A is merged. Then D, then E2E (§11).

### A. Core: feed, rules, signature, installer
- **Files:**
  - `Sources/Cala/UpdateVersion.swift` (Foundation)
  - `Sources/Cala/UpdateFeed.swift` (Foundation)
  - `Sources/Cala/UpdateRules.swift` (Foundation)
  - `Sources/Cala/UpdateSignature.swift` (Foundation and CryptoKit only)
  - `Sources/Cala/UpdateInstaller.swift` (Foundation, Darwin, Security)
  - `Checks/UpdateCore/main.swift`, `Checks/UpdateInstall/main.swift`
  - `scripts/check-update.sh`: add two compile units and keep the current one. Enforce the import rule per file.
- **Contract:**

  ```swift
  struct UpdateManifest: Codable, Equatable { schema, bundleId, version, build: Int, minimumSystemVersion, publishedAt: Date,
                                               dmg: Asset /*url,size,sha256*/, app: AppInfo /*unpackedSize,keychainHelperSHA256*/,
                                               notes: [String: String], notesURL: URL? }
  enum UpdateSignature { static let domain: Data
      static func verify(feed: Data, publicKeys: [Data]) throws -> (manifest: UpdateManifest, bytes: Data) }
  struct AppVersion: Comparable { init?(version: String, build: String) }      // version first, then build
  enum UpdateEvaluation: Equatable { case upToDate, available(UpdateManifest), skipped(UpdateManifest),
      manualInstall, needsNewerMacOS(String) }
  enum FeedFailure: Equatable { case offline, feedUnavailable, rateLimited(retryAfter: TimeInterval?), tooLarge }
  enum UpdateRules {
      static func evaluate(_ m: UpdateManifest, running: AppVersion, bundleId: String, os: OperatingSystemVersion,
                           highestSeen: AppVersion?, skipped: String?, blocked: Set<String>, testURLs: Bool) -> UpdateEvaluation
      static func classify(status: Int, headers: [String: String], error: URLError?) -> FeedFailure?
      static func nextCheck(now: Date, lastAttempt: Date?, failures: Int, retryAfter: TimeInterval?, jitter: Double) -> Date
      static func autoInstall(enabled: Bool, path: InstallPath, idleSeconds: Double, blockers: Int, presenting: Bool,
                              skipped: Bool, blocked: Bool, idleThreshold: Double) -> Bool
      static func installPath(location: AppLocationKind, bundleWritable: Bool, parentWritable: Bool) -> InstallPath }
  enum InstallPath { case ready, needsAdmin, unsupported }
  enum InstallResult: Equatable { case installed(previous: URL), upToDate, verificationFailed(String), diskFull(Int64),
      busy, blockedByMacOS, failed(String) }
  final class UpdateInstaller {   // all work on its own queue; completion on main
      init(target: URL, tools: InstallerTools = .system, faults: InstallerFaults = .none)
      func install(manifest: UpdateManifest, dmg: URL, completion: @escaping (InstallResult) -> Void) }
  ```

  `InstallerTools` wraps hdiutil, ditto and the code-signature checks, so tests can substitute them.
- **Acceptance:**
  - Every rule in §3, §5 and §7 has a positive and a negative test.
  - The RFC 8032 §7.1 vectors are copied from the RFC (https://www.rfc-editor.org/rfc/rfc8032#section-7.1). Tests also cover a flipped byte, a missing prefix and a wrong key.
  - Version-first comparison, including "developer build number above the release".
  - 404, 401 and 403 give `feedUnavailable`. 429 and 403 with rate-limit headers give `rateLimited`.
  - Installer, on fake bundles in a temp folder, with real ad-hoc `codesign --sign -` at test time: the swap works. `before-swap` and `after-swap` leave a target that is byte-identical or fully new. A symlinked target is refused, a changed inode gives `busy`, a held lock gives `busy`, and a changed keychain helper gives `verificationFailed`. No `.cala-update.*` is left after a failure. Cleanup errors after the swap still return `installed`.
  - No `/usr/bin/lipo`, `xcrun` or PlistBuddy in the sources (grep in the check).
- **Check:** `scripts/check-update.sh`

### B. Pipeline, key tool, rollback helper
- **Files:**
  - `Package.swift`: add executable target `cala-update`.
  - `Sources/CalaUpdateHelper/main.swift`: `watch` and the swap, self-contained.
  - `Checks/UpdateHelper/main.swift`, `scripts/check-update-helper.sh` (new)
  - `build.sh`, `install.sh`, `scripts/make-dmg.sh`, `scripts/release.sh`, `scripts/publish-github.sh`
  - `scripts/update-sign.swift`, `scripts/make-update-fixture.sh`
  - `packaging/update-public-keys` (empty until the maintainer generates a key)
  - `docs/release.md`, `docs/releases/README.md`
- **Contract:**
  - The helper CLI and files from §6. The watchdog contract: if `update-rollback` exists, it does not relaunch. Shard C adds that line to `Watchdog.swift`.
  - `update-sign.swift` subcommands and the key format from §4. Shard A verifies its output.
  - Info.plist keys from §4 and §10.
- **Acceptance:**
  - `update-sign.swift selftest` passes. A feed it signs verifies with A's `UpdateSignature` (cross-check in `check-update-helper.sh`, once A is merged).
  - The helper `watch` test, using fake bundles, a fake `open` (injected only under `-DCALA_UPDATE_TEST`) and short timeouts: the marker path deletes the stage; the timeout path swaps back, writes `update-blocked.json` and never sends SIGKILL.
  - A test build contains `Contents/Helpers/cala-update`, and `codesign --verify --deep --strict` passes.
  - The `cala-keychain` cdhash is unchanged.
  - `CALA_UPDATE_TEST=1 scripts/release.sh` exits non-zero before building. A key file with no keys gives an Info.plist with no `CalaUpdatePublicKeys`.
- **Check:**

  ```bash
  scripts/check-update-helper.sh && \
  CALA_UPDATE_TEST=1 CALA_BUILD_DIR="$TMPDIR/cala-b" CALA_UPDATE_FEED_URL=http://127.0.0.1:8765/latest.json ./build.sh && \
  codesign --verify --deep --strict "$TMPDIR/cala-b/Cala.app" && \
  scripts/verify-keychain-helper.sh "$TMPDIR/cala-b/Cala.app/Contents/Helpers/cala-keychain" --cdhash && \
  ! CALA_UPDATE_TEST=1 scripts/release.sh
  ```

### C. App: service and UI
- **Files:**
  - `Sources/Cala/UpdateService.swift`, `Sources/Cala/UpdateWindow.swift` (new)
  - `Sources/Cala/UpdatePolicy.swift` (the `.updater` blocker), `Sources/Cala/BundleUpdateMonitor.swift`, `Checks/Update/main.swift`
  - `Sources/Cala/Config.swift`, `scripts/check-settings.sh`, `Sources/Cala/Settings/SupportSettings.swift`
  - `Sources/Cala/StatusItem.swift`, `Sources/Cala/BarView.swift`, `Sources/Cala/BarModule.swift`, `Sources/Cala/SettingsWindow.swift`
  - `Sources/Cala/main.swift`: start and stop the service, the `launch:` log line, the crash fault, Snapshots fixtures for every state.
  - `Sources/Cala/Lifecycle.swift`: the pending-update relaunch through the helper.
  - `Sources/Cala/Watchdog.swift`: the `update-rollback` check.
  - `Sources/Cala/MailService.swift`: exit 77 while `pendingRestart`.
- **Contract:**

  ```swift
  final class UpdateService: ObservableObject {
      static let shared
      @Published var state: UpdateState
      @Published var available: UpdateManifest?
      @Published var pendingRestart: Bool
      func start(store: ConfigStore)
      func stop()
      func checkNow()
      func install()
      func skip()
      func later()
  }
  ```
- **Acceptance:**
  - All strings use `tx`. The audit counts 59/59 keys.
  - No synchronous wait on main: grep for `waitUntilExit` and `.sync` outside `UpdateInstaller`.
  - The blocker test passes.
  - Every §8 state has a Snapshots fixture. The main session renders and reviews them.
- **Check:** `scripts/check-update.sh && scripts/check-settings.sh && swift build -c release`

### D. Docs (after merge)
- **Files:** `docs/architecture.md` (the module and check tables, the update section), `docs/configuration.md` (keys and state), `docs/troubleshooting.md` (feedUnavailable, blockedByMacOS, rollback, `update-blocked.json`), `docs/features.md`, `README.md`, `README.es.md` (an Updating section, and the privacy paragraph at `README.md:174` mentioning the daily check).
- **Acceptance:** matches the merged behavior.
- **Check:** review. Docs-only, so no install.

## Red-team findings: disposition

| # | Disposition |
|---|---|
| 1 | Agreed: §3 `feedUnavailable` and the G0 command in §10 |
| 2 | Agreed for install time. Confirmed: `/usr/bin/lipo` has 78 hard links (the xcrun shim), while `codesign`, `ditto`, `hdiutil` and `xattr` are single real binaries. The install path uses Security calls and `removexattr`, and keeps only `hdiutil` and `ditto`. Build-time `lipo` in `build.sh` stays (maintainer toolchain) |
| 3 | Agreed. The tap is on the main run loop (`Switcher.swift:227`). Everything in §5 runs off main |
| 4 | Agreed. `/Applications` is `drwxrwxr-x root:admin` with no sticky bit (verified). §5 step 3 and step 7 cover it |
| 5 | Agreed: two-field envelope, `schema` signed |
| 6 | Resolved by the encrypted key file (§4) |
| 7, 8 | Agreed: §6 |
| 9 | Agreed: §10 checks the mounted DMG, and fixtures build outside `build/` |
| 10 | Agreed. Confirmed `install.sh:20-28`. Version first, and `release.sh` refuses a non-increasing `VERSION` |
| 11 | Agreed: the ladder, faults baked into the plist, `get-cala.sh` dropped, prompts counted |
| 12 | Agreed. Confirmed `check-settings.sh:68-73`. Config, settings and service are one shard (C), and the local inventory is a main-session step (E0) |
| 13 | Agreed. Confirmed `build.sh:90`. The check depends on how the copy is signed (§5 step 5) |
| 14 | Agreed: §5 step 8 |
| 15 | Agreed: the §8 caption |
