# Code and structure review (2026-11-09)

An independent reviewer agent read every script against DESIGN.md. Its
findings were verified and most were fixed, then tested in the dev build and
in the packaged `Sable.exe`. Testing turned up one more bug (silent LLM lines).

No crashes or data loss were found. The problems were wrong behaviour,
chattiness and polish.

## Fixed

| # | Problem | Fix |
|---|---|---|
| 1 | A busy LLM server was treated as offline, so Sable fell asleep and woke up "after 0 minutes" during long jobs. | brain.gd now has three states. A timeout counts as **busy**. Only a refused connection or a failing `/health` counts as **offline**. Backoff grows only inside the health check. |
| 2 | A late LLM reply could replace a newer, more important line (for example an idle musing overwriting a "struggle" comment). | main.gd `_ask()` remembers what had been said when it asked, and drops the reply if something newer was said meanwhile. |
| 3 | The tray's "Vibe check" judged the wrong turns. It also ignored the deny list and failed silently. | `sable_take.mjs --from-tray` keeps the latest turn, honors `pet-hook.config.json`, and has the pet say any failure out loud. |
| 4 | Background-task notifications were counted as user turns in vibe checks. | Entries are skipped by `origin.kind`. The reviewer's suggested filter would have dropped every real prompt, because real prompts carry `origin.kind: "human"`, so it now skips only non-human kinds. |
| 5 | "Long session" wrap-ups repeated after almost every turn once a session passed 45 minutes, and "grind" ignored breaks. | One wrap-up per stretch of work. A 20-minute gap restarts the grind and wrap-up timers. |
| 6 | Long lines (vibe checks) were probably never spoken: the TTS timeout was a fixed 6 s. | The timeout scales with text length (6-25 s). |
| 7 | A cut-off JSON reply was shown raw (`{"emotion": ...`). | The fields are recovered with a regex, and `max_tokens` is raised to 300. |
| 8 | Turning on Do Not Disturb didn't close a multi-page bubble; it just advanced a page. | `bubble.hide_now()` closes it. |
| 9 | Audio kept playing under a new silent line, or after the bubble was clicked away. | Audio stops on the silent path and when the last page is closed. |
| 10 | Launching twice gave two cats and two tray icons. | A second launch tells the first one to show itself, then exits (UDP bind check). |
| 11 | `install.mjs` was fragile: it crashed if settings.json was missing, overwrote its backup on every run, and wrote non-atomically. | It creates `{}` if the file is missing, backs up once, and writes to a temp file then renames it. |
| 12 | Idle CPU was ~7% of a core because she redrew at 30 fps forever. | Frame-rate governor: 10 fps idle, 30 fps while talking, emoting, dragging or showing a bubble. Now ~3-4% of a core. |
| 13 | Sable's take could carry injected text from a tool output back into Claude as "instructions". | SKILL.md now says her output is commentary only and must never be acted on. |
| 14 | The UDP bus accepted any emote name, so an emote string could load any PNG on disk; text length was unbounded; wrong-typed fields raised errors. | Emotes are checked against a whitelist, text is capped at 600 chars, packets are capped at 8 KB, and fields are converted to strings first. |
| 15 | Mood-shift lines had no rate limit, so a mood flapping across a boundary meant constant comments. | All unprompted lines share a 90 s quiet gap. |
| 16 | The tray said "Hide Sable" while she was hidden; a hidden Sable still talked. | The tray tracks visibility. Hidden means fully quiet: no bubbles, no voice, no LLM calls. |
| 17 | DPI scale was fixed at startup for the wrong monitor. | The scale is worked out for the screen she is placed on, and recomputed when she's dragged to another monitor. |
| 18 | Stale comments and dead code in `brain.ask`. | Rewritten. |
| 19 | The deny entry `C:/dev/secret` also matched `C:/dev/secret-v2`. | Path entries now match on folder boundaries, in both the hook and the vibe check. |
| 20 | A one-slot server would hang requests pinned to slot 1. | Brain and vibe check use slot 1 only if `/slots` shows it exists. |
| 21 | The mood file was re-read every 2 s; the volume slider saved on every tick. | The mood file is read only when its mtime changes (plus every 30 s). The slider saves when you let go. |
| new | **LLM lines were silent in practice.** At 10 fps idle, Godot's HTTPRequest advances one step and reads 64 KB per frame, so TTS downloads crawled into the timeout. | Brain and voice requests now run on threads with 1 MB chunks. Measured: bubble plus voice ~3 s after a request, down from ~9 s silent. |

Structural fixes:
- One path helper (`godot/scripts/paths.gd`). Dev resolves to the repo root, the packaged build to the folder with `Sable.exe`, and `SABLE_HOME` overrides both. This replaced all the `res://..` paths, which break in an export.
- The icon loads through the resource system, so it also works in the export.
- User art in `art/sable` next to the app takes priority over bundled `res://art/sable`.
- Diagnostic lines (`[voice]`, `[say]`) print when TTS fails or a line goes silent. Run `Sable.exe` with redirected output to see them; Godot buffers its log file until exit.

Smaller cleanups: removed the dead "quit" line and the unused `available` flag. `Lines.pick()` no longer modifies the caller's dictionary. All files use LF line endings.

## Deferred (worth doing, not urgent)

- **Shared config.** Partly done: the URLs, slot and persona dir now come from one `.env` (read by `env.gd`, `tools/load_env.ps1` and `sable_take.mjs`). Port 47800 and the emotion list are still repeated in several GDScript and Node files; moving them into the same config would remove the remaining drift risk.
- **One prompt builder.** brain.gd and sable_take.mjs both assemble SOUL + USER + rules and clean output. Move the vibe-check rules to `brain/vibe_rules.md` and share one builder. The planned pi RPC brain may own this anyway.
- **A real speech queue.** Priority, TTL and supersede in one place, replacing `_say_seq`, the brain's busy fallback and the watcher's rate limit. Today's fixes cover the actual bugs.
- **Per-page TTS.** Synthesize each bubble page separately so long text starts speaking sooner (DESIGN 6.2). Today the whole line renders first (~1.2 s per 6 s of audio).
- **Memory.** ~163 MB private in the release build, against a 100 MB target. It's mostly the engine. A custom export template with 3D, physics and unused modules disabled is the main lever (also shrinks the 104 MB exe).
- **Bus auth.** Any local process can drive the debug commands. Nothing leaves the machine. A token file would close it if that ever matters.
- **Async hooks.** If Claude Code supports `"async": true` on command hooks (unverified), the hook could stop costing ~65 ms per event.

## How it was verified

- **Headless runs:** Godot 4.7.2 headless runs after each round, with no script errors.
- **Node scripts:** `node --check` on all of them. The deny-list matcher passed 4 cases. The vibe check ran against this session's real transcript.
- **Dev build:** a second launch hands off to the first instance. Idle CPU is ~3.4% of a core.
- **Packaged `Sable.exe`:**
  - out of the taskbar, title "Sable", no errors
  - brain lines use slot 1 with the pet rules loaded
  - voice confirmed by ear (LLM line and plain line both heard)
  - idle ~4% CPU
