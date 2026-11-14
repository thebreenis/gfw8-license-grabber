"""Offline CLI/worker-boundary tests; fixture worker never calls Store/Xbox."""
from pathlib import Path
import json
import os
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / ('dist/GFW8LG-CLI v' + (ROOT / 'CLI_VERSION').read_text().strip() + '.exe')
checks = 0


def check(ok, message):
    global checks
    assert ok, message
    checks += 1


def run(args, exe=CLI, stdin=None):
    return subprocess.run([str(exe), '--no-color', *args], input=stdin, text=True, capture_output=True, timeout=45)


version = run(['--version'])
expected_version = (ROOT / 'CLI_VERSION').read_text().strip()
check(version.returncode == 0 and ('CLI v' + expected_version) in version.stdout and 'Alec Breen | TheBreenis' in version.stdout, 'Version and credit')
listing = run(['--list'])
lines = [line for line in listing.stdout.splitlines() if line.strip() and line.strip().split()[0].isdigit()]
check(listing.returncode == 0 and len(lines) == 108, 'All108 catalogue entries')
for args in (['--bulk', '--token'], ['--token'], ['--presence'], ['--game'], ['--unknown']):
    check(run(args).returncode == 2, 'Invalid flags rejected before worker actions: ' + str(args))
flow = run(['--demo', '--game', '26', '--receipt', '--token', '--presence'])
check(flow.returncode == 0 and 'simulated' in flow.stdout and 'Temporary Presence removed: True' in flow.stdout, 'Demo action chain and cleanup display')
menu = run(['--demo'], stdin='2\n4\n5\ny\n6\n0\n')
check(menu.returncode == 0 and '  RECEIPT ' in menu.stdout and '  TOKEN ' in menu.stdout and '  PRESENCE ' in menu.stdout and 'Saved 16' in menu.stdout and not any(label in menu.stdout for label in ('01 RECEIPT', '02 TOKEN', '03 PRESENCE')), 'Interactive menu has unnumbered sections and receipt/token/Presence/bulk chain')

# Build the unchanged CLI source with an explicitly synthetic worker resource.
fixture = ROOT / 'build/cli-fixture'
fixture.mkdir(exist_ok=True)
payload = fixture / 'payload.zip'
with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.write(ROOT / 'tests/fixtures/CliWorker.ps1', 'Worker.ps1')
    archive.write(ROOT / 'backend/games.json', 'backend/games.json')
windows = Path(os.environ['WINDIR'])
csc = windows / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
exe = fixture / 'FixtureCLI.exe'
fixture_source = fixture / 'FixtureProgram.cs'
fixture_source.write_text((ROOT / 'build/CliProgram.cs').read_text().replace('GFW8LicenseGrabber-', 'GFW8LG-Test-').replace('Gfw8Sharing.ShareClient.AutoStartAsync(runtime);', '{}'), encoding='utf-8')
subprocess.run([str(csc), '/nologo', '/target:exe', '/platform:x64', '/reference:System.Windows.Forms.dll', '/reference:System.IO.Compression.dll', '/reference:System.Web.Extensions.dll', '/resource:' + str(payload) + ',GFW8.Payload', '/out:' + str(exe), '/reference:System.Security.dll', str(fixture_source), str(ROOT / 'src/cli/Sharing.cs'), str(ROOT / 'src/sharing/ShareCrypto.cs'), str(ROOT / 'src/sharing/ShareClient.cs')], check=True)
unlicensed = run(['--game', '28', '--receipt', '--token'], exe)
check(unlicensed.returncode == 3, 'No-license exit code')
check(unlicensed.stdout.count('Fixture: no license.') == 1, 'No-license event and final result print once')
installed = run(['--game', '2', '--receipt', '--token'], exe)
check(installed.returncode == 4, 'Installed-game guard exit code')
check(installed.stdout.count('Fixture: installed-game guard.') == 1, 'Installed guard event and final result print once')
repeat = run(['--game', '2'], exe, stdin='2\n4\n4\n0\n')
check(repeat.stdout.count('Fixture: installed-game guard.') == 2, 'Separate retries each print their error once')
duplicate = run(['--game', '42', '--receipt', '--token'], exe)
check(duplicate.returncode == 1 and duplicate.stdout.count('Fixture: duplicate error events.') == 1, 'Repeated same-job error events and result deduplicate')
failure = run(['--game', '33', '--receipt', '--token'], exe)
check(failure.returncode == 1 and 'PRIVATE_FIXTURE_DIAGNOSTIC' not in failure.stdout + failure.stderr, 'Private child diagnostics never leak to console')
check(failure.stdout.count('Fixture: worker failure.') == 1, 'Missing error event still prints final-result error')
imported = run(['--import', 'fixture-pop.bin', '--token'], exe)
check(imported.returncode == 0 and 'Hitman GO receipt:' in imported.stdout and '[fixture token]' in imported.stdout, 'Import auto-selects game for following token action')
cancelled = run(['--import', 'cancel-fixture', '--token'], exe)
check(cancelled.returncode == 5 and 'Operation cancelled' in cancelled.stdout and 'Token saved:' not in cancelled.stdout, 'Worker cancellation stops following token action without a malformed DTO error')
full = run(['--game', '26', '--receipt', '--token', '--presence'], exe)
check(full.returncode == 0 and 'Active readback: True' in full.stdout and 'Temporary Presence removed: True' in full.stdout, 'Actual private worker IPC action chain')
installer_no = run([], exe, stdin='i\nfixture.zip\nn\n0\n')
check(installer_no.returncode == 0 and 'Fixture installer preview' in installer_no.stdout and 'Fixture receipts installed' not in installer_no.stdout, 'Installer uninstalled-game opt-out does not install')
installer_cancel = run([], exe, stdin='i\nfixture.zip\ny\nn\n0\n')
check(installer_cancel.returncode == 0 and 'Fixture receipts installed' not in installer_cancel.stdout, 'Installer final confirmation can cancel')
installer_yes = run([], exe, stdin='i\nfixture.zip\n\ny\ny\n0\n')
check(installer_yes.returncode == 0 and 'Type Y or N.' in installer_yes.stdout and 'Fixture receipts installed' in installer_yes.stdout, 'Installer explicit uninstalled-game opt-in and final confirmation')
logs = Path(os.environ['LOCALAPPDATA']) / 'GFW8LicenseGrabber/Logs/CLI'
before = set(logs.iterdir())
process = subprocess.Popen([str(exe), '--no-color', '--bulk'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    job = None
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        added = set(logs.iterdir()) - before
        if added:
            job = next(iter(added))
            if (job / 'request-private.json').exists():
                break
        time.sleep(.05)
    check(job is not None and (job / 'request-private.json').exists(), 'Bulk creates private worker job')
    blocked = run(['--game', '26', '--receipt'], exe)
    check(blocked.returncode == 1 and 'Close the running GUI/CLI' in blocked.stdout, 'Concurrent GUI/CLI operations blocked by shared mutex')
    (job / 'cancel.flag').write_text('cancel')
    stdout, stderr = process.communicate(timeout=15)
    check(process.returncode == 5 and 'Checked 1/108' in stdout and 'Saved 1' in stdout, 'Cooperative bulk cancellation retains completed count and returns5')
finally:
    if process.poll() is None:
        if job is not None:
            (job / 'cancel.flag').write_text('cancel')
        process.communicate(timeout=35)
summary = {'checksPassed': checks, 'workerCallsSynthetic': True, 'liveStoreOrXboxCalls': 0, 'gameRegistrationsChanged': 0, 'realReceiptOrTokenFilesCreated': 0}
(ROOT / 'build/cli-test-results.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
