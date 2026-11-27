# Mail (maintainers)

How the Mail module works after the latency rework: one persistent IMAP connection per account, optimistic actions with verified rollback, a parsed-body cache with partial fetch and prefetch, attachments, bulk actions and older pages. For what the user sees, read [features.md](features.md#mail). For the Keychain helper, read [architecture.md](architecture.md#code-signing-and-permissions). This page names files and types, not line numbers.

Contents: [Source map](#source-map) · [Connection and sync](#connection-and-sync) · [Optimistic layer](#optimistic-layer) · [Server semantics that must not change](#server-semantics-that-must-not-change) · [Body cache, partial fetch, prefetch](#body-cache-partial-fetch-prefetch) · [Attachments, links, bulk actions, older pages](#attachments-links-bulk-actions-older-pages) · [Credentials](#credentials) · [Observability](#observability) · [Measurements](#measurements) · [Checks, limits and risks](#checks-limits-and-risks)

## Source map

| File | Owns |
|---|---|
| `MailIMAP.swift` | The IMAP client for one connection: command stream, `MailIMAPTuning`, IDLE and DONE, moves, flags, partial bodies, prefetch, attachment chunks, older pages. Also the `NWConnection` transport (`MailIMAPSocket`) |
| `MailService.swift` | `MailService` (main actor): accounts, one `AccountRun` per account (queue, worker, reconnects), overlays, notices, cache wiring, attachments, older pages. `MailTiming`, `MailFailure`, `MailKeychain` (helper client), `MailCredentialStore` |
| `MailSyncPlan.swift` | Pure: `MailLink` constants, `MailKnownMessages`, `MailSyncPlanner` (window, plan, `uidSet`), `MailPrefetchPlanner`, `MailOlderPager`, `MailQueueSignal`, `MailCancelFlag` |
| `MailOverlay.swift` | Pure: the optimistic overlay (effects, states, reconciliation) |
| `MailBodyCache.swift` | Parsed-body cache, memory plus disk |
| `MailBodyStructure.swift` | Pure: BODYSTRUCTURE parser, `MailPartPlan`, `MailPartAssembler` |
| `MailMIME.swift` | Pure Foundation: providers, MIME decoding, IMAP framing and tokens, `MailIMAPMailbox` (trash and archive selection). Must import only Foundation (`check-mail.sh` enforces it) |
| `MailAttachment.swift` | Attachment list, decoding, file-name sanitizing, save, quarantine, Quick Look copies |
| `MailWebBody.swift` | Message web view and its shared state |
| `MailViews.swift` | Tray envelope, inbox panel, reader, selection bar, attachments row, Quick Look |
| `MailKeychainAccess.swift` | Reads Keychain access lists (never passwords) to predict macOS windows |

`TrayModule.swift` starts Mail: it calls `MailWebBody.prewarm()` only when accounts exist, then `MailService.shared.start(explainingKeychain:dismissing:)`. Turning the Tray off calls `stop(purgingCache:)`; quitting or an update relaunch does not purge (see [Body cache](#body-cache-partial-fetch-prefetch)).

## Connection and sync

### One connection per account

Each enabled account has one `AccountRun` and one long-lived worker task (`MailService.monitor`). The worker owns the connection's command stream; only `close()` and `requestRefresh()` may be called from elsewhere. Its loop, per connection:

1. `signIn` (Keychain read, `LOGIN`, `CAPABILITY`, `SELECT INBOX`; if the provider's username form is refused, `LOGIN` is retried once with the full address).
2. Send everything queued (`performOperations`), then sync if a reason is pending, then prefetch if nothing is queued, then park in IDLE (`waitForInboxChange`).
3. IDLE returns an outcome that decides the next sync reason: `idle-renew` syncs only if `MailLink.periodicSync` (15 min) passed since the last sync; `interrupt` syncs as `refresh` when something asked for a refresh (panel opened, wake from sleep), not after an action alone; `link-check` only proves the link lives; any other outcome (`idle-change`, `idle-server-end`, `change`, `poll`) syncs with that outcome as its reason. A server change seen while operations or prefetch ran syncs as `server-change`.
4. Without IDLE the client polls every `MailLink.pollInterval` (120 s).

Wake sources: opening the Mail panel (`refresh()`), `NSWorkspace.didWakeNotification`, any queued operation (`wake`, which also cancels a pending retry delay).

### Link liveness

Gmail drops idle connections silently after about 25 minutes (the old debug log showed IDLE ending in a timeout, then 5 to 44 s to recover). The constants live in `MailLink`:

| Constant | Value | Meaning |
|---|---|---|
| `keepaliveIdle` / `keepaliveInterval` / `keepaliveCount` | 60 s / 10 s / 3 | TCP keepalive on the `NWConnection` (also keeps NAT mappings open). A dead peer fails the connection about 90 s after the last traffic |
| `idleRearm` | 9 min | IDLE is ended with DONE and re-armed well before the silent drop and the 29-minute IDLE limit |
| `doneAckTimeout` | 3 s | Minimum wait for the server's answer to DONE |
| `commandTimeout` | 15 s | Ordinary command timeout (also the TCP connection timeout) |
| `periodicSync` | 15 min | A sync runs at least this often |
| `window` | 25 | Rows the list snapshot keeps |

**DONE acknowledgement.** Every IDLE exit sends DONE and waits for the tagged answer. A live server answers in one round trip. The wait is `max(3 s, 4 × smoothed RTT)` (`doneAckTimeoutMS`; RTT is a moving average of small commands) and it is progress-based, not a deadline: a reply that keeps arriving extends it, only silence for the whole timeout counts. Silence throws `MailIMAPError.linkDead` and logs `link-dead`. This is how a connection that died while idle is found in about 3 s instead of on the next action.

**Early probes.** The transport reports `viabilityUpdateHandler` (not viable) and `betterPathUpdateHandler` as a "suspect" flag, which interrupts IDLE immediately (`link-check` outcome): DONE is sent and the ack decides. The transport also exposes whether the path is constrained or expensive (Low Data Mode, cellular, hotspot), used by prefetch.

**Reconnect.** On any failure `monitor` classifies the error (`MailFailure`):
- Failures that need the user (bad app password, Keychain denied, restart needed) stop the worker and show a status.
- Link failures (`linkDead`, `disconnected`, `timedOut`) reconnect at once when the person is waiting on this connection (something queued or on the wire, foreground work, not a prefetch failure) and the connection had been signed in. That quick retry is granted again only after a connection stayed up for 60 s, so a flapping link cannot loop.
- Everything else waits `backoff` seconds: 2, 4, 8 … capped at 300, reset after a connection that lasted 60 s. `wake`, a new operation and `network-back` cancel the wait.
- `keepContent`: after a quick reconnect, queued opens survive (each is tried at most twice) instead of failing.

**NWPathMonitor.** `MailService.start()` (the shared service only) runs one monitor and calls `networkChanged(satisfied:)`:
- Lost: no run counts as `live`, and every queued action that hides a row is reverted at once with a "No connection" notice (`dropRowActions`, reason `no-network`). Actions queued while the path is unsatisfied revert immediately too.
- Back: runs without a live connection cancel their retry delay and reconnect now (measured: Wi-Fi back to synced in about 6 s).

**Offline grace.** If macOS still says the path is fine but there is no working connection (a dead link not found yet), an action that hides a row waits at most `MailService.offlineGrace` (30 s). When the timer fires and the run is still not live, the row comes back with a notice and the action is dropped; it never runs later behind the person's back. The same drop happens at once when a connection could not even be opened (`connect-failed`) and for actions older than the grace when the connection fails (`offline-too-long`). Reads are harmless to send late, so they stay queued.

### Queue and priorities

`AccountRun.pending` is the account's single queue; the worker sends it in order. `insert` ranks operations:

| Rank | What | Notes |
|---|---|---|
| 0 | Content: opening a message, the attachment list of an old cache entry (`structure`), older-page paging the person scrolled to | `Operation.isContent`. Goes ahead of everything not already on the wire |
| 1 | Cala's own repairs: `verifyMove`, `verifyMany`, `clearDeleted`, `clearDeletedMany` | `isRepair`. They settle an earlier action, so they go before newer actions |
| 2 | The person's actions: mark read or unread, archive, delete, bulk moves and flags, mark all read | Keep their order |
| 3 | Background: attachment downloads and chunks, older-flag refresh, older gap fills | `isBackground`. Always last |

Sync, prefetch and gap fills are not queue entries; they step aside:
- A sync checks `MailQueueSignal` between commands (`shouldYield`). It yields to any waiting work, except the sync that follows a bulk operation, which yields only to content. A yielded sync applies nothing and returns `nil` (`sync-preempted`); the caller sends the queued work and syncs again.
- Prefetch stops between messages when anything is queued (`stop=interactive`), abandons a download in flight (`read-cap reason=interactive-waiting`) and stops if the mailbox changes (`stop=change`). Its timeouts never tear down the link.

Dedup in `enqueue`: a mark-read already waiting (not on the wire) covers a second one; a read and an unread of the same message that were not sent cancel out, only the newest goes. Opening a message shows it read at once; the `STORE \Seen` is queued when the body arrives or after 2 s, so it never sits in front of the body fetch (`open`, `flushDeferredRead`).

After a bulk operation (`markAllRead`, `Operation.isBulk`) the worker reads the inbox again (`after-bulk-operation`) before sending anything else, because it touched messages outside the snapshot.

### Tunings

`MailIMAPTuning` selects the command stream. Only read-only commands differ; delete, archive and flag writes are identical in both.

| Setting | `.fast` (production, `MailIMAP(provider:)`) | `.conservative` (default for injected transports) |
|---|---|---|
| `cachesMailboxList` | One `LIST` per connection | A `LIST` before every move |
| `incrementalSync` | `UID FLAGS` for the newest 25 plus headers only for unknown UIDs | A full `FETCH` of the newest 25 every sync, with a 256 KB second try for empty previews |
| `partialBodies` | `RFC822.SIZE BODYSTRUCTURE`, then only readable parts | `RFC822.SIZE`, then the whole `BODY.PEEK[]` |
| `prefetch` | On | Off |

`.conservative` is the original stream, pinned by the transcript checks. A transport passed to `MailIMAP(socket:provider:tuning:)` gets `.conservative` unless it asks for `.fast`; `MailHarness` in the checks asks for `.fast`. Changing production behaviour means changing `.fast` and its checks, and leaving `.conservative` alone.

### Incremental sync

Per sync (`synchronize`, `incrementalMessages`):

1. Once per connection, if the server has MOVE or UIDPLUS: `LIST`, to learn whether archiving is possible (`canArchive`).
2. `NOOP`.
3. `FETCH n:* (UID FLAGS)` for the newest 25 sequence numbers. Rows flagged `\Deleted` are hidden (`deleted_hidden`), so the original of a half-done move never flashes.
4. `UID FETCH <unknown UIDs> (UID INTERNALDATE [X-GM-THRID X-GM-MSGID] BODY.PEEK[HEADER.FIELDS (...)] BODY.PEEK[TEXT]<0.16384>)`. Known rows come from `MailKnownMessages` (per account and UIDVALIDITY, newest 200); a new UIDVALIDITY forgets them.
5. `UID SEARCH UNSEEN` for unread state.
6. Previews that are empty in the first 16 KB get one `UID FETCH (UID BODYSTRUCTURE)` and one partial fetch of a single text part (`BODY.PEEK[section]<0.32768>`). If the sync yielded first, those rows are marked `incomplete` and read again next time.

Unsolicited news (EXISTS, EXPUNGE, flag changes) bumps `revision`; the connection ignores FETCH answers to its own commands (`solicited`) so they are not counted as news. A change during a sync triggers another pass. On a new UIDVALIDITY the snapshot, older pages and queued reads for old UIDs are dropped, and cached bodies of other epochs are purged.

### Mailbox list cache

With `cachesMailboxList` the `LIST` result is kept for the connection. A move that finds no target in the cache re-lists once. A move answered `NO` or `BAD` with a cached list re-lists once and retries only if the target mailbox was renamed (`renamed()`); if the name is unchanged the refusal stands. The mailbox name is used exactly as `LIST` returned it (modified UTF-7) and only quoted.

## Optimistic layer

What the list shows is the last server snapshot plus the person's pending actions (`MailOverlay`). The snapshot is never edited, so reverting an action means dropping its entry; the exact original row comes back. `MailService.publishInbox` applies the overlay to the window and to the older pages.

**Effects** (`MailOverlay.Effect`): `hide`, `read`, `unread`, `readAllThrough(uid)`, `hideMany`, `readMany`, `unreadMany` (and `readAll`). They are idempotent against the row they find, so a snapshot that already reflects an action is not counted twice. Bulk effects are one entry, so a whole selection confirms or reverts together.

**States** (`MailOverlay.State`):

| State | Shown? | Meaning |
|---|---|---|
| `queued` | yes | Waiting in the account's queue. Also used while a lost move is being verified (row stays hidden) |
| `inFlight` | yes | Sent, no answer yet |
| `held` | no | Repeatable action whose answer was lost with the connection; it will be sent again after reconnecting, and the row looks unchanged until then |
| `confirmed(afterSync: n)` | yes | The server said OK while sync number `n` was the latest started |

**Reconciliation.** Every sync gets a sequence number when it starts (`syncStarted`). On the server's OK the entry becomes `confirmed(afterSync: n)` with `n` = the latest sync started so far. It keeps applying to snapshots from syncs numbered up to `n`, which may have read the mailbox before the OK and would bring a deleted row back. It is dropped when a snapshot from a sync numbered above `n` is applied (`prune(appliedSync:)`). Pruned entries are remembered (last 100) and applied for good to older-page rows, which live outside snapshots (`reconcileOlder`, `prunedLog`).

**Revert paths.** An entry is removed (the row returns) and a notice is shown when:
- the server refuses (`NO`, `BAD`; log `op-refused`, then `optimistic-revert reason=<code>`);
- there is no network at tap time, or `networkChanged(false)` finds the action queued (immediate);
- no connection could be opened, or the 30 s grace passed with no live connection ([above](#connection-and-sync));
- the account stops (removed, turned off, Mail stopped): "Mail stopped before your last changes reached the server" (`failOperations`);
- a verified move turns out not to have happened.

Notices (`MailNotice`) live in `MailService.notices`, at most 3 (the oldest go), until dismissed; texts are in English and Spanish through `tx`. The debug log records only `notice kind=...`, never the text.

**Never resend MOVE or COPY.** `Operation.isRepeatable` is false for `archive`, `trash` and `moveMany`: a second COPY would duplicate the message. Repeatable operations (mark read or unread, flag sets, mark all read) are held and sent again after a reconnect. When a move's answer is lost (the connection fails while it is on the wire), `lostAnswer` does this:

1. The row stays hidden (entry set to `queued`), the lost move is dropped, and a read-only check is queued as a repair (rank 1) that runs after reconnecting.
2. The check asks the server where the message is: `UID FETCH <uid> (UID)`, or `(UID FLAGS)` when a UIDPLUS move had already copied. For a set, one `UID FETCH <set> (UID FLAGS)`.
3. No answer for the UID: it moved; the entry is confirmed.
4. Still there: it did not move. The row returns with "wasn't moved. It's still in Inbox".
5. Still there and `\Deleted` (a UIDPLUS move stopped before its `UID EXPUNGE`): the row returns, a `clearDeleted` repair (`UID STORE <uid> -FLAGS.SILENT (\Deleted)`) is queued, and the notice says a copy exists in the target but the original could not be removed.
6. After a timeout (the server may still finish the command) a "still there" answer is checked once more after `MailService.recheckDelay` (15 s) before it counts.
7. If the check itself cannot run in time (offline grace), the row returns with a "connection dropped before the server confirmed… check the inbox" notice (`unconfirmed`); nothing is resent.

**Half-done UIDPLUS moves** (no MOVE capability). `MailIMAP.lastMoveStage` tracks `none → copied → flagged → done`. If a step is refused, the notice says what happened (`copied`: a copy exists, the original stays; `flagged`: the same, and the `\Deleted` flag is taken off again by a queued `clearDeleted`). Nothing is retried.

**Bulk `UID MOVE` refused.** A `NO` to a MOVE of several UIDs may still have moved some of them (RFC 6851 section 3.3). `mayBePartial` queues a `verifyMany` before anything is reverted, and only the rows still in the inbox come back (the entry is rewritten to `hideMany` of the rows that left).

**Mark all read is bounded by tap time.** `markAllRead` records the newest UID in the snapshot and its UIDVALIDITY (`through:`, `validity:`). The server step is `UID SEARCH UNSEEN`, filtered to UIDs at or below `through`, sorted, then `UID STORE <set> +FLAGS.SILENT (\Seen)` in batches of 300. Mail that arrived after the tap stays unread. A different UIDVALIDITY sends nothing (`staleMessage`).

**Offline summary.** Reads queue and are sent after reconnecting. Deletes and archives never wait on a missing connection: they revert at once when macOS reports no network, otherwise within 30 s. A message that arrived or changed elsewhere meanwhile is handled by the next sync.

## Server semantics that must not change

Delete, archive and the read flags are what users trust Mail with; the checks pin them command by command (`Checks/MailParsing/main.swift`, `checkMailActions`, run for both `.conservative` and `.fast`). Do not "optimize" these.

| Action | Commands |
|---|---|
| **Delete** (move to Trash) | With MOVE: `UID MOVE <set> "<trash mailbox>"`. Without MOVE but with UIDPLUS: `UID COPY <set> "<trash>"`, then `UID STORE <set> +FLAGS.SILENT (\Deleted)`, then `UID EXPUNGE <set>`. With neither: `moveUnsupported`, nothing is sent that mutates |
| **Archive** | The same two paths with the archive mailbox. Gmail: the `\All` mailbox only (mailboxes named Archive are ignored). Other providers: the `\Archive` flag, else a mailbox named `archive` or `archivo` |
| **Mark read** | `UID STORE <set> +FLAGS.SILENT (\Seen)` |
| **Mark unread** | `UID STORE <set> -FLAGS.SILENT (\Seen)` |

Rules behind the table:
- **Never a plain `EXPUNGE`, never `CLOSE`.** Both would permanently remove other clients' pending `\Deleted` messages. Only `UID EXPUNGE` of the same UID set that was copied and flagged is allowed.
- Order is fixed: COPY first, then STORE `\Deleted` (only after COPY was accepted), then UID EXPUNGE (only after STORE was accepted). A refusal stops the sequence.
- A bulk action sends one command per step for the whole UID set (compact set from `MailSyncPlanner.uidSet`); flag writes split at 300 UIDs.
- Trash is the mailbox with `\Trash` (selectable), else one named `trash`, `deleted messages` or `papelera`. A mailbox such as "Deleted Items" without `\Trash` is not guessed. A mailbox named Trash does not beat one carrying the flag.
- Every message must belong to the connection's current UIDVALIDITY (`validate`), else `staleMessage` and nothing is sent.
- A read-only open uses `BODY.PEEK`, never `BODY`, so opening does not mark anything read; read state is changed only by the explicit `STORE`.

`wireIsSafe` in the checks encodes the invariants (COPY accepted, then STORE of the same UIDs, then UID EXPUNGE of the same UIDs; no EXPUNGE, no CLOSE, no sequence-number STORE). The pins were also tried against 13 hand-made mutants of `MailIMAP.swift` (plain EXPUNGE, STORE before COPY, MOVE also flagging, trash and archive swapped, swallowed errors, batch size 500, an extra CLOSE, and so on); all failed the checks. The mutants are not kept in the repository.

## Body cache, partial fetch, prefetch

### Cache (`MailBodyCache`)

Stores parsed `MailContent` (`html`, `text`, plus the attachment list), never raw RFC 822 and never attachment bytes.

- **Key** (`MailBodyKey`): account, mailbox (`INBOX`), UIDVALIDITY, UID and `formatVersion`. A message with no UIDVALIDITY is never cached.
- **Disk:** `~/Library/Caches/<bundle id>/Mail/<sha256(account)>/<sha256(mailbox)[0..<32]>/<validity>/<uid>.v<format>.json`. Directories 0700, files 0600, atomic writes (temporary file then rename), the root excluded from backups.
- **Limits:** memory 24 MB and 30 entries (LRU; an entry above 24 MB is not kept in memory). Disk 100 MB per account and 30 days since last use; a hit touches the file's modification date. When over the disk limit the least recently used go until the account is at 90% of it (`trim`).
- **Blank bodies are never cached** (not in memory, not on disk; a blank file read back is deleted). The reader fetches them again.
- **Lookups:** the reader's first frame uses the memory entry synchronously (`cachedContent`); the disk lookup runs off the main thread; disk writes and purges run on one utility queue (`cacheQueue`).

**Purge rules**

| Event | What goes |
|---|---|
| Account removed, turned off, or provider changed | Memory immediately, files on the queue, and the account refuses writes until it syncs again (`forget`, `deleteFiles`, `allow`), so a write already in flight cannot bring files back |
| UIDVALIDITY changed, or the first sync of a run | Bodies of other epochs in that mailbox (`purge(account:keepingValidity:)`), also catching a change that happened while Cala was off |
| Mail starts (`start()`) | `cleanUp`: folders of accounts that are not enabled, half-written `.tmp` files, and each kept account's files past 30 days or over the limit |
| Tray turned off (`stop(purgingCache: true)`) | Everything, 3 s later (`purgeAll`); a quick `start()` cancels it |
| Quit, update relaunch (`isShuttingDown`) | Nothing: the cache survives |

**When to bump `MailBodyKey.formatVersion`:** whenever `MailMIME.content`'s output changes (sanitizer rules, inline-image handling, anything that alters what a cached body would show) or the stored JSON format changes incompatibly. Old `.v<n>.json` files are not read; they age out through the 30-day and size trimming. Adding an optional field does not need a bump: `attachments` is optional in the file, and an entry without it triggers a `structure` fetch (`UID FETCH (UID BODYSTRUCTURE)`) to fill the list.

### Partial fetch (`MailPartPlan`, `MailPartAssembler`)

With `partialBodies`, opening a message takes two round trips:

1. `UID FETCH <uid> (UID RFC822.SIZE BODYSTRUCTURE)`. The attachment list comes from this structure.
2. `UID FETCH <uid> (UID BODY.PEEK[s.MIME] BODY.PEEK[s] ...)` for the readable leaves only: non-attachment `text/plain` and `text/html`, plus the images of a `multipart/related` that carry a Content-ID. A multipart that a `related` `start` may point to is fetched as `BODY.PEEK[s.MIME]` only (for its Content-ID).

`MailPartAssembler` rebuilds a MIME message from BODYSTRUCTURE's skeleton, a fresh boundary and the fetched parts with their own headers; every other leaf becomes an empty attachment. `MailMIME.content` then parses it exactly as it parses a whole message. This keeps one parser for both paths.

**Fallbacks to the whole message** (`UID FETCH <uid> (UID BODY.PEEK[])`, 25 MB cap, otherwise `messageTooLarge`): single-part messages; a `message/*` part anywhere; an attachment-disposition multipart; depth 25 or more; a multipart with no boundary; no or unparsable BODYSTRUCTURE; planned bytes over 20 MB; a missing part in the reply; a part containing the generated boundary; a rebuild that parses blank. Each is logged: `body-plan mode=full reason=...`. A body fetch fails only after 20 s with no byte at all (`bodyStallMS`), however long the whole reply takes.

### Prefetch policy

After a sync, when nothing is queued, `tuning.prefetch` is on and the path is not constrained or expensive (`prefetch-skip reason=constrained-network`):
- Candidates: the first 8 visible rows of the account that are not cached and not in `prefetchSkipped` (per process), unread ones first.
- One `UID FETCH <set> (UID RFC822.SIZE BODYSTRUCTURE)`, then `select`: a known plan, no part above 1 MB (`maxPart`), running total within 4 MB (`budget`); everything else is skipped.
- One partial fetch per message (max 60 s each, `prefetchCapSeconds`), stored in memory and on disk with its attachment list.
- Stops on queued work or a mailbox change. A failed message is not tried again in this process. A timeout leaves the link up (its late answer is skipped); only a dead link reaches the reconnect logic.

## Attachments, links, bulk actions, older pages

### Attachments

- **Listing:** from BODYSTRUCTURE while opening, or from the whole message after a full fallback (`MailAttachmentList`). Body text and inline `cid:` images of a `related` are not listed. Names decode RFC 2047 and RFC 2231 (`filename*`, continuations). No attachment bytes are fetched until the person asks.
- **Download:** on click (`fetchAttachment`), as a rank-3 background operation, so opens and actions run first. Parts up to 1 MB (`MailIMAP.attachmentChunk`) use one `UID FETCH <uid> (UID BODY.PEEK[section])` (cancellable, stall-based wait). Larger parts use 1 MB chunks, `BODY.PEEK[section]<offset.1048576>`, each its own queued command so other work runs between chunks and a cancel stops after the current one. A short non-final chunk or a total more than 1% below the declared size fails the download (`MailFailure.incomplete`, `attachment-short`); a truncated file is never produced. Decoding (base64 read leniently, quoted-printable) runs off the main thread. Limit: 50 MB decoded (`MailAttachment.downloadLimit`); larger ones show a notice pointing to the web inbox.
- **Memory only:** bytes are held in `attachmentBytes` (150 MB, oldest out first) and released when the Mail panel closes, Mail stops or the account goes (`panelClosed`, `releaseAttachments`). Reopening downloads again.
- **Quick Look** (`MailQuickLook`): needs a file, so `MailAttachmentFiles.quickLookCopy` writes one into its own temporary folder `Cala-QuickLook-<uuid>` (0700), created exclusively with mode 0600 and quarantined before any byte is written. The folder is removed when the preview panel closes, when the next preview starts, when the Mail panel closes with no preview showing, and swept (keeping the one on screen) when the Mail panel appears and when Mail stops. Nothing is opened or run. Quick Look is not offered for types whose preview may load remote content or run active content (`allowsQuickLook`: HTML, XHTML, SVG, XML, `message/rfc822`, web locations, `.eml`, `.webarchive` and similar); those can only be saved.
- **Save to Downloads** (`MailAttachmentFiles.save`): the name is sanitized (`/`, `\`, `:` become `_`; control, format, bidi and zero-width characters, separators, unassigned and private-use scalars are dropped; leading dots removed; never empty; at most 230 UTF-8 bytes measured decomposed, cut on a character boundary with a short extension kept). A taken name becomes `name 2.ext`, `name 3.ext`. The file is created with `O_CREAT | O_EXCL | O_NOFOLLOW`, never replacing anything, and gets the `com.apple.quarantine` attribute on the open descriptor before the first byte, so Gatekeeper checks it before it can run. A failed write removes the partial file. Cala never opens the saved file.

### Links and the message view (`MailWebBody`)

JavaScript is off; `javaScriptCanOpenWindowsAutomatically` is off; link previews are off. The document carries a Content-Security-Policy (`default-src 'none'`; images from `data:` only, plus `https:` and `http:` when remote images are on; no fonts, forms or base URL). Navigation is cancelled for everything except a clicked link with scheme `http`, `https` or `mailto`, which is handed to `NSWorkspace`. The width-fitting query runs in an isolated world. When remote images are off, a compiled content rule list (`cala-mail-block-remote-v1`, blocking `http(s)`) is attached and the alt text replaces blocked pictures.

All views share one `WKWebsiteDataStore.nonPersistent()` with cookies refused, so nothing is written to disk and nothing outlives the process. `MailWebBody.prewarm()` (called at start when accounts exist) applies the cookie policy, compiles or looks up the rule list and starts one throw-away web view, so the first message does not pay for the WebContent process or the rule compile.

### Multi-select bulk actions

In the list, the sender avatar is the selection toggle; while rows are selected the toolbar becomes the selection bar (Archive, Delete, Mark as read, Mark as unread, Clear; Esc or a click on empty space also clears). `MailService.trash/archive/markRead/markUnread([MailMessage])` de-duplicates, filters (`canArchive` for archive, rows whose state would change for flags), groups by account and sends one operation per account with one UID set (`moveMany`, `flagMany`) and one overlay entry (`hideMany`, `readMany`, `unreadMany`). A group of one takes the single-message path. The server commands are those in [Server semantics](#server-semantics-that-must-not-change); a lost or refused bulk move is verified per UID ([Optimistic layer](#optimistic-layer)).

### Scrolling and older pages

The list shows the synced window (25 newest per account) plus older pages loaded while scrolling (`older`, per account, kept in memory only).
- The last row loads by itself when the list is taller than the panel; otherwise it is a button. A failed load shows "Retry" and is retried by itself after the next reconnect.
- The first request does `UID SEARCH UID 1:<lowest-1>` (once per UIDVALIDITY; the UIDs are kept in `olderCandidates`), then each page is `MailOlderPager.page` (25 UIDs) fetched as `UID FETCH <set> (UID FLAGS INTERNALDATE ... headers + 16 KB preview)`. Rows flagged `\Deleted` are skipped; unread comes from `\Seen`; empty previews get the BODYSTRUCTURE-guided look. Decisions are made only for the UIDs asked.
- **Reconciliation after every sync** (`reconcileOlder`): confirmed overlay effects are applied to older rows for good; older rows now inside or above the window are dropped. If the window moved up and left a gap, the gap is filled in the background (at most two pages, added whole only when complete so no hole remains; a wider gap resets the older pages instead; a range already searched is not searched again, `gapSearched`).
- **When the panel opens:** one `UID FETCH <older set> (UID FLAGS)` (`olderFlags`) removes rows deleted elsewhere and refreshes `\Seen`.
- **500-row cap** (`MailService.olderLimit`): paging stops at 500 older rows per account (a partial last page is truncated to fit), `olderCapped` is set and the list says to open the inbox in the browser.
- Closing the panel drops older pages, candidates and counters; a UIDVALIDITY change resets them.

## Credentials

Passwords are read in one place: `signIn` calls `MailCredentialStore.read`, which asks `MailKeychain` to run `Contents/Helpers/cala-keychain` (see [architecture.md](architecture.md#code-signing-and-permissions) for the protocol, exit codes, migration of old items and the notice window). Writes go through `changeCredential` (add or change account, Settings) to the helper's own `v2:<email>` item; `readCurrentCredential` reads only that item, for rollback. `MailKeychainAccess` inspects access lists to predict macOS windows and never reads a password.

Consequence for measuring: the helper refuses any caller that is not the running `Cala.app` bundle's main executable (exit 77), so a standalone harness or a copy of the sources cannot sign in to a real account. Logged-in measurements must be taken inside the installed app (see [Observability](#observability)), and the checks use a scripted IMAP server with injected credentials (`readCredential:`). Do not launch `build/Cala.app` next to the installed one to measure: see `AGENTS.md`.

## Observability

Every line is written to `~/Library/Application Support/Cala/debug.log` (rotated at 1 MB to `debug.log.1`) with the prefix `mail-timing`. Lines never contain credentials, addresses, subjects, bodies or mailbox names: accounts appear as `account[<index>]`, commands as their verb only (`MailTiming.verb`). Times are monotonic milliseconds; `op=<n>` ties the lines of one operation together, `sync=<n>` those of one sync.

| Area | Lines (main fields) |
|---|---|
| Reader and opens | `ui-request` (`first_frame=cache` when drawn from memory), `ui-content-delivered` (`since_request_ms`), `ui-content-failed`, `webview-rules`, `webview-load`, `webview-didFinish` (`since_delivered_ms`) |
| Queue | `enqueue` (`since_tap_ms` or `since_request_ms`, `queued`, `connected`), `dequeue`, `start` (`queue_wait_ms`), `end` (`perform_ms`, `since_tap_ms`), `op-refused`, `content-resume`, `row-gone` (`total_tap_ms`: tap until the server answered) |
| Optimistic layer | `optimistic-apply`, `optimistic-shown` (`publish_ms`, `since_tap_ms`), `optimistic-confirm` (`after_sync`), `optimistic-revert` (`reason`), `optimistic-hold`, `optimistic-verify`, `move-verified`, `move-partial`, `notice` (`kind`), `sync-skip` |
| Protocol | `cmd` (verb, `ms`, `bytes`), `body-plan` (`mode`, `part_bytes`, `full_bytes`), `content-fetched`, `mime-parse`, `late-answer`, `read-cap` |
| Sync | `sync-start` (`reason`, `mode`), `sync-done` (`total_ms`, `bytes`, `fetched_headers`, `incomplete`, `deleted_hidden`), `sync-yield`, `sync-preempted`, `sync-extended-previews`, `sync-part-previews`, `validity-change` |
| Cache and prefetch | `cache-hit` (`source=memory\|disk`, `lookup_ms`), `cache-miss`, `cache-store`, `prefetch-start`, `prefetch-done` (`stop`), `prefetch-failed`, `prefetch-skip` |
| Link | `signin-start`, `signin-end` (`keychain_ms`, `imap_ms`), `idle-exit` (`outcome`, `idle_ms`, `done_ack_ms`), `link-dead`, `link-check`, `link-state`, `link-viability`, `link-better-path`, `connection-lost`, `retry-wait`, `reconnect`, `reconnect-immediate`, `network-lost`, `network-back` |
| Attachments, older pages | `attachment-done`, `attachment-failed`, `attachment-cancelled`, `attachment-saved`, `attachment-short`, `older-request`, `older-page`, `older-gap`, `older-failed`, `older-retry` |

**Measuring before and after.** Use the real app, one account, the same messages:

1. Build the baseline (the commit before the rework, `5c1675d`) or the current code, install it, quit and relaunch so the log starts at `sync=1`.
2. Run the scenario (open, reopen, mark read, delete, archive, attachment, offline) and note the time.
3. Extract: `grep 'mail-timing' ~/Library/Application\ Support/Cala/debug.log`, then per metric:
   - open to content: `ui-content-delivered since_request_ms`; open to visible: `webview-didFinish since_delivered_ms` (first web view of the process is slower, `first_webview=true`);
   - action response: `optimistic-shown since_tap_ms`; server confirmation: `row-gone total_tap_ms`;
   - sync cost: `sync-done total_ms` and `bytes` (`mode=incremental` or `full`);
   - link health: `idle-exit done_ack_ms`, `link-dead`, `connection-lost`, `retry-wait`, `signin-end total_ms`;
   - per-command floor: `cmd ... ms` for `NOOP`.
4. Compare the same lines from the baseline. A baseline from before the rework has no `optimistic-*`, `cache-*` or `mode=` fields: there the row disappears at `row-gone`.

Timestamps are UTC (`+0000`). Close the panel and reopen the Mail panel between runs of the same message so cache state is what you intend (memory vs disk vs network).

## Measurements

Owner's Gmail account, real network, logs `baseline-mail-timing.log` (before) and `after-mail-timing.log` (after). The per-command floor on Gmail is about 176 to 200 ms (`NOOP`), which bounds anything that needs a round trip.

| Scenario | Before | After |
|---|---|---|
| Open an unread message, tap to content | 950 to 1034 ms | 0 ms (from cache or prefetch) |
| Open, tap to visible (web view) | 1383 to 1430 ms; first open 2665 ms | 127 to 633 ms; first open 464 ms |
| Open a 2.7 MB message | 1597 ms content, 2026 ms visible | all opens in the "after" run came from the cache or prefetch (see below) |
| Reopen a message | 740 to 837 ms content, 1153 to 1279 ms visible | from the memory cache, 0 ms content, 127 to 633 ms visible |
| Delete, row gone | 808 to 1366 ms | 0 ms (optimistic); server confirmed 550 to 960 ms in the background |
| Archive, row gone | 633 ms | 0 ms; confirmed in the same 550 to 960 ms range |
| Mark read or unread | 524 to 586 ms (`row-gone`, after the server answered) | 0 ms; confirmed 550 to 960 ms |
| Sync after an action | full sync, about 870 ms and 250 to 300 KB | incremental, 1 to 35 KB (about 1 KB when nothing new) |
| Idle link | silently dead after about 25 min (59 of 67 cycles), then 5 to 44 s to reconnect | re-armed every 9 min, a dead link is found by the DONE check in about 3 s |
| Offline delete | not measured | row reverts with a notice (immediately when macOS reports no network; 30 s grace otherwise) |
| Wi-Fi back | not measured | synced in about 6 s |
| 2 MB attachment | not available | about 3 s, in 3 chunks |

Not measured: a cold open of a message that was not prefetched (every open in the "after" run hit the cache or prefetch), so the wall-clock cost of a cold open through the partial-fetch path is known only from its commands (the structure fetch, then one parts fetch).

## Checks, limits and risks

### Checks

`./scripts/check-mail.sh` compiles `MailMIME.swift` (it fails if that file imports anything but Foundation) together with the Mail sources that do not need AppKit views, `AppPaths` and `CalendarText`, plus `Checks/MailParsing/` (`main.swift`, `MailFastChecks.swift`, `MailFeatureChecks.swift`), and runs the result. It prints `PASS`/`FAIL` per check and a total (663 PASS at the time of writing). `scripts/release.sh` runs every `scripts/check-*.sh`. `MAIL_DEBUG=1` prints the last 30 commands of the scripted server when a check fails.

| Group | What it pins |
|---|---|
| Parsing (`main.swift`) | RFC 2047 and 2231, charsets, snippets, senders, avatars, IMAP framer and tokens, LIST and mailbox selection |
| Wire pins (`main.swift`) | The `.conservative` transcript; delete, archive, mark read and mark all read for both tunings, with the safety invariants and the failure cases (NO, BAD, dropped link, stale message, missing mailbox) |
| Account and Keychain (`main.swift`) | Account lifecycle, notice gate, credential migration and races |
| `.fast` wire and planners (`MailFastChecks.swift`) | `.fast` transcripts (incremental sync, partial bodies, mailbox cache and re-LIST only on rename, prefetch limits), sync and prefetch planners |
| Overlay and service | The overlay table; optimistic actions through `MailService` with a scripted IMAP world that keeps server state across connections: confirm, revert, notices, held, never-resend, lost-answer verification, half-done UIDPLUS moves, offline grace, mark-all-read bound |
| Cache, structure | Body cache (keys, limits, purge, permissions, blank bodies); BODYSTRUCTURE parser, part plan and assembler (alternative, mixed, related, forwarded and malformed shapes; a rebuilt message must read exactly like the whole one) |
| Dead link | DONE-ack timeout, stall extension, immediate reconnect |
| Features (`MailFeatureChecks.swift`) | Attachment lists, names and saving, attachment wire and service (chunking, cancel, short chunks), bulk actions, older pager, older pages (races, gap fills, repeated gap searches, 500-row cap) |

Review findings that were fixed became ordinary checks (named `I*`, `M*`, `F-*`, `G-*`), so a regression fails the script.

Not covered: the real `NWConnection` transport (`MailIMAPSocket`), WebKit, the Keychain helper process, Quick Look and the SwiftUI views, and every timing figure above. Those need the installed app.

### Known limits and risks

- **Cancelling a small download.** A part up to 1 MB is one command; cancel ends the wait within a read slice (about 0.5 s) but the connection keeps receiving and discarding the rest of that reply before the next command's answer can be read. Larger parts are chunked at 1 MB for exactly this reason.
- **Dead link behind a "satisfied" path.** Queued deletes and archives wait for the DONE check (3 s or more) or, at most, the 30 s offline grace, then revert with a notice. A link that dies while a command is on the wire is found by that command's timeout (15 s) or keepalive (about 90 s).
- **Quick Look is off** for HTML, SVG, XML, messages and web-location types; they can only be saved.
- **Cold open not measured** (see [Measurements](#measurements)).
- **Prefetch is best effort.** A message prefetch skipped or failed is not retried until Cala restarts (`prefetchSkipped`); it then opens through the normal two-round-trip path.
- **Only the inbox** is read: the window is the newest 25 rows plus up to 500 older rows per account; older mail is for the browser. Providers: Gmail, iCloud, Yahoo, with app passwords.
