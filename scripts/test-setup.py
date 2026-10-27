#!/usr/bin/env python3
"""Offline setup/export checks; no SDK download or API access."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


setup = module('avatar_setup', Path(__file__).with_name('setup.py'))
packaging = module('avatar_packaging', Path(__file__).with_name('package-source.py'))


class SourceReleaseTests(unittest.TestCase):
    def test_source_manifest_excludes_installed_sdk_models_and_private_data(self):
        names = {name for name, _ in packaging.source_files()}
        self.assertIn('Sources/AvatarBehavior/AvatarMemory.swift', names)
        self.assertIn('vendor/swift-cubism/Sources/CubismBridge/include/CubismBridge.h', names)
        self.assertIn('scripts/patches/cubism-metal-macos.patch', names)
        for name in names:
            self.assertFalse(name.startswith(('local-assets/', 'build/', '.build/', '.git/', 'memory_data/',
                                             'vendor/swift-cubism/Core/', 'vendor/swift-cubism/Sources/CubismFramework/')))
            self.assertFalse(name.endswith(('.moc3', '.a', '.dylib', '.model3.json', '.yaml', '.env')))

    def test_modified_sdk_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'sdk.zip'
            archive.write_bytes(b'not the pinned SDK')
            destination = root / 'unpacked'
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                setup.extract_verified(archive, destination)
            self.assertFalse(destination.exists())

    def test_archive_traversal_is_rejected_even_if_hash_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'sdk.zip'
            with zipfile.ZipFile(archive, 'w') as output:
                output.writestr('../outside', 'invalid')
            with patch.object(setup, 'SHA256', hashlib.sha256(archive.read_bytes()).hexdigest()):
                with self.assertRaisesRegex(ValueError, 'Unsafe path'):
                    setup.extract_verified(archive, root / 'unpacked')
            self.assertFalse((root / 'outside').exists())


if __name__ == '__main__':
    unittest.main()
