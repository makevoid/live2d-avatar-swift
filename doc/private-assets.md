# Personal assets in a separate private repository

Maintain application code in this repository. Keep licensed models and personal
reference profiles in a separate **private** repository that you control. No SDK,
API credentials, recorded conversations, or saved-character YAML files belong there.
The SDK is still installed through the official setup task. Existing character
memories stay in `~/Library/Application Support/Live2DAvatar/`.

The optional personal integration expects this layout:

```text
private-assets/
  live2d_model/           # original Bear Commander runtime folder for Rei
  live2d_model_creature/  # original F2U Red Panda runtime folder for Poldo
  memory_data/           # optional reference profiles, not saved chat memories
    mem_private.md
    mem_public.md
```

Keep the original filenames, texture folders, and creator notices intact. The
application already has descriptors and personas for these two models. Other
models use the [general model guide](models.md).

## First run

Install the SDK normally, then use your authenticated Git SSH URL:

```sh
PRIVATE_ASSETS_REPO=git@github.com:YOUR_ACCOUNT/YOUR_PRIVATE_ASSETS.git rake private
```

If the SDK is not installed yet, supply your downloaded official ZIP in the same task:

```sh
SDK_ZIP="$HOME/Downloads/CubismSdkForNative-5-r.4.1.zip" \
PRIVATE_ASSETS_REPO=git@github.com:YOUR_ACCOUNT/YOUR_PRIVATE_ASSETS.git rake private
```

Without Ruby/Rake:

```sh
python3 scripts/setup-private.py --repo git@github.com:YOUR_ACCOUNT/YOUR_PRIVATE_ASSETS.git --launch
```

The task clones only on the first run, verifies both runtime models, and creates an
ignored `memory_data` symlink to the private checkout. It refuses to overwrite an
existing profile directory. Merge any existing local profiles into the private
checkout yourself and move the old directory aside before repeating the task.
Edits through that symlink edit the private checkout, so they can be committed
there deliberately. Nothing is uploaded automatically.

## Daily use and updates

```sh
rake private
```

This builds and opens `build/Live2D Avatar Private.app`, with Rei selected at startup and Haru, Character/Rei,
and Creature/Poldo in the selector. It does not modify original model assets.
Prepared model copies belong only to that ignored personal app bundle.

Existing private checkouts are reused without resetting or pulling over local work.
To fetch updates explicitly, commit or stash your private edits first, then run:

```sh
git -C local-assets/private pull --ff-only
rake private
```

Use `python3 scripts/setup-private.py --no-build` to clone/link without building,
or omit `--launch` for a build without opening the app. Public `./scripts/build.sh`
continues to produce `build/Live2D Avatar.app` with Haru only. The two output bundles
are separate; don't redistribute the personal bundle containing licensed models.

## Release boundary

`local-assets/` and the entire `memory_data` path are ignored by Git. Source packaging
uses an allowlist and omits both even after a personal build. Profiles remain on
disk; neither app bundle contains them. Before starting voice, the app loads your
local reference profile and saved facts into the session as documented in
[voice and privacy](voice.md).

The original private development repository is a historical archive, not a remote
to merge into this clean application history. Future application fixes belong here;
asset/profile changes belong in the private asset repository.
