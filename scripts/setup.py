#!/usr/bin/env python3
"""Install a pinned Live2D SDK and Haru sample locally; never vendor them in Git."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '5-r.4.1'
URL = f'https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-{VERSION}.zip'
SHA256 = 'b71ec6bafc6578cce3b4cbbaa42a1cb51ae6eb477557932b02d22af957e733c7'
TERMS = [
    'https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html',
    'https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html',
    'https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html',
    'https://www.live2d.com/en/learn/sample/haru/',
    'https://www.live2d.com/en/sdk/license/',
]


def extract_verified(archive, target):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError(f'SDK checksum mismatch. Use the unmodified official {VERSION} ZIP; no files installed.')
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError('Unsafe path or symbolic link in SDK archive.')
        source.extractall(target)
    return target / f'CubismSdkForNative-{VERSION}'


def install(archive):
    package = ROOT / 'vendor/swift-cubism'
    with tempfile.TemporaryDirectory(prefix='live2d-setup-') as staging:
        sdk = extract_verified(archive, Path(staging))
        framework = sdk / 'Framework'
        subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(ROOT / 'scripts/patches/cubism-metal-macos.patch')], cwd=framework, check=True)
        core = Path(staging) / 'prepared-core'
        slice_dir = core / 'Live2DCubismCore.xcframework/macos-arm64_x86_64'
        (slice_dir / 'Headers').mkdir(parents=True)
        shutil.copy2(sdk / 'Core/include/Live2DCubismCore.h', slice_dir / 'Headers/Live2DCubismCore.h')
        subprocess.run(['xcrun', 'lipo', '-create', str(sdk / 'Core/lib/macos/arm64/libLive2DCubismCore.a'),
                        str(sdk / 'Core/lib/macos/x86_64/libLive2DCubismCore.a'), '-output', str(slice_dir / 'libLive2DCubismCore.a')], check=True)
        metadata = {'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0', 'AvailableLibraries': [{
            'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': 'libLive2DCubismCore.a',
            'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64', 'x86_64'], 'SupportedPlatform': 'macos'}]}
        (slice_dir.parent / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        for name, source in [('LICENSE.md', sdk / 'Core/LICENSE.md'), ('SDK-LICENSE.md', sdk / 'LICENSE.md'),
                             ('SDK-NOTICE.md', sdk / 'NOTICE.md'), ('RedistributableFiles.txt', sdk / 'Core/RedistributableFiles.txt')]:
            shutil.copy2(source, core / name)
        haru = sdk / 'Samples/Resources/Haru'
        # Haru's prerecorded voice has separate restrictions and is not used by this app.
        shutil.rmtree(haru / 'sounds', ignore_errors=True)
        manifest = haru / 'Haru.model3.json'
        data = json.loads(manifest.read_text())
        for motions in data['FileReferences'].get('Motions', {}).values():
            for motion in motions:
                motion.pop('Sound', None)
        manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        (haru / 'LICENSES.md').write_text('Haru © Live2D Inc. Not MIT licensed.\n\n' + '\n'.join(TERMS) + '\n')
        for source, destination in [(framework, package / 'Sources/CubismFramework'), (core, package / 'Core'),
                                    (haru, ROOT / 'local-assets/Haru')]:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(source, destination)
    print('Installed Cubism SDK ' + VERSION + ' and Haru in ignored local folders.')
    print('Next: ./scripts/build.sh or ./scripts/run.sh')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--sdk-zip', type=Path, help=f'Official CubismSdkForNative-{VERSION}.zip downloaded after reviewing its terms')
    source.add_argument('--download', action='store_true', help='Download the pinned archive from Live2D')
    parser.add_argument('--accept-live2d-licenses', action='store_true', help='Confirm that you reviewed and accept the separate Live2D SDK and sample terms')
    args = parser.parse_args()
    if args.download:
        if not args.accept_live2d_licenses:
            parser.error('Review the Live2D terms, then explicitly add --accept-live2d-licenses:\n' + '\n'.join(TERMS))
        cache = ROOT / 'build/downloads'
        cache.mkdir(parents=True, exist_ok=True)
        archive = cache / f'CubismSdkForNative-{VERSION}.zip'
        if not archive.exists():
            temporary = archive.with_suffix('.download')
            try:
                with urllib.request.urlopen(URL, timeout=60) as response, temporary.open('wb') as output:
                    shutil.copyfileobj(response, output)
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    else:
        archive = args.sdk_zip.expanduser().resolve()
    install(archive)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit(f'Setup failed: {error}')
