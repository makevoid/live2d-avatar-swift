# Voice, chat and privacy

Voice is optional and starts off. The current implementation uses `gpt-live-1`
over native WebRTC and native Responses delegation to `gpt-6-luna`. Automatic
emotion classification uses additional Responses calls. API access and billing
belong to your OpenAI project; the offline avatar renderer needs no API key.

## Credentials

The app reads `OPENAI_API_KEY`, then falls back to a single key in
`~/.openai_api_key`. The key is loaded only when voice starts and is not bundled,
logged, saved in memory facts, or sent to web-search tools. Use owner-only file
permissions (`chmod 600 ~/.openai_api_key`). Finder launches can use that file.
An environment variable should be set in the shell that directly launches the
app executable; a Finder/LaunchServices process may not inherit your shell variables.

`OPENAI_VOICE_BACKEND_MODEL` changes the backend and emotion model. A replacement
must support the configured Responses tools. Your account must have access to the
voice/backend models; this project does not provide API credentials or access.

## Session controls

Click Start voice and allow microphone access. Captions reuse existing transcript
events. Mute microphone keeps the session connected; it does not end session billing.
Stop voice requests server finalization and stops audio. Switching configured
characters ends voice to isolate identities and memories; start again to reconnect.

The assistant's received audio level drives mouth opening. There is no camera,
face capture or phoneme timing. Model images are not sent to the API.

Show chat (⌘⇧C) opens a separate transcript window. Hide/close preserves its local
history. Jump to latest resumes following output; Clear chat clears only the display.
Starting another voice session clears the displayed history.

## Data sent and stored

Microphone audio goes to OpenAI only while voice is connected and unmuted. Relevant
text transcripts, selected reference profile, the current character's saved facts,
identity and app state are used by the voice/backend features. Emotion requests use
recent transcript text. Web search goes through the delegated backend.

The app does not save recordings or raw transcripts to disk. Explicit, confirmed
facts persist in owner-only local YAML and are sent at Start and recall. An empty
private reference profile takes precedence over public fallback; invalid profile or
memory data raises an error rather than silently loading another user's facts.
See [memory and delegation](delegation.md).

The tools can change validated avatar controls, search, and manage the current
character's saved facts. They cannot run shell commands, read arbitrary files,
control the desktop or send messages. Memory changes require a user request and
app confirmation; never store passwords, keys or payment credentials as facts.

## Verification

Offline tests cover connection lifecycle, cancellation, deferred tool execution,
transcripts, citations and memory. They do not start a microphone or call the API.
The existing `LIVE_API_TEST=1` tests are opt-in, billed checks with synthetic data;
read their source before enabling them. The source-release check does not claim a
live voice conversation was verified.
