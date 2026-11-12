# GFW8 License Grabber CLI

**v1.5.0 - Alec Breen | TheBreenis**

Download [CLI v1.5.0](https://github.com/thebreenis/gfw8-license-grabber/releases/tag/cli-v1.5.0) from GitHub Releases.

The command-line edition is a separate, single Windows x64 executable: `GFW8LG-CLI.exe`. It runs from CMD, PowerShell, or Windows Terminal. Its cyan, purple, and green console sections follow the GUI's Windows 8 colours. Plain text is used when output is redirected or `--no-color` is supplied.

It shares the GUI's 108-game catalogue, receipt validation, private output folders, native helper, sign-in recovery, installed-game guards, and bulk receipt behaviour. No Python, SDK, or adjacent files are needed to run it. Windows PowerShell 5.1/.NET Framework and the same Windows account/Appx requirements apply.

## Interactive use

Run `GFW8LG-CLI.exe` with no arguments. The header shows the CLI version and credit. Select a game by number or name, get or import a receipt, optionally get a token, and optionally test Presence. Importing a receipt automatically selects its game. Changing games clears the current receipt/token selection.

The menu also offers bulk receipts, account/installation status, token clipboard copy, saving the sanitized activity log, and opening saved files. Presence asks before changing activity and submitting Last Played history. No achievement requests are made.

Press **S** for receipt sharing: temporary/permanent codes, join, peer catalogues, automatic pulls, pause, shared-game selection and background mode. See the [sharing guide](SHARING.md).

## Commands

```cmd
GFW8LG-CLI.exe --sharing
GFW8LG-CLI.exe --list
GFW8LG-CLI.exe --game 26 --status
GFW8LG-CLI.exe --game 26 --receipt
GFW8LG-CLI.exe --game "Dragon Mania Legends" --receipt --token
GFW8LG-CLI.exe --import "D:\Receipts\pop.bin" --token
GFW8LG-CLI.exe --import "D:\Receipts\pop.bin" --token --presence
GFW8LG-CLI.exe --bulk
GFW8LG-CLI.exe --version
GFW8LG-CLI.exe --help
```

`--presence` explicitly requests the Presence/Last Played operation and requires `--token` in the same invocation. `--token` requires `--receipt` or `--import`. Bulk cannot be combined with token or Presence operations. Installed games support receipts only; the backend checks installation again before token/Presence calls.

Press **Ctrl+C during bulk** to request cancellation after the current request finishes. Completed downloads remain saved. During authentication, Ctrl+C leaves the worker running until authentication and cleanup finish; complete or cancel any Windows sign-in prompt. The GUI and CLI share an operation lock, so close one before using the other for live operations. Read-only catalogue listing, bundle verification and offline demo mode can run independently.

The receipt policy is 24 hours from its issued timestamp. Token expiry is taken from Xbox's response. Tokens are saved privately and are not printed to the console; the interactive clipboard option copies the saved token XML. Successful receipts use the same per-game folders as the GUI. Failed/unlicensed bulk attempts stay in the batch summary without creating game folders.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Successful operation |
| 1 | Operation, profile/Presence confirmation, worker, or startup error |
| 2 | Invalid arguments or missing receipt/token |
| 3 | No license for the selected game/edition |
| 4 | Installed-game guard blocked the token/Presence operation |
| 5 | Operation cancelled; completed bulk results retained |

`--demo` runs simulated menu/command flows without Windows account or network requests. Its clearly labelled receipt/token/log paths are examples, not real files. `--list` and `--status` do not sign in; status only queries the selected game's installation.

## Build and test

```powershell
python tools/build.py --cli-only
python tests/Test-CLI.py
```

The regular `python tools/build.py` builds both the GUI and CLI. Add `--rebuild-native` to compile the helper from C++ source. `VERSION` tracks the GUI; `CLI_VERSION` tracks the console edition. The CLI embeds a minimal backend bundle and verifies it when extracting into a private versioned runtime folder.

Offline tests cover flags, version/credit, all 108 entries, interactive flows, worker IPC, exit codes, import selection, private diagnostics, the shared operation lock and cooperative bulk cancellation. They use an explicitly synthetic test worker; they do not acquire real receipts/tokens, call Store/Xbox, or change game registrations.

Press **I** in the main menu for the built-in receipt installer. Select a folder, ZIP, or 7z path, review its newest valid receipt per game, explicitly answer Y/N for uninstalled games, and confirm installation. This copies receipts into the current user package data folders and replaces existing receipts without backups. It does not contact Microsoft. Ctrl+C cancels after the current file. See [receipt installation](RECEIPT-INSTALLER.md).

Sharing in CLI1.5.0: G accepts comma-separated IDs or ALL for sequential downloads. R explicitly refreshes friend catalogues; L shows transfer and connection activity. Both peers should update to receive saved-receipt confirmations.
