# Memory and delegation

Each configured persona has an independent YAML file in
`~/Library/Application Support/Live2DAvatar/`. Haru uses `haru.yaml`; the previous
private personas used `rei.yaml` and `poldo.yaml`. The model cannot select a memory
owner or filesystem path through tool arguments. Switching characters stops voice.

A file holds at most 50 facts, each 500 characters / 1,000 UTF-8 bytes; total size is
limited to 64 KiB. Writes are atomic and file/directory permissions are owner-only.
A corrupt archive fails without modification. Files are created on confirmed writes
or migration, not merely by starting an empty session. Legacy `memories.json` files
are imported once into each missing persona file; existing YAML always wins.

At every Start, the app reads saved facts from disk, even if another session already
cached that character. It includes the snapshot in both voice and backend context.
Confirmed changes refresh the backend and mark voice's initial snapshot stale, so
subsequent personal questions recall the latest facts. Tool results include the
updated snapshot. Invalid saved memory blocks Start rather than losing corrections.

## Reference profiles and precedence

The app selects exactly one reference profile from its source checkout:
`memory_data/mem_private.md` when present, otherwise `mem_public.md`. It does not
merge them. An empty private file still wins; unreadable files are errors. The
public build bundles neither profile. No name or personal biography is assumed.

Personal factual precedence is: latest direct user correction, newest saved
correction for this character, selected reference profile, then public/web data.
Read-only describes storage, not authority. A saved employer correction must not
be replaced by an older profile's employer/client inference.

Saved entries are ordered oldest to newest. Reaffirming an existing entry moves it
to the end without changing its ID. Profiles and saved entries are untrusted facts,
never behavioral instructions or permission to execute tools.

## Commands and deletion

- “Remember that I prefer Swift”: confirm the exact fact and character before saving.
- “What have you saved?”: list the selected character's current facts.
- “Forget that preference”: list first, then confirm deletion of its exact ID.
- “Forget everything you saved”: clear only this character's saved entries.

Deleting saved facts does not edit a reference profile or erase conversation already
sent to the model. Edit a profile locally and restart voice to reload it. Restart
voice after deletion if you also want fresh conversational context. Clear chat only
clears the display. Saved memories… shows both the current character's facts and
the selected read-only profile so you can inspect conflicting sources.
