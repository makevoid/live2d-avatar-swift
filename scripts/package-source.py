#!/usr/bin/env python3
"""Create a source-only release ZIP using an explicit allowlist, never Git history."""
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ['.gitignore', 'AGENTS.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md',
         'Package.swift', 'Package.resolved', 'Rakefile', 'App/Info.plist', 'App/AppIcon.icns', 'App/AppIcon.png',
         'vendor/swift-cubism/Package.swift', 'vendor/swift-cubism/LICENSE', 'vendor/swift-cubism/LOCAL_CHANGES.md']
TREES = {
    'Sources': {'.swift'}, 'Tests': {'.swift'}, 'scripts': {'.py', '.sh', '.patch'}, 'doc': {'.md'},
    'vendor/swift-cubism/Sources/Cubism': {'.swift'},
    'vendor/swift-cubism/Sources/CubismBridge': {'.m', '.mm', '.h', '.hpp'},
    'vendor/swift-cubism/Tests': {'.swift'},
}
IMAGES = ['doc/images/app-window.png', 'doc/images/haru.png', 'doc/images/controls.png',
          'doc/images/rei.png', 'doc/images/poldo.png']


def source_files():
    names = set(FILES)
    names.update(name for name in IMAGES if (ROOT / name).is_file())
    for folder, suffixes in TREES.items():
        for path in (ROOT / folder).rglob('*'):
            if path.is_symlink():
                raise ValueError(f'Source export refuses symbolic link: {path.relative_to(ROOT)}')
            if path.is_file() and path.suffix in suffixes:
                names.add(path.relative_to(ROOT).as_posix())
    for name in sorted(names):
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Missing or linked source file: {name}')
        data = path.read_bytes()
        if path.suffix not in {'.png', '.icns'} and re.search(rb'sk-[A-Za-z0-9_-]{24,}', data):
            raise ValueError(f'Possible credential in {name}; no archive created.')
        yield name, data


def main():
    files = list(source_files())
    destination = ROOT / 'build/live2d-avatar-source.zip'
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.tmp')
    manifest = {'sdkAndModelsIncluded': False, 'gitHistoryIncluded': False,
                'files': {name: hashlib.sha256(data).hexdigest() for name, data in files}}
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in files:
            info = zipfile.ZipInfo('live2d-avatar/' + name)
            info.external_attr = (0o100755 if name.endswith(('.py', '.sh')) else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
        archive.writestr('live2d-avatar/SOURCE_MANIFEST.json', json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    temporary.replace(destination)
    print(f'{destination}\n{len(files)} source/documentation files; no SDK, models, profiles, caches, bundles or Git history.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Source packaging failed: {error}')
