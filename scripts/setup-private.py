#!/usr/bin/env python3
"""Load an authenticated private assets checkout and build a personal app."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODELS = ('live2d_model', 'live2d_model_creature')


def checkout(repo, destination):
    if destination.exists():
        if not (destination / '.git').is_dir():
            raise ValueError(f'{destination} already exists but is not a Git checkout; nothing was replaced.')
        if repo:
            origin = subprocess.check_output(['git', '-C', str(destination), 'remote', 'get-url', 'origin'], text=True).strip()
            if origin != repo:
                raise ValueError('Existing private checkout has a different origin; nothing was replaced.')
        return
    if not repo:
        raise ValueError('First run: set PRIVATE_ASSETS_REPO to your private Git SSH URL, or pass --repo.')
    if repo.startswith('-'):
        raise ValueError('Invalid repository URL.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='private-clone-', dir=destination.parent) as temporary:
        staged = Path(temporary) / 'assets'
        subprocess.run(['git', 'clone', '--single-branch', '--', repo, str(staged)], check=True)
        staged.rename(destination)


def validate(assets):
    # Validate complete, self-contained runtime exports before linking profiles or building.
    with tempfile.TemporaryDirectory(prefix='private-model-check-') as temporary:
        for name in MODELS:
            source = assets / name
            if not source.is_dir() or source.is_symlink():
                raise ValueError(f'Missing private model directory: {name}')
            subprocess.run(['python3', str(ROOT / 'scripts/prepare-model.py'), str(source),
                            str(Path(temporary) / name)], check=True)
    profiles = assets / 'memory_data'
    if profiles.exists():
        if not profiles.is_dir() or profiles.is_symlink() or any(p.is_symlink() for p in profiles.rglob('*')):
            raise ValueError('Private profiles must be a regular, self-contained directory.')


def link_profiles(assets, root=ROOT):
    profiles = assets / 'memory_data'
    if not profiles.is_dir():
        return
    destination = root / 'memory_data'
    if destination.is_symlink() and destination.resolve() == profiles.resolve():
        return
    if destination.exists() or destination.is_symlink():
        raise ValueError('memory_data already exists; move it aside or merge its files into the private checkout first. Nothing was overwritten.')
    destination.symlink_to(os.path.relpath(profiles, root), target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=os.environ.get('PRIVATE_ASSETS_REPO'), help='Private Git SSH URL; needed only for the first clone')
    parser.add_argument('--sdk-zip', type=Path, default=os.environ.get('SDK_ZIP'), help='Optional official SDK ZIP for first-time dependency setup')
    parser.add_argument('--no-build', action='store_true', help='Only clone, validate and link the private assets')
    parser.add_argument('--launch', action='store_true', help='Open the personal app after building')
    args = parser.parse_args()
    if args.no_build and args.launch:
        parser.error('--no-build and --launch cannot be combined')
    assets = ROOT / 'local-assets/private'
    checkout(args.repo, assets)
    validate(assets)
    link_profiles(assets)
    if not args.no_build:
        if args.sdk_zip:
            subprocess.run(['python3', str(ROOT / 'scripts/setup.py'), '--sdk-zip', str(Path(args.sdk_zip).expanduser())], check=True)
        environment = dict(os.environ, PRIVATE_ASSETS_DIR=str(assets))
        subprocess.run(['bash', str(ROOT / 'scripts/build.sh')], cwd=ROOT, env=environment, check=True)
        if args.launch:
            subprocess.run(['open', str(ROOT / 'build/Live2D Avatar Private.app')], check=True)
    print('Private assets loaded locally. No files were uploaded; profiles are not bundled.')
    print('The existing checkout is reused on later runs. Pull updates inside local-assets/private when needed.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Private setup failed: {error}')
