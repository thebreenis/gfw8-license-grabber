"""Offline source/package checks. Does not use account credentials or network."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('project_build', ROOT / 'tools/build.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_routes()
import package_policy
from deterministic_build import verify_dependencies
verify_dependencies(ROOT)
package_policy.inputs(ROOT, 'source')
version = (ROOT / 'VERSION').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+', version)
for folder in ('src', 'backend', 'tools', 'tests', 'docs', 'relay'):
    for path in (ROOT / folder).rglob('*'):
        if not path.is_file() or any(part in path.parts for part in ('__pycache__', 'node_modules', '.wrangler')):
            continue
        assert path.name.lower() not in ('pop.bin', 'issued-token.xml', 'native-token.txt', 'request-private.json', 'registration.lock', 'appxmanifest.xml')
        if path.suffix.lower() in ('.ps1', '.cs', '.cpp', '.py', '.json', '.txt', '.xml', '.md', '.cmd'):
            text = path.read_text(encoding='utf-8-sig')
            assert not re.search(r'[A-Za-z]:[/\\]Users[/\\][^/\\\s]+[/\\]', text), str(path)
            assert not re.search(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA )?PRIVATE KEY-----)', text), str(path)
payload = ROOT / 'build/gui-payload.zip'
if payload.exists():
    with zipfile.ZipFile(payload) as archive:
        assert archive.testzip() is None
        import runtime_layout
        expected_backend = {'backend/' + '/'.join(runtime_layout.NAMES.get(part, part) for part in Path(name).parts[1:])
                            for name in package_policy.manifest(ROOT)['backend']}
        expected_ui = {Path(name).name for name in package_policy.manifest(ROOT)['ui'] if Path(name).name != 'Launcher.cs'}
        expected = expected_backend | expected_ui | {'README.txt','Sharing.dll','GFW8LG-Agent.exe','sharing-relay.json','sharing-icon.png'}
        assert set(archive.namelist()) == expected, 'Unexpected or missing GUI bundle member'
        helper = 'backend/runtime/xbox-auth/shared-auth-helper/'
        inventory = json.loads(archive.read(helper + 'payload-inventory.json').decode('utf-8-sig'))
        for component in inventory:
            name = helper + component['path'].replace('\\', '/')
            assert hashlib.sha256(archive.read(name)).hexdigest() == component['sha256'].lower(), name
        native_hash = hashlib.sha256(archive.read(helper + 'Probe.exe')).hexdigest().upper()
        assert native_hash in archive.read('backend/runtime/xbox-auth/AcquireXboxToken.ps1').decode('utf-8-sig')
        assert len(json.loads(archive.read('backend/games.json').decode('utf-8-sig'))['games']) == 108
        assert f'Text="v{version}"' in archive.read('MainWindow.xaml').decode()
        assert 'backend/runtime/xbox-auth/AcquireXboxToken.ps1' in archive.namelist()
        assert 'backend/runtime/xbox-auth/XboxTokenWorker.ps1' in archive.namelist()
        for name in archive.namelist():
            assert 'jetpack-auth-investigation' not in name and 'standalone-receipt-tool' not in name
            if name.endswith('.ps1'):
                script = archive.read(name).decode('utf-8-sig')
                assert 'jetpack-auth-investigation' not in script and 'Test-XboxExchange.ps1' not in script
        assert not any(Path(name).name.lower() in ('pop.bin', 'issued-token.xml', 'native-token.txt', 'registration.lock', 'appxmanifest.xml') for name in archive.namelist())
print('PASS: 108 routes, manifest provenance, dependency hashes, version, package CRC and private-artifact exclusions.')
cli_payload = ROOT / 'build/cli-payload.zip'
if cli_payload.exists():
    with zipfile.ZipFile(cli_payload) as archive:
        assert archive.testzip() is None
        assert 'Worker.ps1' in archive.namelist()
        assert 'App.ps1' not in archive.namelist() and 'MainWindow.xaml' not in archive.namelist()
        assert len(json.loads(archive.read('backend/games.json').decode('utf-8-sig'))['games']) == 108
        assert not any(Path(name).name.lower() in ('pop.bin', 'issued-token.xml', 'native-token.txt', 'registration.lock', 'appxmanifest.xml') for name in archive.namelist())
    print('PASS: minimal CLI bundle, all108 entries, CRC and private-artifact exclusions.')
agent_payload = ROOT / 'build/agent-payload.zip'
if agent_payload.exists():
    with zipfile.ZipFile(agent_payload) as archive:
        assert archive.testzip() is None
        assert 'SharingBackend.ps1' in archive.namelist()
        assert not any('Probe.exe' in name or 'Test-XboxExchange' in name or 'AcquireXboxToken' in name or 'private' in Path(name).name.lower() for name in archive.namelist())
        assert 'backend/runtime/receipt-support/receipt-public.cer' in archive.namelist()
        assert not any(Path(name).name.lower() in ('pop.bin', 'issued-token.xml', 'native-token.txt') for name in archive.namelist())
    print('PASS: receipt-only agent payload, CRC and private-artifact exclusions.')
