"""Build the receipt-only sharing agent and GUI adapter; no private input files."""
from pathlib import Path
import shutil
import os
import subprocess
import zipfile
import struct


def build(root, stage):
    csc = Path(os.environ.get('WINDIR', r'C:\Windows')) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    source = root / 'src/sharing'
    common = [source / name for name in ('ShareCrypto.cs', 'ShareClient.cs')]
    refs = ['/reference:' + name + '.dll' for name in (
        'System.Web.Extensions', 'System.Security', 'System.Windows.Forms',
        'System.Drawing', 'System.Net.Http', 'System.IO.Compression')]
    subprocess.run([str(csc), '/nologo', '/target:library', '/platform:x64', '/optimize+',
                    *refs, '/out:' + str(stage / 'Sharing.dll'),
                    *map(str, common), str(source / 'SharingWindow.cs'), str(source / 'ReceiptInstallerWindow.cs'), str(source / 'MetroChrome.cs'), str(source / 'ReceiptFolderPicker.cs')], check=True)
    icon_bytes = (stage / 'App.ico').read_bytes()
    frames = [struct.unpack_from('<BBBBHHII', icon_bytes, 6 + 16*i) for i in range(struct.unpack_from('<H', icon_bytes, 4)[0])]
    frame = max(frames, key=lambda row: (row[0] or 256) * (row[1] or 256))
    png = icon_bytes[frame[7]:frame[7]+frame[6]]
    assert png.startswith(b'\x89PNG\r\n\x1a\n')
    (stage / 'sharing-icon.png').write_bytes(png)
    payload = root / 'build/agent-payload.zip'
    files = {name: stage / name for name in ('GuiBackend.ps1', 'InstalledGames.ps1')}
    files['SharingBackend.ps1'] = source / 'SharingBackend.ps1'
    for name in ('Core.ps1', 'games.json'):
        files['backend/' + name] = stage / 'backend' / name
    for name in ('FileHash.ps1', 'PublicWam.ps1', 'receipt-public.cer'):
        rel = 'backend/runtime/receipt-support/' + name
        files[rel] = stage / rel
    with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, file in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, file.read_bytes())
    exe = stage / 'GFW8LG-Agent.exe'
    subprocess.run([str(csc), '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
                    *refs, '/win32icon:' + str(stage / 'App.ico'),
                    '/resource:' + str(payload) + ',GFW8.Payload', '/out:' + str(exe),
                    *map(str, common), str(source / 'Agent.cs'), str(source / 'AgentOperations.cs'), str(source / 'SharingActivity.cs'), str(source / 'AgentBundle.cs')], check=True)
    subprocess.run([str(exe), '--verify-bundle'], check=True)
    shutil.copy2(source / 'sharing-relay.json', stage / 'sharing-relay.json')
    return [stage / name for name in ('Sharing.dll', 'GFW8LG-Agent.exe', 'sharing-relay.json', 'sharing-icon.png')]
