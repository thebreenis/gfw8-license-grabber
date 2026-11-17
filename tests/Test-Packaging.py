"""Adversarial offline checks for shipping inputs, dependency integrity and release freezing."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import package_policy
import runtime_layout
import deterministic_build
import freeze_release


class Packaging(unittest.TestCase):
    def test_runtime_ignores_new_source_and_staging_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'source'
            stage = Path(folder) / 'stage'
            (root / 'tools').mkdir(parents=True)
            (root / 'backend').mkdir()
            (stage / 'backend').mkdir(parents=True)
            (root / 'tools/package-inputs.json').write_text(json.dumps({'backend':['backend/Core.ps1'], 'ui':[]}))
            (root / 'backend/Core.ps1').write_text('expected')
            (stage / 'backend/Core.ps1').write_text('expected')
            (root / 'backend/unexpected-account-data.json').write_text('DO NOT SHIP')
            (stage / 'backend/old-token.txt').write_text('DO NOT SHIP')
            files = runtime_layout.prepare(root, stage)
            self.assertEqual([p.relative_to(stage).as_posix() for p in files], ['backend/Core.ps1'])

    def test_missing_and_escaping_inputs_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for path in ['../outside','/absolute','x\\y','C:/outside','missing']:
                with self.assertRaises(ValueError):
                    package_policy.checked_file(root, path)

    def test_dependency_tamper_fails_before_signature_check(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'tools').mkdir()
            (root / 'dependency.dll').write_bytes(b'tampered')
            (root / 'tools/dependencies.json').write_text(json.dumps({'components':[
                {'path':'dependency.dll','sha256':hashlib.sha256(b'original').hexdigest()}]}))
            with self.assertRaisesRegex(ValueError, 'Dependency hash mismatch'):
                deterministic_build.verify_dependencies(root)

    def test_zip_is_order_timestamp_and_location_independent(self):
        with tempfile.TemporaryDirectory() as folder:
            one, two = Path(folder)/'one.zip', Path(folder)/'two.zip'
            package_policy.write_zip(one, {'z':b'two','a':b'one'})
            package_policy.write_zip(two, {'a':b'one','z':b'two'})
            self.assertEqual(one.read_bytes(),two.read_bytes())

    def test_unpinned_runtime_binary_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'tools').mkdir()
            (root/'tools/dependencies.json').write_text('{"components":[]}')
            (root/'tools/package-inputs.json').write_text('{"backend":["backend/new.dll"]}')
            with patch.object(deterministic_build,'powershell_records',return_value=[]):
                with self.assertRaisesRegex(ValueError,'dependency pin'):
                    deterministic_build.verify_dependencies(root)

    def test_invalid_signature_fails_even_when_hash_matches(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'tools').mkdir()
            (root/'vendor.dll').write_bytes(b'fixture')
            (root/'tools/dependencies.json').write_text(json.dumps({'components':[
                {'path':'vendor.dll','sha256':hashlib.sha256(b'fixture').hexdigest(),'requireMicrosoftSignature':True}]}))
            with patch.object(deterministic_build,'powershell_records',return_value=[
                {'name':'vendor.dll','signature':'HashMismatch','signer':'O=Microsoft Corporation'}]):
                with self.assertRaisesRegex(ValueError,'signature did not validate'):
                    deterministic_build.verify_dependencies(root)

    def test_source_allowlist_covers_tracked_sources_and_no_generated_outputs(self):
        names=package_policy.manifest(ROOT)['source']
        for name in names:
            self.assertFalse(any(part in {'build','dist','.git','.wrangler','node_modules','__pycache__'} for part in Path(name).parts))
        package_policy.inputs(ROOT,'source')

    def test_freeze_refuses_replacement_and_changed_source_or_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'repo';out=Path(folder)/'frozen'
            (root/'tools').mkdir(parents=True);(root/'dist').mkdir()
            (root/'source.txt').write_text('source')
            (root/'tools/package-inputs.json').write_text(json.dumps({'source':['source.txt']}))
            (root/'dist/app.exe').write_bytes(b'executable fixture')
            record={'guiVersion':'1.0.0','cliVersion':'1.0.0','inputs':package_policy.hashes(root,'source'),
                    'artifacts':{'app.exe':hashlib.sha256(b'executable fixture').hexdigest()}}
            (root/'dist/BUILD-PROVENANCE.json').write_text(json.dumps(record))
            (root/'dist/FILE-DETAILS.json').write_text('[]')
            frozen=freeze_release.freeze(root,out)
            self.assertTrue((frozen/'app.exe').is_file())
            with self.assertRaises(FileExistsError):freeze_release.freeze(root,out)
            (root/'source.txt').write_text('changed')
            with self.assertRaisesRegex(ValueError,'Source changed'):freeze_release.freeze(root,out)
            (root/'source.txt').write_text('source')
            (root/'dist/app.exe').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'artifact changed'):freeze_release.freeze(root,out)


if __name__ == '__main__':
    unittest.main()
