"""Product-facing runtime names; research source paths remain stable."""
from pathlib import Path

NAMES = {
    'jetpack-auth-investigation': 'xbox-auth',
    'standalone-receipt-tool': 'receipt-support',
    'Test-XboxExchange.ps1': 'AcquireXboxToken.ps1',
    'Invoke-TemporaryXboxAuth.ps1': 'XboxTokenWorker.ps1',
}

def text(value):
    for old, new in NAMES.items():
        value = value.replace(old, new)
    return value

def prepare(root, stage):
    files = []
    for original in (root / 'backend').rglob('*'):
        if not original.is_file():
            continue
        relative = original.relative_to(root / 'backend')
        source = stage / 'backend' / relative
        target = stage / 'backend' / Path(*(NAMES.get(p, p) for p in relative.parts))
        data = source.read_bytes()
        if original.suffix.lower() == '.ps1':
            data = (b'\xef\xbb\xbf' if data.startswith(b'\xef\xbb\xbf') else b'') + text(data.decode('utf-8-sig')).encode('utf-8')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files.append(target)
    for script in stage.glob('*.ps1'):
        data = script.read_bytes()
        script.write_bytes((b'\xef\xbb\xbf' if data.startswith(b'\xef\xbb\xbf') else b'') + text(data.decode('utf-8-sig')).encode('utf-8'))
    return files
