GFW8 TOKEN LAB v0.1.3
Alec Breen | TheBreenis
Developer-only companion. Separate from GFW8 License Grabber.

Run "GFW8 Token Lab v0.1.3.exe". Its filename and Windows Properties details automatically follow the Lab version. It contains the runtime; Windows 10/11 x64,
.NET Framework 4.x and Windows PowerShell 5.1 are required, like the main app.

This build fixes a helper inventory crash when an installed development package
has no InstallLocation. A separate Xbox service rejection may still be reported
after the helper reaches the token endpoint; this update does not change Xbox
authentication or licensing behavior.

PULL ALL RECEIPTS + TEST TOKENS
Checks the complete 108-game catalogue through Microsoft's receipt service
using the same backend as GFW8 License Grabber v1.10.3. Downloads entitled,
valid receipts, then attempts a native Xbox token for each downloaded receipt.
Receipts and tokens go to the same private Games folders used by the main app.
Games without a license appear in the receipt results, without empty game folders.
The BOM correction and shared full-scan/HTTP-throttle cooldowns are retained.

TEST ALL SAVED RECEIPTS
Uses the newest currently valid receipt proof for each game saved by the app.
It does not request more Microsoft licenses. It does make token requests.
Arbitrary pop.bin files without an app validation record are not scanned.

TEST A SINGLE RECEIPT
Choose one pop.bin file. The app validates its signature, identity and expiry,
saves a validated copy, then attempts a token for that game only. No Store
receipt request is made. The table and reports include a Trial / Full column.
STOP CURRENT PROCESS
Available while a run is active. Stops further receipt/token requests after the
current request and helper cleanup finish. The button disables once requested;
completed results are retained. Closing the window requests the same safe stop.

TOKEN CHECKS AND LIMITS
A "Valid token" means the backend accepted issuance, confirmed expiry and
helper cleanup, and a read-only Xbox profile request returned HTTP 200.
It does not prove game sign-in, Presence or achievement permissions.
The tool makes no Presence or achievement writes.

Installed games are logged as blocked. They are never uninstalled or replaced.
Windows sign-in prompts are enabled by default. Uncheck the option for unattended,
silent attempts. No repeated automatic retries or alternative SDK probes.
Close the main GUI/CLI before starting a batch. Sharing may remain running;
receipt requests share the backend request lock and throttle state.

Repeated Microsoft requests can be throttled; there is no published safe-rate
guarantee. Full pulls retain the app's 15-minute cooldown shared with Bulk and
Sharing and stop on HTTP throttling without automatic retries. Receipts are
requested sequentially with no extra fixed pause between completed requests.
This removes about 2 minutes 42 seconds of artificial waiting over 108 games;
network and service response times still determine the actual scan duration.
One Windows credential is reused for the batch, as before. Cached token tests
do not bypass token-server limits. Closing the window requests a stop after
the current operation and helper cleanup.
Unconfirmed cleanup or game-data preservation stops the batch for inspection.
The Lab tolerates changes to Windows-managed Settings\settings.dat,
settings.dat.LOG1, settings.dat.LOG2 and roaming.lock. These exact files remain
in the before-run backup, but their normal changes do not stop the batch.
All other existing files, including game saves and every pop.bin, retain
the preservation check. The main app preservation policy is unchanged.

REPORTS
Click Open Reports for the latest run under:
  %LOCALAPPDATA%\GFW8TokenLab\Runs

  results.csv / results.json  Receipt and token outcomes for the run
  token-failures.csv          Failures and blocks, codes, stage, HTTP/SOAP,
                             cleanup and read-only profile check status
  summary.json               Counts, cancellation/stopping reason, backend version
  events.jsonl               Activity events, without token/account contents
  worker-private.log         Private worker startup/PowerShell output; do not share

Click a game row for its concise message; Copy Failures copies the CSV.
Diagnostics references in CSV are relative to the main app's private data root:
  %LOCALAPPDATA%\GFW8LicenseGrabber
Raw token diagnostics and the successful tokens remain there, in Games\...\Tokens.
These raw files are private and must not be uploaded with the sanitized report.
Reports still disclose your game list and error history; review before sharing.

BUILD
The source ZIP includes the pinned backend snapshot and Metro title-bar source.
Extract it with token-lab and main-snapshot alongside one another. Run build.py
from token-lab with Python on Windows; output goes to token-lab\dist.
The .NET Framework csc compiler is used; no NuGet download.
No personal receipts, credentials, saved profiles or test run logs are embedded.
This is an unsigned developer executable; no GitHub publication was performed.
