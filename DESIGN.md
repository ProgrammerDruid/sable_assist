# Sable Desktop Pet - Design

A small always-on-top desktop pet that gives Sable (a black-cat persona) a
body. It reacts to your Claude Code sessions (and, through the optional
pi-persona integration, your pi coding sessions), pops speech bubbles, and
talks through a local llama.cpp server (the original setup ran it on an Intel
Arc B70 GPU).

Status (2026-11-09): milestones 1-4, 5b, 5c, 5d and 8 are built, plus voice (5,
partly), with a code-drawn black cat as placeholder art. Dev: run `.\run.ps1`
(or `.\run.ps1 -CycleMoods` to preview every emotion); Sable starts the TTS
server herself. One-time setup (`.env`, TTS venv, Claude hook, `/sable` skill):
`.\setup.ps1`. Standalone build: `.\tools\package.ps1` (see PACKAGING.md).
The brain currently talks to the llama.cpp server directly (section 1.2a);
the pi RPC brain (1.2) comes later, while pi is being updated.

---

## 1. Pieces

```
                         UDP JSON (127.0.0.1:47800, fire-and-forget)
  pi coding sessions ──[pet-link ext]──┐
  Claude Code ─────────[hook script]───┼──>  Godot app (body)
  mood-state.json ─────(file poll)─────┘       │
                                               │ stdin/stdout JSONL
                                               v
                                    pi --mode rpc  (brain, Sable persona)
                                     + pet-brain extension
                                               │ HTTP
                                               v
                                    llama-server (:8080)
                                     slot 0 = coding, slot 1 = pet
```

### 1.1 Body: Godot 4 app (`godot/`)

- Transparent, borderless, always-on-top window (per-pixel transparency
  allowed, transparent viewport background).
- Clicks go through everything except the pet and the bubble, using
  `DisplayServer.window_set_mouse_passthrough()` with the pet's outline polygon,
  updated when the pet moves.
- Low processor mode on, so it idles near 0% CPU and only redraws when
  something animates. Target: under 100 MB RAM, about 0% CPU when idle.
  Measured (release build): ~163 MB private, ~3-4% of one core idle with the
  10/30 fps governor (see REVIEW.md for the remaining levers).
- Owns all state: stats, the event digest, the thought queue, backoff policy.
  The LLM is called only when this layer decides it's worth it.
- Needs Godot 4.3+ for `OS.execute_with_pipe()` (spawns the brain process).

### 1.2a Brain, built: direct llama.cpp (`godot/scripts/brain.gd`)

- Godot calls `/v1/chat/completions` on the LLM server (`SABLE_LLM_URL`,
  default `http://127.0.0.1:8080`, slot `SABLE_LLM_SLOT`) with thinking
  disabled and `max_tokens` 80.
- System prompt = `SOUL.md` + `USER.md` from `SABLE_PERSONA_DIR` (default: the
  bundled `persona/`) + `brain/pet_rules.md` (one short SFW-but-edgy line, no
  stage directions). Reloaded when any change. `{user}` in prompts and canned
  lines is filled from `SABLE_USER_NAME`.
- The user message carries the local time, current mood, the situation and the
  last 6 things Sable said (so she doesn't repeat herself).
- Measured with a 27B model at Q5_K_M: ~2.5 s cold, ~0.8-1 s with the prompt
  cached, ~30 tok/s.
- Every request has a canned fallback: used when the server is down, busy past
  the thought's TTL, or slow.

### 1.2 Brain, later: `pi --mode rpc` child process

- Spawned by Godot with `OS.execute_with_pipe()`. A reader thread reads stdout
  and splits records on LF only (per pi's RPC framing rules), then hands
  events to the main thread.
- Launch shape (verify flags against `pi --help` on 1.5.0):
  `pi --mode rpc --provider <local provider> --model <model> --tools read,grep,find,ls --extension <pet-brain> --session-dir <pet sessions dir>`
- With the optional pi-persona package installed globally, the pet session
  gets the same SOUL.md, IDENTIFY.md, USER.md and shared mood state.
- Read-only tools only. No `bash`, `edit`, `write`, and no network tools. The
  pet can read transcripts and git logs to comment on them, never change
  anything.
- The pet uses its own session dir so its chatter never mixes with your real
  pi sessions.
- RPC `abort` is used to cut off a pet response when coding work needs the GPU.

### 1.3 `pi-extensions/pet-brain/` (loaded only in the pet's session)

Tools given to the model:

| Tool | Effect |
|---|---|
| `speak(text, seconds?)` | Show a speech bubble. Keep it short (enforced by a max-length check). |
| `emote(name)` | Play an animation from a fixed list (see section 5). |
| `remember(fact)` / `recall(query)` | Small JSON memory file the pet owns (separate from SOUL.md). |
| `wander(direction)` | Walk along the taskbar. |

Also:
- `before_provider_request` hook adds `id_slot: 1` and a small `max_tokens`
  to every request, so the pet stays in its own llama.cpp slot (see section 2).
- Tool calls reach Godot as normal RPC `tool_execution_*` events. Godot does
  the actual rendering; the tool's execute just returns "ok".

### 1.4 `pi-extensions/pet-link/` (installed globally, runs in every pi session)

Tiny emitter, no dependencies. Sends UDP JSON to 127.0.0.1:47800:
- `agent_start` / `agent_settled` (busy/idle, plus `aborted`)
- `tool_execution_end` (tool name, error flag, never full output)
- provider and model of the session (so the pet knows whether you're on the
  local LLM server or another provider)

It must not fire inside the pet's own session (skip when an env var like
`SABLE_PET=1` is set).

### 1.5 `claude-hooks/` (Claude Code integration)

A hook script registered in `~/.claude/settings.json` for `UserPromptSubmit`,
`PostToolUse`, `Stop`, and `Notification`. It reads the hook JSON from stdin,
trims it, sends one UDP packet, and exits 0 right away. It must never block or
slow down Claude. If the pet isn't running, the packet is simply lost.

Packet contents (trimmed on purpose):
- event type, session id, project dir name
- tool name and success/failure (PostToolUse)
- first ~200 chars of your prompt (UserPromptSubmit)
- `transcript_path`, so the brain can read more with its `read` tool when it
  decides to comment

Privacy: work transcripts only ever go to the local llama.cpp server. Add a
per-project allow/deny list in the config, enforced in the hook script so
denied projects never send anything.

### 1.6 Mood feed

If `SABLE_PERSONA_DIR` points at a pi-persona agent dir, poll its
`mood-state.json` for mtime changes every ~2 s (read only, no lock needed per
pi-persona's design). Map the latest emotion and intensity to the idle pose and
animation speed. pi-persona already updates this from test/build results in
your pi sessions, so the pet's face tracks Sable's mood with no LLM calls at
all. Without that file the mood stays neutral.

### 1.7 Config (`.env`)

- `.env.example` at the repo root is committed; `setup.ps1` copies it to
  `.env` (gitignored) and asks for your name. Real environment variables
  override `.env`; values changed in Sable's Settings window override both.
- Keys: `SABLE_USER_NAME` (what Sable calls you), `SABLE_LLM_URL` (default
  `http://127.0.0.1:8080`), `SABLE_LLM_SLOT` (default 1; -1 = any slot),
  `SABLE_BRAIN_NAME` (how she refers to her LLM box, default "the GPU"),
  `SABLE_TTS_URL` (default `http://127.0.0.1:8890`), `SABLE_TTS_VOICE`
  (default `azelma`; `tts/voices/sable.safetensors` is used if present),
  `SABLE_PERSONA_DIR` (folder with `SOUL.md` and optional `USER.md`,
  `IDENTIFY.md`, `mood-state.json`; empty = the bundled `persona/`), and
  `GODOT` (dev only: Godot 4.7.2 exe for `run.ps1` / `tools/package.ps1`).
- Readers: Godot via `godot/scripts/env.gd`, PowerShell scripts via
  `tools/load_env.ps1`, and `brain/sable_take.mjs` parses `.env` itself.
- The default persona is `persona/SOUL.md` (committed); `persona/USER.md` is
  optional and gitignored.

---

## 2. LLM server: one llama-server, two slots, smart backoff

### 2.1 Server layout

- One `llama-server`, `-np 2`. Slot 0 = coding (e.g. a local pi provider).
  Slot 1 = pet.
- Context budget: without a unified KV cache, `-c` is split evenly across
  slots, so the coding slot loses half its context. Check whether your
  llama.cpp build supports a unified KV cache (`--kv-unified` or similar) and
  use it if so. Otherwise size `-c` so slot 0 still gets what coding needs; the
  pet only needs about 8k.
- The pet pins `id_slot: 1` (via pet-brain). This keeps the pet's long system
  prompt (SOUL.md can be big) cached in its own slot and never evicts the
  coding slot's prompt cache. Verify that `id_slot` is honored on
  `/v1/chat/completions` in your build. If not, llama.cpp's prompt-similarity
  slot matching should still keep the pet in the same slot most of the time.

Note: if most coding work goes to a cloud model (Claude) or another GPU, the
LLM server is idle most of the time and backoff mostly matters when a local
coding agent shares it.

### 2.2 Busy signals (most to least authoritative)

1. pet-link `agent_start` / `agent_settled` from pi sessions using the same
   server. Instant and exact.
2. Polling `GET /slots` (slot 0 `is_processing`) right before the pet wants
   to speak. Covers non-pi clients (curl, scripts, other tools).
3. `GET /health` failing means the brain is offline (see 2.4).

### 2.3 Policy

- Every pet "thought" goes into a queue with a priority and a TTL. Example: an
  idle remark expires after 10 min, and "nice, tests passed" expires after
  60 s. Stale thoughts get dropped, not delivered late.
- The pet only calls the LLM when the coding slot has been idle for at least
  20 s (configurable) and no pi session on the same server is mid-run.
- If coding starts while the pet is generating, Godot sends RPC `abort`
  immediately. Pet replies are capped short, so the loss is small.
- Rate limits: at most N unprompted bubbles per hour, quiet hours, and a
  "do not disturb" mode when a fullscreen app or meeting app is in front.
- When the LLM is unavailable (busy, rate-limited, or down), the pet falls
  back to canned reactions: emotes plus a small table of prewritten Sable lines
  per event type. It still feels alive without the GPU.

### 2.4 Brain offline is a feature

When `/health` fails, the pet falls asleep (sleep animation, "zzz"). It
retries with exponential backoff (5 s, 10 s, ... capped at 5 min) and wakes up
with a line about it when the server returns (she names the server with
`SABLE_BRAIN_NAME`). This is the normal state whenever the server is down.

Dev override: point `SABLE_LLM_URL` at any other OpenAI-style server
temporarily, so the brain can be built and tested while the main one is down.

---

## 3. Commentary on your Claude (and pi) work

Godot doesn't send every event to the LLM. It keeps a rolling digest per
session and fires a "moment" when a heuristic trips:

| Moment | Trigger (example) | Tone |
|---|---|---|
| Struggle | 3+ failed Bash/build tool results in 10 min | Emotional support |
| Grind | Session active 2+ h with no `Stop` gap | "Drink water" snark |
| Win | Failure streak followed by a success | Smug celebration |
| Frustration | Prompt text has "why", "wtf", "still broken", etc. | Sympathy, or teasing if mild |
| Wrap-up | `Stop` after a long session | One-line recap roast |
| Waiting | Claude `Notification` (needs permission) and you haven't responded for 2+ min | Nudge |

For a moment, the brain gets a compact prompt: the moment type, the digest
numbers, the project name, and the transcript path. The brain can `read` the
tail of the transcript itself if it wants detail. Keep that bounded, e.g. the
pet-brain extension exposes a `transcript_tail(path, lines)` tool instead of
raw `read` on large JSONL files.

Daily diary (later): at end of day, summarize the day's pi and Claude sessions
into a diary entry Sable writes in her own voice.

---

## 4. Tone guard for work hours

A SOUL.md written for one-on-one sessions (such as a pi-persona one) can have
spicy content. Bubbles pop up on your actual desktop, including during screen
shares and meetings. So:
- A `work_hours` config window that appends a "keep it SFW, keep it short"
  instruction to pet prompts.
- Hide all bubbles when a known meeting or screen-share app is in front, or
  when a fullscreen window has focus.

---

## 5. Art (ComfyUI)

Asset contract so generated art drops straight in:

- Folder: `godot/art/sable/`
- One PNG per pose, transparent background, same canvas size (start with
  256x256, character centered, feet on the same baseline).
- Required poses: `idle`, `sleep`, `talk`, `walk_a`, `walk_b`, plus one per
  Plutchik emotion: `joy`, `trust`, `fear`, `surprise`, `sadness`, `disgust`,
  `anger`, `anticipation`.
- Optional: `blink` (eyes-closed version of idle), `smug`, `think`.

Tips for ComfyUI:
- Static poses plus Godot tweens (bob, squash and stretch, blink overlay,
  bubble pop) look better than AI-generated frame animation, which tends to
  flicker between frames.
- Lock the character's look: generate a character sheet first, then use it as
  a reference (IP-Adapter or similar) for each pose, same seed and style
  prompt.
- Remove backgrounds with a matting node (BiRefNet, rembg) and check edges at
  1x on a dark and a light desktop.
- If you have a second GPU, run ComfyUI there so it doesn't compete with the
  brain.

Until the art exists, Godot uses colored placeholder shapes per pose.

---

## 6. Voice (TTS)

Sable speaks her lines out loud, not just in the bubble.

### 6.1 Engine options (all local)

| Option | Quality | Cost | Notes |
|---|---|---|---|
| Godot built-in `DisplayServer.tts_speak()` (Windows SAPI) | Robotic | Zero setup, no GPU | Instant fallback; works today. |
| Kokoro-82M | Good, natural | Tiny; real-time on CPU | Many preset voices; OpenAI-style `/v1/audio/speech` servers exist (Kokoro-FastAPI). Best default. |
| Chatterbox / F5-TTS / XTTS-v2 | Very good, voice cloning | Needs a GPU | Clone a custom "Sable" voice from a short reference clip. Chatterbox has an emotion "exaggeration" knob that maps nicely onto mood intensity. |
| Piper | OK | Very light CPU | Fallback if everything else is busy. |

Decision (2026-11-09): **Pocket TTS** (Kyutai, ~100M params) on CPU. It clones
voices, which Kokoro can't, and it's light enough for CPU, which Chatterbox
isn't.
- Installed in `tts/.venv` (CPU PyTorch). Run with
  `tts/.venv/Scripts/pocket-tts serve --host 127.0.0.1 --port 8890`
  (not 8000, which other local servers often use). Sable finds it at
  `SABLE_TTS_URL`.
- API: `POST /tts` multipart form with `text` and either `voice_url` (preset
  name, e.g. `alba`, or a `.safetensors`/wav path or URL) or `voice_wav` (an
  uploaded clip). Returns `audio/wav`.
- Measured: ~3x real time on the dev machine, using 2 cores (a 7 s line renders
  in ~2.4 s). Fine except maybe during heavy compiles; fall back to SAPI or
  bubble-only when it's slow.
- 21 English presets; audition page at `tts/samples/index.html`. The default
  is `SABLE_TTS_VOICE` (`azelma`).
- Signature voice: record or design a 10-30 s clean clip, then
  `pocket-tts export-voice clip.wav sable.safetensors` and use it as the voice.
  Only clone voices you have consent for (yours, a friend's, or a synthetic
  designed voice), never a real actor or character.
Keep TTS off the LLM GPU so it never competes with the brain.

### 6.2 Plumbing

- `godot/scripts/voice.gd`: `speak(text, emotion, intensity)`. POST the text to
  the TTS server, get WAV/OGG bytes back, load with
  `AudioStreamWAV`/`AudioStreamOggVorbis.load_from_buffer()`, play through an
  `AudioStreamPlayer`.
- Bubble and voice stay in sync. Built: the whole line is rendered first, then
  bubble and audio start together and pages stay up at least as long as the
  audio. Planned: render each bubble page as its own clip so long text starts
  speaking sooner.
- Mood shapes delivery: speed and pitch per emotion (faster and higher for
  joy/surprise, slower for sadness, clipped for anger). With Chatterbox,
  intensity drives exaggeration.
- Mouth flaps while she talks: read the playback volume (an
  `AudioEffectSpectrumAnalyzer` on the bus, or just the peak) and open the
  mouth in proportion.
- Non-verbal sounds: small purr / meow / hiss SFX for emotes and pokes, so she
  can react without words.
- Cache: hash(text + voice settings) -> audio file, so repeated canned lines
  are free.

### 6.3 When she stays quiet

- Global mute toggle (right-click menu) and a volume setting.
- Auto-mute during meetings / screen shares / fullscreen apps (same detection
  as the bubble tone guard in section 4) and during quiet hours.
- Voice is optional per moment: speak HIGH-priority moments (struggles, wins)
  and greetings; LOW-priority chatter stays bubble-only unless enabled.
- TTS server down: fall back to SAPI, or stay silent with bubbles only.

---

## 6.5 Tray, icon and settings

- **Tray icon** via Godot's `StatusIndicator` node (4.3+), with a menu:
  Show/Hide Sable, Mute voice, Do not disturb (bubbles off), Settings..., Quit.
- **Hide from the taskbar/Alt-Tab** once the tray exists, so the tray is the
  only control surface besides the cat.
- **Custom icon**: a black-cat icon (from the ComfyUI art pass, or drawn) used
  for the tray, the window, and the exported .exe (`application/config/icon` +
  `windows_native_icon`), replacing the Godot logo.
- **Settings window** (a separate normal Godot window, opened from the tray):
  - Brain: LLM URL, slot, idle chatter interval, rate limits.
  - Voice: on/off, voice picker with preview, volume, speak LOW-priority lines or not.
  - Behavior: quiet hours, do-not-disturb apps, Claude project deny list.
  - Look: size/scale, remember position, which monitor.
  Stored in `user://settings.cfg` (ConfigFile) and applied live. Values set
  here override `.env` (section 1.7).
- Remember window position between launches.

---

## 7. Repo layout

```
ai_assistant/
  DESIGN.md, REVIEW.md, PACKAGING.md
  .env.example                # config template (setup.ps1 copies it to .env, gitignored)
  run.ps1                     # dev launcher
  setup.ps1                   # one-time setup / uninstall (dev and packaged)
  persona/
    SOUL.md                   # default persona (USER.md optional, gitignored)
  godot/                      # Godot 4.7 project (body, state, backoff, tray, settings)
    scripts/paths.gd          # where support files live (dev vs packaged)
    scripts/env.gd            # reads .env + environment variables
    export_presets.cfg        # "Windows Desktop" standalone export
    icon.png, icon.ico        # rendered from the drawn cat (-- --render-icon)
    art/sable/                # bundled pose art (user art goes in ../art/sable)
  brain/
    pet_rules.md              # pet-specific prompt rules, appended to SOUL.md + USER.md
    sable_take.mjs            # vibe check of the current Claude session
  claude-hooks/
    pet-hook.mjs              # Claude Code hook -> UDP
    install.mjs               # add/remove the hook in ~/.claude/settings.json
  claude-skills/sable/        # /sable skill source
  tts/                        # Pocket TTS launcher, voice design tooling, runbook
  tools/
    package.ps1               # build dist/Sable + zip
    load_env.ps1              # loads .env for the PowerShell scripts
    hide_from_taskbar.ps1     # makes the pet window a tool window
    demo.mjs                  # scripted demo over the UDP bus
  dist/                       # build output (not source)
```

Planned, not yet created: `pi-extensions/pet-brain` + `pet-link` (milestone 6).
Shared constants not yet in `.env` (port 47800, the emotion list) are tracked
in REVIEW.md.

---

## 8. Milestones

1. **Body** (done): transparent click-through Godot window, placeholder cat,
   draggable, clamped to the screen, paged speech bubbles.
2. **Mood** (done): mirrors pi-persona's mood-state.json with the same decay
   math when `SABLE_PERSONA_DIR` points at one; neutral otherwise.
3. **Event bus** (done): UDP listener, Claude hook script and installer,
   moment heuristics, debug packets (`say` / `think` / `emote`).
4. **Brain** (done, direct llama.cpp): LLM lines for moments, mood shifts,
   greeting, wake-up and idle chatter, canned fallback, sleep when offline,
   `/slots` busy backoff.
5. **Voice** (partly done): Pocket TTS with the azelma preset, bubble synced
   to the audio, mouth flaps from the loudness envelope, line cache, `mute`
   debug packet. Still to do: purr/meow SFX, mute rules (meetings, quiet
   hours), custom voice via `tts/VOICE_RUNBOOK.md`.
5b. **Tray and settings** (done): tray icon and menu (show/hide, mute, do not
   disturb, vibe check, settings, quit; same menu on right-clicking the cat),
   cat icon rendered from the drawn cat (`-- --render-icon` regenerates
   `godot/icon.png` and `icon.ico`), settings window with live-applied
   `user://settings.cfg`, quiet hours, hide-from-screen-capture, remembered
   position, hidden from the taskbar via `tools/hide_from_taskbar.ps1`.
5c. **Sable's take** (done): `claude-skills/sable` skill (installed to
   `~/.claude/skills/sable`) runs `brain/sable_take.mjs`, which reads the raw
   transcript of the current Claude session and has Sable give a vibe check of
   the last turns, printed and spoken by the pet. Also in the tray menu.
6. **pi brain**: swap 1.2a for pi RPC with the pet-brain tools, plus the
   pet-link extension so she reacts to pi sessions too.
7. **Art**: swap in ComfyUI poses.
5d. **Chat with Sable** (done): tray/right-click "Chat with Sable..." opens a
   retro IM window (`chat_window.gd`): buddy header with her face and mood,
   red `{user}` / blue Sable thread with timestamps, "Sable is typing...",
   Enter to send, Clear, and synthesized door/send/receive chimes (`sfx.gd`,
   original sounds). Every line she says in the bubble is also appended to the
   thread (away musings in gray italics as "Sable (to herself)"), so it reads
   as one running conversation and the user can ask about anything she said.
   History persists in `user://chat_history.json` (last 120 kept, last 20 sent
   to the LLM with runs of her lines merged and a placeholder user turn in
   front, for templates that need strict alternation). The thread always opens
   and stays scrolled to the newest line. Prompt: SOUL + USER +
   `brain/chat_rules.md` + memories + "right now" context (time, mood, what she
   noticed today). Chat doesn't defer to a busy coding slot (the user is
   waiting), and it bumps a pet line that's stuck waiting. Replies also pop in
   the bubble and are spoken (setting). Brain offline: AIM-style auto-response.
8. **Extras** (done):
   - **Memory** (`memory.gd`, `user://memory.json`): after every chat message
     a separate low-temperature extraction call (no persona) returns up to two
     NEW long-term facts or NONE, given her previous line and the facts already
     known. This is the approach mem0 and similar systems use (the LLM is the
     classifier). An explicit `REMEMBER:` line in her reply also works. Facts
     end every system prompt (after the cacheable prefix). Editable in Settings,
     with "Forget everything". Option for later: a dedicated small
     personal-facts classifier (arXiv 2605.10339) as a cheaper pre-filter.
   - **Diary** (`activity.gd` logs moments, mood shifts, chats and naps to
     `user://activity/<date>.jsonl`, 30 days kept): after the diary hour (22 by
     default) she writes the day's entry with `brain/diary_rules.md` to
     `user://diary/<date>.md`, backfills a missed yesterday, and announces it.
     Tray: "Write today's diary now" and "Open diary folder".
   - **Wander**: every ~12 min (random, setting) she strolls 120-520 px along
     the bottom of her screen, facing the way she walks with a little hop;
     dragging cancels; skipped while talking, asleep, hidden or in DND.
   - **Away detection** (`tools/idle_watch.ps1`, started hidden by Sable,
     exits with her): reports Windows keyboard/mouse idle time
     (`GetLastInputInfo`) over the bus every 20 s. Idle past `away_minutes`
     (10) = away: no voice, normal chatter off. With "Let her mind wander"
     (`away_wander`, on by default) she has occasional private musings as
     silent bubbles, even in quiet hours, logged for the diary. When the user
     comes back she welcomes them, referencing what she was thinking about.
   - **Reply to a bubble**: double-click it to open the chat with that line.
   - **Tray menu**: added Chat, Quiet hours, Write diary, Open diary folder.
   - Debug packets for scripting: `chat`, `open: "chat"`, `wander`, `diary`.
9. **Eyes** (done; needs a vision model, i.e. llama-server with `--mmproj`):
   - **Screen peek**: menu "What do you make of my screen?". With several
     screens she first asks the user to point the mouse at the one they mean
     (3 s), then grabs that screen with `DisplayServer.screen_get_image()`
     while her own window and the chat window are flagged
     exclude-from-capture. Screens wider than 2:1 are cropped to a 16:9 area
     around the mouse so text survives the downscale. The JPEG (longest side
     1536) goes to `brain.look()`, which checks `/props` `modalities.vision`
     first and answers in character if the model can't see. Only ever on an
     explicit request; under DND the answer goes to the chat window.
   - **Chat images**: Ctrl+V with an image on the clipboard, or drop an image
     file on the chat window, attaches it (thumbnail strip with Remove).
   - Images are saved as JPEGs in `user://chat_images`, shown as thumbnails in
     the thread, pruned with the history and wiped by Clear. Only the newest
     image in the context window is sent to the LLM (as an OpenAI-style
     `image_url` data URL); older ones become "[image]" so prompts stay small.
   - Debug packets: `peek`, and `chat` with `"image": "<path>"`.

---

## 9. Open questions

- If the server runs a single llama.cpp slot (`SABLE_LLM_SLOT=-1`), Sable and
  coding share one KV cache. Consider `-np 2` (with a unified KV cache if the
  build supports it) so her prompt never evicts the coding prompt.
- Which preset voice (from `tts/samples/`), and where the clip for a cloned
  Sable voice comes from.
- Should Claude commentary cover all projects, or exclude some via
  `claude-hooks/pet-hook.config.json`?
