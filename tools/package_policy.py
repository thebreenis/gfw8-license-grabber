"""Explicit, source-controlled packaging inputs. Never discover runtime inputs by glob."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import zipfile


def manifest(root):
    return json.loads((Path(root) / 'tools/package-inputs.json').read_text(encoding='utf-8'))


def checked_file(root, name):
    relative = PurePosixPath(name)
    if relative.is_absolute() or '..' in relative.parts or '\\' in name or ':' in name:
        raise ValueError('Unsafe package input: ' + name)
    root = Path(root).resolve()
    file = root.joinpath(*relative.parts)
    if file.resolve() != file.absolute() or not file.is_file():
        raise ValueError('Missing or linked package input: ' + name)
    if root not in file.resolve().parents:
        raise ValueError('Package input left checkout: ' + name)
    return file


def inputs(root, group):
    names = manifest(root)[group]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate input in ' + group)
    return [checked_file(root, name) for name in names]


def write_zip(path, files):
    """files maps safe relative archive names to bytes, with fixed metadata/order."""
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            relative = PurePosixPath(name)
            if relative.is_absolute() or '..' in relative.parts or '\\' in name or ':' in name:
                raise ValueError('Unsafe archive member: ' + name)
            item = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.create_system = 0
            item.external_attr = 0o600 << 16
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Archive CRC verification failed')


def hashes(root, group):
    root = Path(root).resolve()
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in inputs(root, group)}
