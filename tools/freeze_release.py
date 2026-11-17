"""Freeze verified local EXEs and allowlisted source. Never publishes or overwrites."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import tempfile
import zipfile
import package_policy

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def freeze(root, destination):
    root = Path(root).resolve()
    destination = Path(destination).resolve()
    dist = root / 'dist'
    record = json.loads((dist / 'BUILD-PROVENANCE.json').read_text(encoding='utf-8'))
    if record['inputs'] != package_policy.hashes(root, 'source'):
        raise ValueError('Source changed after build. Rebuild before freezing a release.')
    for name, expected in record['artifacts'].items():
        if Path(name).name != name or sha((dist / name).read_bytes()) != expected:
            raise ValueError('Built artifact changed after verification: ' + name)
    # The release identity is the version pair. It is created atomically and immutable.
    destination.mkdir(parents=True, exist_ok=True)
    final = destination / ('GUI' + record['guiVersion'] + '-CLI' + record['cliVersion'])
    if final.exists():
        raise FileExistsError('Frozen version already exists. Use a new version; nothing was overwritten: ' + str(final))
    with tempfile.TemporaryDirectory(prefix='.freeze-', dir=destination) as scratch:
        stage = Path(scratch)
        for name in record['artifacts']:
            shutil.copy2(dist / name, stage / name)
        # Only portable file details are distributed, not local absolute paths.
        details = json.loads((dist / 'FILE-DETAILS.json').read_text(encoding='utf-8'))
        for row in details:
            row['file'] = Path(row['file']).name
        (stage / 'FILE-DETAILS.json').write_text(json.dumps(details, indent=2) + '\n', encoding='utf-8')
        shutil.copy2(dist / 'BUILD-PROVENANCE.json', stage / 'BUILD-PROVENANCE.json')
        source = {p.relative_to(root).as_posix():p.read_bytes() for p in package_policy.inputs(root, 'source')}
        source_name = 'GFW8-License-Grabber-Source-GUI' + record['guiVersion'] + '-CLI' + record['cliVersion'] + '.zip'
        package_policy.write_zip(stage / source_name, source)
        (stage / 'SHA256SUMS.txt').write_text(''.join(sha(p.read_bytes()) + '  ' + p.name + '\n'
            for p in sorted(stage.iterdir()) if p.is_file()), encoding='ascii')
        # os.rename fails rather than replacing an existing destination on Windows.
        stage.rename(final)
    return final


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=ROOT / 'dist/releases')
    args = parser.parse_args()
    print(freeze(ROOT, args.destination))
