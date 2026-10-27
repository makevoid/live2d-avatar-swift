# Add and use Live2D models

A model is an independent licensed asset. Obtain it from its creator and keep the
original download unchanged. Buying or downloading a model does not automatically
give permission to redistribute its files or a bundle containing them.

## Required runtime files

Export for Cubism SDK from Cubism Editor, or use a creator-supplied runtime folder:

```text
MyModel/
  MyModel.model3.json
  MyModel.moc3
  MyModel.2048/
    texture_00.png
  MyModel.physics3.json       # if referenced
  MyModel.pose3.json          # if referenced
  MyModel.cdi3.json           # display/parameter metadata, recommended
  expressions/
    smile.exp3.json
  motions/
    idle.motion3.json
```

There must be exactly one `.model3.json` at the selected folder's root. Every
resource referenced by `FileReferences` must exist at its relative path. Filenames
are case-sensitive on some filesystems. A `.cmo3` editor project must be exported
first. `.vtube.json` is VTube Studio configuration, not a runtime model manifest.
The pinned SDK must support the export version used by your model.

## Try a model without changing the app

Build the application once, then prepare a local copy:

```sh
mkdir -p local-assets/custom
python3 scripts/prepare-model.py "/path/to/MyModel/runtime" "local-assets/custom/MyModel"
"build/Live2D Avatar.app/Contents/MacOS/Live2DAvatar" \
  --model "$PWD/local-assets/custom/MyModel"
```

Quit any earlier app process first to avoid confusing two windows. Use absolute
paths when launching from outside the repository. The original model remains
unchanged; `local-assets/` is ignored and excluded from source archives.

Preparation registers loose expression files at the root or in `exp/` when no
expression list exists, and loose motions in `motions/` when no motion groups
exist. For other folder layouts, add references to the model manifest yourself.
Existing authored expression and motion references are preserved.

Models whose display metadata lists `ParamMouthForm` receive Smile, Sad and Neutral
mouth motions. Missing EyeBlink registrations are repaired when that metadata lists
the standard eye parameters. Mouth opening uses `ParamMouthOpenY`; rigs with different
parameter names require a bridge/behavior mapping. A `.moc3` contains the rig itself;
this app cannot create deformations that the artist did not author.

## Expressions and motions

The UI reads the model's manifest. Custom expression names appear as supplied.
VTube Studio hotkeys, tracking configuration and plugins are not imported. Authored
motions may loop or fade out; generated Face motions intentionally hold their final
mouth shape. Automatic emotions use only parameters actually present in the rig.

An unregistered custom model works with rendering, authored expressions/motions,
pointer input and generic voice instructions. Character-specific memory and
procedural emotions require registering a persona as described below. Do not assume
a model looks like Haru or another built-in persona.

## Add a configured character to the selector

For a maintained integration, make these code changes in your fork:

1. Add an `AvatarPersona` case in `Sources/AvatarBehavior/AvatarPersona.swift` with a
   unique stable `memoryKey`, name, voice and accurate identity description. Add its
   default pose/expression descriptions in `AvatarExpression.swift`. Never reuse
   another person's memory key for an unrelated character.
2. Add a `BundledAvatar` case in `AvatarRenderer.swift`: its relative bundle directory,
   exact manifest filename, display title, persona and creator credits. The selector
   filters this catalog to files actually present in the bundle.
3. Add an explicit preparation command in `scripts/build.sh` to copy that model from
   an ignored local folder into its own resource directory. Build always recreates
   resources, so additions must be scripted. Keep Haru if you want it available too.
4. Set suitable zoom/pan in `resetView()` and map supported facial parameters. Do not
   copy model-specific mesh IDs, tears or costume switches from a different rig.
5. Run the GPU checks on the added model, inspect the images and verify expression,
   motion, speech-mouth and memory isolation behavior. Include clear creator credits.

The repository retains descriptors for two earlier private development models so
their bridge/behavior code remains understandable. Their model files are absent,
so they do not appear in the default selector and are not needed for the public build.

For a local test of an unregistered model:

```sh
MTL_DEBUG_LAYER=1 "build/Live2D Avatar.app/Contents/MacOS/Live2DAvatar" \
  --model "$PWD/local-assets/custom/MyModel" --smoke-test "$PWD/build/custom-verification"
```

Some rigs lack the standard pointer or mouth parameters and may need custom
verification. The default Haru test covers the shipped integration; it cannot prove
that every artist's rig is compatible.

## Sharing

Commit your code and model installation instructions, not the model files. Use an
official creator download link and retain its license. Do not publish model textures,
editor projects, or purchased models in Git history. Rendered screenshots also have
artwork terms; permission to display a character is distinct from permission to
redistribute its editable/runtime data. The app's MIT license does not cover them.
