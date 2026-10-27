#!/usr/bin/env python3
"""Prepare bundled model copies, registering assets and adding manual face motions."""
import json
from pathlib import Path
import shutil
import sys

if len(sys.argv) != 3:
    raise SystemExit('Usage: prepare-model.py SOURCE_RUNTIME_DIRECTORY DESTINATION_DIRECTORY')
source, destination = (Path(value).expanduser().resolve() for value in sys.argv[1:3])
if not source.is_dir() or source == destination or source in destination.parents or destination in source.parents:
    raise SystemExit('Use an existing source and a separate destination directory outside the source tree.')
if any(path.is_symlink() for path in source.rglob('*')):
    raise SystemExit('Model folders must not contain symbolic links; use a self-contained runtime export.')
shutil.copytree(source, destination, dirs_exist_ok=True, ignore=shutil.ignore_patterns('.DS_Store'))
manifests = sorted(destination.glob('*.model3.json'))
if len(manifests) != 1:
    raise SystemExit('Expected exactly one .model3.json in the model folder.')
manifest = manifests[0]
data = json.loads(manifest.read_text())
refs = data['FileReferences']
refs.setdefault('Expressions', [
    {'Name': p.name.removesuffix('.exp3.json'), 'File': p.relative_to(destination).as_posix()}
    for p in sorted([*destination.glob('*.exp3.json'), *(destination / 'exp').glob('*.exp3.json')])
])
refs.setdefault('Motions', {'Actions': [
    # These one-shot accessory actions must reach and retain their authored final
    # values. Fading their weight to zero strands visibility controls mid-transition
    # (guan's Param43 stayed at ~0.205, leaving a translucent raised arm).
    {'File': p.relative_to(destination).as_posix(), 'FadeInTime': 0.3, 'FadeOutTime': 0.0}
    for p in sorted((destination / 'motions').glob('*.motion3.json'))
]})

# Animate the existing mouth rig without changing the original model or taking
# ownership of ParamMouthOpenY (the manual mouth-opening slider controls that).
# Constant target curves plus fade-in blend from the current pose, including when
# switching directly from Smile to Sad. Zero fade-out keeps the finished pose.
display_info = refs.get('DisplayInfo')
parameters = (
    json.loads((destination / display_info).read_text()).get('Parameters', [])
    if display_info and (destination / display_info).is_file() else []
)
# Both source manifests leave EyeBlink empty despite having working eyelid rigs.
# Enable natural blinking in the bundled copies only.
eye_ids = [p['Id'] for p in parameters if p['Id'] in ('ParamEyeLOpen', 'ParamEyeROpen')]
if eye_ids:
    groups = data.setdefault('Groups', [])
    blink = next((g for g in groups if g.get('Name') == 'EyeBlink'), None)
    if blink is None:
        groups.append({'Target': 'Parameter', 'Name': 'EyeBlink', 'Ids': eye_ids})
    elif not blink.get('Ids'):
        blink['Ids'] = eye_ids
if any(parameter['Id'] == 'ParamMouthForm' for parameter in parameters):
    face_directory = destination / 'avatar-motions'
    face_directory.mkdir(exist_ok=True)
    face_motions = []
    for name, value in [('Smile', 1.0), ('Sad', -1.0), ('Neutral mouth', 0.0)]:
        motion = {
            'Version': 3,
            'Meta': {
                'Duration': 0.6, 'Fps': 60.0, 'Loop': False,
                'AreBeziersRestricted': True, 'CurveCount': 1,
                'TotalSegmentCount': 1, 'TotalPointCount': 2,
                'UserDataCount': 0, 'TotalUserDataSize': 0,
            },
            'Curves': [{
                'Target': 'Parameter', 'Id': 'ParamMouthForm',
                'Segments': [0.0, value, 0, 0.6, value],
            }],
        }
        path = face_directory / f'{name}.motion3.json'
        path.write_text(json.dumps(motion, indent=2) + '\n')
        face_motions.append({
            'File': path.relative_to(destination).as_posix(),
            'FadeInTime': 0.35, 'FadeOutTime': 0.0,
        })
    refs['Motions']['Face'] = face_motions

paths = [refs['Moc'], *refs['Textures']]
paths += [refs[k] for k in ('Physics', 'Pose', 'DisplayInfo', 'UserData') if refs.get(k)]
paths += [e['File'] for e in refs.get('Expressions', [])]
paths += [m['File'] for group in refs.get('Motions', {}).values() for m in group]
for path in paths:
    resolved = (destination / path).resolve()
    if Path(path).is_absolute() or '..' in Path(path).parts or not resolved.is_relative_to(destination):
        raise SystemExit(f'Unsafe model resource path: {path}')
    if not resolved.is_file():
        raise SystemExit(f'Missing model resource: {path}')
manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
print(f'Model ready: {len(refs["Textures"])} textures, {len(refs["Expressions"])} expressions, '
      f'{sum(map(len, refs["Motions"].values()))} motions')
