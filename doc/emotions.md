# Emotions and expressions

Haru supports nine procedural emotions: happy, excited, playful, sad, hurt,
apologetic, curious, surprised and neutral. `EmotionPose` produces bounded curves
for standard mouth, eye, brow and head parameters; only parameters present in the
compiled rig are applied. Some poses therefore look different between models.

Automatic emotions begin enabled. Transcript meaning chooses reactions while
voice is active. Manual expressions/motions disable automatic emotion updates so
that a selected look can hold. Voice expression handling uses the current catalog.
The avatar's audio-driven mouth opening remains independent of these poses.

Authored expressions are read from the manifest (Haru F01–F08), and appear under
their authored names. The project does not claim that every model has tears, hearts,
or the costume switches used by earlier private development models. Add accurate
expression descriptions with a new persona; see [models](models.md).
