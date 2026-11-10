# Sable

A black-cat desktop familiar. She watches your Claude Code sessions, comments
through a local LLM, and talks with a local voice. Everything runs on this
machine.

## First run

1. Open PowerShell in this folder and run `.\setup.ps1` (add `-Autostart` to
   start Sable at login). It copies `.env.example` to `.env`, asks what Sable
   should call you, and installs the local TTS voice, the Claude Code hook and
   the `/sable` skill. Re-run it if you move this folder.
2. Start `Sable.exe`. She appears bottom-right and gets a tray icon.

## Config

`.env` in this folder holds the defaults (`SABLE_USER_NAME`, `SABLE_LLM_URL`,
`SABLE_LLM_SLOT`, `SABLE_TTS_URL`, `SABLE_TTS_VOICE`, `SABLE_PERSONA_DIR`, ...;
see `.env.example` for all keys). Real environment variables override `.env`,
and anything changed in Sable's Settings window overrides both. Her persona is
`persona\SOUL.md` unless `SABLE_PERSONA_DIR` points elsewhere.

## Needs

- A llama.cpp server with an OpenAI-style API (default `http://127.0.0.1:8080`,
  slot 1 reserved for Sable: run it with `-np 2`, or set `SABLE_LLM_SLOT=-1`
  to use any slot).
- Node.js (Claude hook, vibe check) and uv (TTS setup).

## Using her

- Drag her anywhere; double-click to poke; click a bubble to skip it.
- Right-click her (or the tray icon) for the menu: mute, do not disturb,
  vibe check, settings, quit.
- In Claude Code: "What's your take on this, Sable?" or `/sable`.
- Custom voice: `tts\VOICE_RUNBOOK.md`. Custom art: drop PNGs in `art\sable\`.
- Settings live in `%APPDATA%\Godot\app_userdata\Sable Pet\settings.cfg`.

## Removing

`.\setup.ps1 -Uninstall`, then delete this folder.

## License

PolyForm Noncommercial 1.0.0 (see `LICENSE.md`): free for noncommercial use,
modification and sharing; no commercial use.
