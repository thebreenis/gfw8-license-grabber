"""Local Roslyn compilation and portable provenance; no downloads or package restore."""
from pathlib import Path
import hashlib
import json
import os
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def powershell_records(paths):
    literals = ','.join("'" + str(Path(p).resolve()).replace("'", "''") + "'" for p in paths)
    script = ("$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); @(" + literals +
              ") | ForEach-Object {$s=Get-AuthenticodeSignature -LiteralPath $_;"
              "$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($_);"
              "[pscustomobject]@{name=[IO.Path]::GetFileName($_);version=$v.FileVersion;"
              "signature=[string]$s.Status;signer=$s.SignerCertificate.Subject}} | ConvertTo-Json -Compress")
    ps = Path(os.environ['WINDIR']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    environment = dict(os.environ)
    # Do not let a calling PowerShell 7 session redirect Windows PowerShell's modules.
    environment['PSModulePath'] = str(ps.parent / 'Modules')
    result = subprocess.run([str(ps), '-NoProfile', '-Command', script], check=True, capture_output=True, env=environment)
    records = json.loads(result.stdout.decode('utf-8-sig'))
    return records if isinstance(records, list) else [records]


def verify_dependencies(root):
    from package_policy import checked_file
    inventory = json.loads((root / 'tools/dependencies.json').read_text(encoding='utf-8'))
    records = []
    signed = []
    for item in inventory['components']:
        path = checked_file(root, item['path'])
        if sha(path) != item['sha256']:
            raise ValueError('Dependency hash mismatch: ' + item['path'])
        for name, expected in item.get('sourceHashes', {}).items():
            if sha(checked_file(root, name)) != expected:
                raise ValueError('Dependency source changed; review and update provenance: ' + name)
        records.append(dict(item))
        if item.get('requireMicrosoftSignature'):
            signed.append(path)
    for record in powershell_records(signed):
        if record['signature'] != 'Valid' or 'O=Microsoft Corporation' not in (record['signer'] or ''):
            raise ValueError('Microsoft dependency signature did not validate: ' + record['name'])
    from package_policy import manifest
    pinned = {r['path'] for r in records if r['path'].startswith('backend/')}
    shipped = {name for name in manifest(root)['backend'] if Path(name).suffix.lower() in ('.exe','.dll','.cer')}
    if pinned != shipped:
        raise ValueError('Every shipped backend binary/certificate must have exactly one dependency pin.')
    return records


class Compiler:
    def __init__(self, root):
        self.root = Path(root).resolve()
        explicit = os.environ.get('GFW8_CSC')
        if explicit:
            self.path = Path(explicit).resolve()
        else:
            vswhere = Path(os.environ.get('ProgramFiles(x86)', '')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
            if not vswhere.is_file():
                raise RuntimeError('Install Visual Studio Build Tools with Roslyn, or set GFW8_CSC to a local Roslyn csc.exe.')
            install = subprocess.check_output([str(vswhere), '-latest', '-products', '*',
                '-requires', 'Microsoft.Component.MSBuild', '-property', 'installationPath'], text=True).strip()
            self.path = Path(install) / 'MSBuild/Current/Bin/Roslyn/csc.exe'
        if not self.path.is_file():
            raise RuntimeError('Roslyn csc.exe was not found. Install the MSBuild tools or set GFW8_CSC.')
        libraries = sorted(self.path.parent.glob('*.dll'))
        records = powershell_records([self.path] + libraries)
        for record in records:
            if record['signature'] != 'Valid' or 'O=Microsoft Corporation' not in (record['signer'] or ''):
                raise RuntimeError('C# compiler and its local libraries must have valid Microsoft signatures: ' + record['name'])
        record = records[0]
        version = subprocess.check_output([str(self.path), '/version'], text=True).strip()
        self.tool = {'name':'Roslyn csc.exe', 'sha256':sha(self.path), 'version':version,
                     'signature':record['signature'], 'signer':record['signer'],
                     'libraries':{p.name:sha(p) for p in libraries}}
        config = self.path.with_name(self.path.name + '.config')
        if config.is_file():
            self.tool['configurationSha256'] = sha(config)
        self.framework = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319'
        self.references = {}
        self.commands = []

    def compile(self, arguments, references):
        refs = []
        for name in sorted(set(['mscorlib.dll', 'System.dll', 'System.Core.dll'] + list(references))):
            path = Path(name) if Path(name).is_absolute() else self.framework / name
            if not path.is_file():
                raise RuntimeError('Missing Framework reference: ' + name)
            self.references[path.name] = sha(path)
            refs.append('/reference:' + str(path))
        common = ['/nologo','/noconfig','/nostdlib+','/deterministic+','/optimize+',
                  '/platform:x64','/langversion:5','/utf8output', '/pathmap:' + str(self.root) + '=/_/src']
        command = [str(self.path)] + common + refs + list(arguments)
        subprocess.run(command, cwd=self.root, check=True)
        self.commands.append([arg.replace(str(self.root), '<checkout>').replace(str(self.framework), '<framework>')
                              .replace(str(self.path), '<csc>') for arg in command])

    def provenance(self):
        return {'compiler':self.tool, 'frameworkReferences':dict(sorted(self.references.items())),
                'compileCommands':self.commands, 'deterministic':True,
                'pythonVersion':__import__('platform').python_version(),
                'zlibVersion':__import__('zlib').ZLIB_RUNTIME_VERSION}
