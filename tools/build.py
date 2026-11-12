"""Build the standalone Windows x64 GUI from this checkout (Python stdlib only)."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sharing_build

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_routes():
    games = json.loads((ROOT / 'backend/games.json').read_text(encoding='utf-8-sig'))['games']
    auth = ROOT / 'backend/runtime/jetpack-auth-investigation'
    configs = json.loads((auth / 'shared-auth-helper/identities.json').read_text(encoding='utf-8-sig'))
    assert len(games) == len(configs) == 108
    assert len({row['gameId'] for row in configs}) == 108
    assert all(game['tokenAttemptAvailable'] for game in games)
    routes = json.loads((ROOT / 'src/metadata/AdditionalTokenRoutes.json').read_text(encoding='utf-8-sig'))
    for route in routes:
        manifest = ROOT / 'src' / route['manifest']
        assert digest(manifest) == route['manifestSha256']
        root = ET.fromstring(manifest.read_bytes())
        namespace = root.tag.split('}')[0][1:]
        expected = {'Windows8': 'http://schemas.microsoft.com/appx/2010/manifest',
                    'Windows10': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10'}[route.get('metadataEra', 'Windows8')]
        assert namespace == expected
        identity = root.find('{' + namespace + '}Identity')
        config = route['configuration']
        assert all(identity.attrib[key] == config[field] for key, field in [('Name', 'name'), ('Publisher', 'publisher'), ('Version', 'version')])
        actual = next(row for row in configs if row['gameId'] == config['gameId'])
        assert actual == config
        game = next(row for row in games if row['index'] == config['gameId'])
        assert game['package_family_name'] == config['family'] and game['legacy_xbox_title_id'] == config['titleId']
        if route.get('titleIdEvidence') == 'user-accepted-candidate':
            assert route['userAcceptedCandidate'] and not game['nativeTitleVerified'] and game['tokenRoute'] == 'experimental'
    inventory = json.loads((auth / 'shared-auth-helper/payload-inventory.json').read_text(encoding='utf-8-sig'))
    for item in inventory:
        assert digest(auth / 'shared-auth-helper' / item['path']).lower() == item['sha256'].lower()
    probe_hash = digest(auth / 'shared-auth-helper/Probe.exe').upper()
    assert probe_hash in (auth / 'Test-XboxExchange.ps1').read_text(encoding='utf-8-sig')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rebuild-native', action='store_true', help='Requires VS C++ Build Tools and Windows SDK/C++ WinRT headers.')
    parser.add_argument('--cli-only', action='store_true', help='Build only the console EXE.')
    args = parser.parse_args()
    if os.name != 'nt':
        sys.exit('Build on Windows 10/11 x64 with .NET Framework and Windows PowerShell 5.1.')
    validate_routes()
    version = (ROOT / 'VERSION').read_text().strip()
    assert re.fullmatch(r'\d+\.\d+\.\d+', version)
    stage = ROOT / 'build/staging'
    stage.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'backend', stage / 'backend', dirs_exist_ok=True)
    for file in (ROOT / 'src/ui').iterdir():
        if file.suffix == '.ico':
            shutil.copy2(file, stage / file.name)
            continue
        text = file.read_text(encoding='utf-8-sig')
        if file.name == 'Launcher.cs':
            text = re.sub(r'"\d+\.\d+\.\d+-"', '"' + version + '-"', text)
        if file.name == 'MainWindow.xaml':
            text = re.sub(r'(x:Name="AppVersion" Text=")v[^"]+', r'\g<1>v' + version, text)
        (stage / file.name).write_text(text, encoding='utf-8-sig' if file.suffix == '.ps1' else 'utf-8')
    shutil.copy2(ROOT / 'docs/USER-GUIDE.txt', stage / 'README.txt')
    if args.rebuild_native:
        subprocess.run(['cmd.exe', '/c', str(ROOT / 'tools/build-native.cmd')], check=True)
        helper = stage / 'backend/runtime/jetpack-auth-investigation'
        old_hash = digest(helper / 'shared-auth-helper/Probe.exe').upper()
        binary = ROOT / 'build/native/Probe.exe'
        new_hash = digest(binary).upper()
        shutil.copy2(binary, helper / 'shared-auth-helper/Probe.exe')
        driver = helper / 'Test-XboxExchange.ps1'
        driver.write_text(driver.read_text(encoding='utf-8-sig').replace(old_hash, new_hash), encoding='utf-8-sig')
        inventory = helper / 'shared-auth-helper/payload-inventory.json'
        rows = json.loads(inventory.read_text(encoding='utf-8-sig'))
        next(row for row in rows if row['path'] == 'Probe.exe')['sha256'] = new_hash.lower()
        inventory.write_text(json.dumps(rows, indent=2) + '\n', encoding='utf-8-sig')
    import runtime_layout
    runtime_files = runtime_layout.prepare(ROOT, stage)
    sharing_files = sharing_build.build(ROOT, stage)
    payload = ROOT / 'build/gui-payload.zip'
    # Enumerate source-owned files only; test results in staging are never embedded.
    files = [stage / p.name for p in (ROOT / 'src/ui').iterdir() if p.name != 'Launcher.cs']
    files += [stage / 'README.txt'] + sharing_files
    files += runtime_files
    with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(files):
            assert file.name.lower() not in ('pop.bin', 'issued-token.xml', 'native-token.txt', 'request-private.json', 'registration.lock', 'appxmanifest.xml')
            info = zipfile.ZipInfo(file.relative_to(stage).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, file.read_bytes())
    with zipfile.ZipFile(payload) as archive:
        assert archive.testzip() is None
    windows = Path(os.environ.get('WINDIR', r'C:\Windows'))
    csc = windows / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    automation = windows / 'Microsoft.NET/assembly/GAC_MSIL/System.Management.Automation/v4.0_3.0.0.0__31bf3856ad364e35/System.Management.Automation.dll'
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    exe = dist / 'GFW8 License Grabber.exe'
    if not args.cli_only:
        subprocess.run([str(csc), '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
                    '/win32icon:' + str(stage / 'App.ico'), '/reference:System.Windows.Forms.dll',
                    '/reference:System.IO.Compression.dll', '/reference:' + str(automation),
                    '/resource:' + str(payload) + ',GFW8.Payload', '/out:' + str(exe), str(stage / 'Launcher.cs')], check=True)
        subprocess.run([str(exe), '--verify-bundle', str(ROOT / 'build/embedded-verification.json')], check=True)
        assert json.loads((ROOT / 'build/embedded-verification.json').read_text())['bundleVerified']
    cli_version = (ROOT / 'CLI_VERSION').read_text().strip()
    assert re.fullmatch(r'\d+\.\d+\.\d+', cli_version)
    cli_source = ROOT / 'build/CliProgram.cs'
    cli_source.write_text((ROOT / 'src/cli/Program.cs').read_text(encoding='utf-8-sig').replace('__CLI_VERSION__', cli_version), encoding='utf-8')
    cli_payload = ROOT / 'build/cli-payload.zip'
    cli_names = {'Worker.ps1', 'GuiBackend.ps1', 'InstalledGames.ps1', 'LegacyPackageRecovery.ps1', 'InstalledGameHost.cs', 'GFW8LG-Agent.exe', 'sharing-relay.json', 'ReceiptInstaller.ps1', 'ReceiptArchives.ps1'}
    with zipfile.ZipFile(payload) as source, zipfile.ZipFile(cli_payload, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as target:
        for entry in source.infolist():
            if entry.filename.startswith('backend/') or entry.filename in cli_names:
                target.writestr(entry, source.read(entry.filename))
    cli_exe = dist / 'GFW8LG-CLI.exe'
    subprocess.run([str(csc), '/nologo', '/target:exe', '/platform:x64', '/optimize+',
                    '/win32icon:' + str(stage / 'App.ico'), '/reference:System.Windows.Forms.dll',
                    '/reference:System.IO.Compression.dll', '/reference:System.Web.Extensions.dll',
                    '/reference:System.Security.dll', '/resource:' + str(cli_payload) + ',GFW8.Payload', '/out:' + str(cli_exe), str(cli_source),
                    str(ROOT / 'src/cli/Sharing.cs'), str(ROOT / 'src/sharing/ShareCrypto.cs'), str(ROOT / 'src/sharing/ShareClient.cs')], check=True)
    subprocess.run([str(cli_exe), '--verify-bundle', str(ROOT / 'build/cli-embedded-verification.json')], check=True)
    assert json.loads((ROOT / 'build/cli-embedded-verification.json').read_text())['bundleVerified']
    built = [cli_exe] if args.cli_only else [exe, cli_exe]
    (dist / 'SHA256SUMS.txt').write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in built), encoding='ascii')
    print(json.dumps({'guiVersion': version, 'cliVersion': cli_version, 'files': [{'file': str(p), 'sha256': digest(p)} for p in built], 'bundlesVerified': True}))


if __name__ == '__main__':
    main()
