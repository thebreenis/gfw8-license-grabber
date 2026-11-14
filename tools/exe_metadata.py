"""Generate and verify Explorer version resources for user-facing executables."""
from pathlib import Path
import json
import os
import re
import subprocess

CREDIT = 'Alec Breen | TheBreenis'


def assembly_info(path, product, description, version):
    assert re.fullmatch(r'\d+\.\d+\.\d+', version)
    values = {
        'AssemblyTitle': product,
        'AssemblyDescription': description,
        'AssemblyProduct': product,
        'AssemblyCompany': CREDIT,
        'AssemblyCopyright': 'Copyright © 2026 ' + CREDIT,
        'AssemblyVersion': version + '.0',
        'AssemblyFileVersion': version + '.0',
        'AssemblyInformationalVersion': version,
    }
    Path(path).write_text('using System.Reflection;\n' + ''.join(
        '[assembly: %s(%s)]\n' % (key, json.dumps(value, ensure_ascii=False))
        for key, value in values.items()), encoding='utf-8')
    return Path(path)


def verify(exe, product, version):
    # Inspect the PE resource Windows Explorer reads, rather than source strings.
    literal = str(Path(exe).resolve()).replace("'", "''")
    command = ("[Diagnostics.FileVersionInfo]::GetVersionInfo('" + literal +
               "') | Select-Object FileVersion,ProductVersion,FileDescription,ProductName,CompanyName,LegalCopyright,OriginalFilename | ConvertTo-Json -Compress")
    ps = Path(os.environ['WINDIR']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    # Preserve the copyright glyph regardless of the console code page.
    command = '[Console]::OutputEncoding=[Text.UTF8Encoding]::new();' + command
    result = subprocess.run([str(ps), '-NoProfile', '-Command', command],
                            check=True, capture_output=True)
    details = json.loads(result.stdout.decode('utf-8-sig'))
    assert details['FileVersion'] == version + '.0', details
    assert details['ProductVersion'] == version, details
    assert details['FileDescription'] == details['ProductName'] == product, details
    assert details['CompanyName'] == CREDIT, details
    assert details['LegalCopyright'] == 'Copyright © 2026 ' + CREDIT, details
    assert details['OriginalFilename'] == Path(exe).name, details
    return {'file': str(Path(exe).resolve()), **details}
