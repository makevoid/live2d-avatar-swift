#!/usr/bin/env python3
"""Check private-profile isolation and preservation without network or model assets."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('private_setup', Path(__file__).with_name('setup-private.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class PrivateSetupTests(unittest.TestCase):
    def test_profile_link_is_ignored_and_editable_without_copying(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = root / 'local-assets/private'
            profiles = assets / 'memory_data'
            profiles.mkdir(parents=True)
            (profiles / 'mem_private.md').write_text('Synthetic profile')
            (root / '.gitignore').write_bytes((setup.ROOT / '.gitignore').read_bytes())
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            setup.link_profiles(assets, root)
            setup.link_profiles(assets, root)
            (root / 'memory_data/mem_private.md').write_text('Changed synthetic profile')
            self.assertEqual((profiles / 'mem_private.md').read_text(), 'Changed synthetic profile')
            for path in ['memory_data', 'local-assets/private/memory_data/mem_private.md']:
                subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', path], check=True)

    def test_existing_profile_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = root / 'local-assets/private'
            (assets / 'memory_data').mkdir(parents=True)
            (root / 'memory_data').mkdir()
            profile = root / 'memory_data/mem_private.md'
            profile.write_text('Keep this local edit')
            with self.assertRaisesRegex(ValueError, 'Nothing was overwritten'):
                setup.link_profiles(assets, root)
            self.assertEqual(profile.read_text(), 'Keep this local edit')

    def test_existing_non_checkout_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            marker = destination / 'keep.txt'
            marker.write_text('Keep')
            with self.assertRaisesRegex(ValueError, 'not a Git checkout'):
                setup.checkout('unused', destination)
            self.assertEqual(marker.read_text(), 'Keep')


if __name__ == '__main__':
    unittest.main()
