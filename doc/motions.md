# Generated mouth poses

`prepare-model.py` works on a copy of the original model. When display metadata
lists `ParamMouthForm`, it adds Smile (1), Sad (-1) and Neutral mouth (0) under the
Face motion group. The curves blend for 0.35 seconds and hold their final pose
with zero fade-out. They do not take control of `ParamMouthOpenY`.

The same preparation fills missing EyeBlink registration from standard eye IDs,
and registers loose expressions/motions if the manifest has no existing list.
Existing authored motion groups, fade behavior and expression IDs are retained.
Do not infer behavior from parameter names alone: verify the compiled rig's limits
and inspect the result. Haru's GPU test covers all nine registered motions and
checks generated mouth-pose endpoints after the full duration.
