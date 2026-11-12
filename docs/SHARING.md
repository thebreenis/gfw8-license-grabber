# Receipt sharing

GUI 1.9.0 and CLI 1.5.0 include a receipt sharing agent, version 1.2.0, by Alec Breen | TheBreenis. Each app remains a single distributable EXE. On first use, it installs its bundled agent into the current Windows user's private app-data folder.

## Pair and pull

Open **Receipt sharing** at the bottom of the GUI, or press **S** in the CLI menu (`GFW8LG-CLI.exe --sharing`). Each person uses their own Windows Microsoft account. Obtain your own receipts locally first; the shared list contains verified locally acquired receipt records for the current Windows receipt account. Imported receipts are not advertised as owned games.

Create a **Temporary Pairing Code** or **Permanent Pairing Code**, send the code privately, and have the other person paste it in the separate join field and choose **Join Code**. Codes are single use and expire after 10 minutes. Joining grants mutual access to each person's selected games; subsequent pulls need no provider approval. Keep the sharing screen open until the pair appears. Joining has a 30-second timeout and a Cancel button; your own generated code is rejected locally. Press Enter or Refresh in the CLI to see updated status.

Choose a paired computer, check the games you want in the left list (or use **Select All**), then choose **Download Checked**. **Clear** removes the checks. The right-hand checkboxes control which of your own games you offer. A batch runs one receipt at a time, keeps completed downloads, and stops after the current receipt when cancelled. The first transfer failure stops the batch and is shown in the status text. The provider must be online. Its agent requests a new receipt from Microsoft for every transfer. A failed request never falls back to a cached receipt. Receipts outside their signed 24-hour window are rejected. The receiver verifies the Microsoft signature, game edition, Full license type and receipt date before saving it. In the GUI, close the sharing window to apply the received receipt to the main screen. In the CLI, return to the main menu to use it.

A temporary pair ends when either agent disconnects or after two hours. Without background mode, closing the app stops its agent and ends temporary sessions. A permanent pair retains trust across restarts; both computers reconnect automatically when their apps next open. Unpair removes that relationship on both sides.

The friend's catalogue is requested once per connection and kept as a stable snapshot. Local status updates do not rebuild it or discard checks/scroll position. **Refresh Friend's List** requests an updated snapshot; reconnecting also loads a new one. Newly shared titles are added on refresh/reconnection. Withdrawn titles can disappear immediately, and the provider rechecks sharing permissions on each transfer even if the receiver has an older list.

The bottom-right **Transfer Activity** panel shows connection/disconnection, receipts downloaded from friends, outgoing sends and confirmed downloads by friends. A send is not labeled confirmed until the recipient acknowledges successful validation and saving. Both people should update for these confirmations; older peers may remain at “awaiting save confirmation.” The latest 200 events are retained locally in the private Sharing folder across background operation and agent restarts. Logs contain computer labels and game names, never receipt contents or account credentials.

CLI Sharing offers **G** with comma-separated game IDs or **ALL**, **R** for explicit list refresh, and **L** for transfer activity.

## Background mode and controls

Enable **Keep sharing in background; start at Windows sign-in** to serve receipts while the main app is closed. The per-user tray agent reconnects when needed and starts at the next Windows sign-in. The computer must be awake, connected to the Internet, and signed into Windows. This is a per-user agent rather than a system service. No ports need to be opened on a home router.

Uncheck background mode to disable startup and stop sharing after the owning app closes. **Pause sharing** withdraws your catalogue and rejects requests, including requests using an earlier cached list. Check the games you want to offer and choose **Save shared games**. The CLI has equivalent pause, background and shared-game controls. The tray menu can stop the agent immediately.

Use **Scan My Licenses** in Sharing to discover your full owned library; you do not need to use the main window's bulk button first. It checks each catalogue entry with Microsoft and saves only successful receipts. The display shows the last completed scan and reminds you when the catalogue changed or the scan is older than a week. New successful individual pulls update the inventory without requiring another full scan. A completed scan's unlicensed result supersedes older owned records for that game; a later successful pull can add it again.

Full scans are manual and cancellable, run sequentially with a short delay, and share a 15-minute local cooldown with the main Bulk button and CLI bulk downloads. That interval is an app precaution, not a documented safe rate for the legacy API. Repeated requests may be throttled. The app stops scans/bulk on HTTP429 or HTTP503 with Retry-After, honors longer Retry-After values, and blocks further receipt requests during the persisted cooldown. Microsoft documents this general approach for [current Store commerce APIs](https://learn.microsoft.com/en-us/xbox/gdk/docs/store/commerce/service-to-service/xstore-fgrl); the exact legacy AcquireReceipt endpoint has no request limit established by our tests. No guarantee against account restrictions is made. A scan talks to Microsoft; it publishes the completed catalogue to paired computers rather than sending a relay request for every game.

Up to four receipt transfers can be served concurrently, with a bounded queue for additional requests. Transfers to different peers can overlap. Microsoft receipt acquisitions are serialized across local GUI, CLI and agent workers, including scans, to avoid simultaneous refresh bursts. Paired friends cannot trigger full scans remotely.

New local receipt records update your own available inventory after a short delay; friends add new titles on their next manual refresh or connection. Use **Refresh** after changing Windows accounts or resolving Windows sign-in. If silent Windows authorization is unavailable, the agent reports that sign-in is needed; it cannot complete verification unattended.

Sharing copies receipts; it does not change Microsoft Store ownership. Receipt acceptance and later Xbox token acceptance are separate outcomes. Tokens and Presence are still requested locally by the recipient, with the existing installed-game restrictions and sign-in requirements.

## Relay and local storage

The bundled relay is `https://gfw8lg-receipt-relay.alec2dabreen.workers.dev`. Friends do not need Cloudflare accounts. Cloudflare stores public device keys and pair relationships. It forwards encrypted catalogues and receipts and does not store their plaintext. Paired computers pin each other's keys through the pairing-code secret. Device private keys and permanent peer trust are encrypted with Windows DPAPI for the current user. Local sharing jobs, receipt files and diagnostics remain in the private app-data folder.

The relay uses a separate SQLite Durable Object per device and invitation, plus WebSocket hibernation. There is no repeated HTTP polling for online status. UI refreshes normally read the local agent; an explicit inventory refresh sends a bounded status update. Idle text heartbeats are answered by Cloudflare's WebSocket auto-response. Connections, messages, RPC calls and storage still consume Cloudflare quotas; see the [Durable Objects pricing documentation](https://developers.cloudflare.com/durable-objects/platform/pricing/). No paid plan or domain purchase is required by this setup, and no plan was upgraded during deployment.

The sharing window uses the main app icon, Metro colours and custom window controls; its title is simply **Receipt Sharing**. The CLI includes equivalent pairing, scan, cancellation, freshness and background commands.

The agent is under `%LOCALAPPDATA%\GFW8LicenseGrabber\Sharing`. Background startup uses the current user's `Software\Microsoft\Windows\CurrentVersion\Run` value named `GFW8LicenseGrabberAgent`. Stop the tray agent before replacing its EXE. Keep this directory and its job logs private.

## Relay development

The Windows app build uses Python's standard library and the .NET Framework compiler. Building an app does not require Node or Cloudflare authentication. The relay is a separate Node project:

```powershell

cd relay

npm ci

npx wrangler dev --port 8799

# In another terminal:

node test-relay.mjs

# From the checkout root, with the local relay still running:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Sharing.ps1

```

The black-box relay suite uses Wrangler/workerd and synthetic device keys. It can also run against a deployed relay by passing its HTTPS URL. It covers authentication, nonce reuse, competing joins, third-party routing, opaque forwarding, permanent reconnection and temporary revocation. `tests/Test-Sharing.cs` exercises two isolated fixture agents, including catalogue exchange, encrypted pulls, DPAPI identity reload, pause, whitelist and process restarts. Fixture support is compiled only with `SHARING_TESTS` and is absent from production binaries. `tests/Test-SharingBackend.ps1` checks invalid imports without creating game receipt records.

Deploy changes using Wrangler OAuth with `account:read`, `user:read`, `workers:write` and `workers_scripts:write`; store credentials in the OS keyring. The app bundle contains only the public relay URL. Never put Cloudflare OAuth credentials, real receipts, Microsoft tokens or private logs in a release.

