# Packaging Sable as a standalone app

## TL;DR

```powershell
.\tools\package.ps1            # -> dist\Sable\ (folder) and dist\Sable-0.1.0.zip (~38 MB)
```

On the target machine: unzip, run `.\setup.ps1` once (add `-Autostart` to start
at login), then start `Sable.exe`. Tested on the dev machine: the packaged exe
runs on its own (taskbar-hidden, tray icon, brain on slot 1, voice working).
Building needs `GODOT` (your Godot 4.7.2 exe) set in `.env` or the environment.

## What's in the package

```
Sable\
  Sable.exe                  Godot 4.7.2 release template, everything embedded (~104 MB)
  setup.ps1                  one-time setup / uninstall (same script works in the dev repo)
  README.md                  short user guide (from tools\dist_README.md)
  .env.example               config template (setup.ps1 copies it to .env)
  persona\SOUL.md            default persona (USER.md optional, yours)
  brain\pet_rules.md         pet prompt rules (editable)
  brain\sable_take.mjs       vibe check (/sable skill and tray menu)
  claude-hooks\pet-hook.mjs  Claude Code hook -> UDP
  claude-hooks\install.mjs   adds/removes the hook in ~/.claude/settings.json
  claude-skills\sable\       /sable skill source ({{SABLE_HOME}} filled in by setup)
  tts\serve.ps1              Pocket TTS server launcher (Sable starts it herself)
  tts\design_voice.py, VOICE_RUNBOOK.md   custom voice tooling
  tools\hide_from_taskbar.ps1, load_env.ps1
  art\sable\                 drop pose PNGs here to replace the drawn cat
```

The repo has the same layout (with `godot\` instead of `Sable.exe`), so one
`setup.ps1` and one path helper (`godot/scripts/paths.gd`) serve both.

## How it works

- **Export**: `godot/export_presets.cfg` ("Windows Desktop"): x86_64 release
  template, pck embedded in the exe, icon from `res://icon.ico` written into the
  exe (Godot 4.7 modifies the exe resources itself, no rcedit), product name
  "Sable", no console wrapper. `icon.png`, `icon.ico` and `art/*` are included
  as raw files.
- **Export templates**: installed once into
  `%APPDATA%\Godot\export_templates\4.7.2.stable\` (only the Windows x86_64
  files were extracted from the official 1.28 GB bundle).
- **Finding files**: `paths.gd` resolves the support folder: the exe's folder in
  an export, the repo root in dev, or `SABLE_HOME` if set.
- **TTS**: Sable checks the TTS port on startup and launches
  `tts\serve.ps1` hidden if voice is on, `tts\.venv` exists, and nothing is
  listening. The server keeps running after she quits.
- **Single instance**: a second launch sees the UDP port taken, tells the
  running Sable to show herself, and exits.
- **Config**: `.env` next to the exe (or at the repo root in dev), read by
  `godot/scripts/env.gd`, `tools/load_env.ps1` and `brain/sable_take.mjs`.
  Real environment variables override `.env`.
- **Settings**: `%APPDATA%\Godot\app_userdata\Sable Pet\settings.cfg`, shared by
  the dev and packaged builds. Values changed there override `.env`.

## setup.ps1

| Step | What it does |
|---|---|
| Prereqs | Checks Node.js (hook, vibe check) and uv (TTS). |
| Config | Copies `.env.example` to `.env` if missing and asks what Sable should call you (`SABLE_USER_NAME`). |
| TTS | Creates `tts\.venv` with Pocket TTS on CPU PyTorch, then warms up (downloads the model). Skip with `-SkipTts`. |
| Claude hook | `node claude-hooks\install.mjs` (atomic, backs up the original settings once). |
| `/sable` skill | Copies `SKILL.md` to `~/.claude/skills/sable` with the real install path filled in (no BOM). |
| `-Autostart` | `HKCU\...\Run\Sable` = path to `Sable.exe` (packaged build only). |
| `-Uninstall` | Removes hook, skill and autostart; leaves the venv and settings. |

Re-run `setup.ps1` after moving the folder (the hook and skill store absolute paths).

## External requirements (not bundled, by design)

- **llama.cpp server** with an OpenAI-style API, `-np 2` so slot 1 is Sable's
  (default `http://127.0.0.1:8080`; change via `SABLE_LLM_URL` /
  `SABLE_LLM_SLOT` or in Settings; slot `-1` = any slot).
- **Node.js** for the Claude hook and vibe check. (Bundling a Node runtime or
  rewriting the hook as a tiny native exe is possible but not worth it for a
  personal tool.)
- **uv + ~1 GB** for the Pocket TTS venv (CPU PyTorch). Freezing it with
  PyInstaller would just move that gigabyte into the zip.
- **pi-persona** (optional). By default Sable uses the bundled
  `persona\SOUL.md` and a neutral mood. Point `SABLE_PERSONA_DIR` at a
  pi-persona agent dir to use its SOUL.md / USER.md and mirror its mood.

## Options considered

| Option | Verdict |
|---|---|
| Folder + zip + setup.ps1 (current) | Simple, transparent, easy to update by re-running `package.ps1`. |
| Real installer (Inno Setup / WiX / MSIX) | Adds Start menu entry, uninstall entry and a fixed install path. Easy to add later on top of the same folder; not needed for one machine. |
| Smaller exe via custom export template | Build Godot with 3D, physics, navigation, etc. disabled: likely ~30-40 MB exe and less RAM. Needs a Godot source build; worth it only if size/RAM matters. |
| Code signing | Avoids SmartScreen warnings when sharing. Irrelevant for personal use. |

## Releasing a new version

1. `.\tools\package.ps1 -Version 0.2.0` (stops a running packaged Sable first).
2. Copy/unzip over the old folder, keeping `.env`, `persona\USER.md`,
   `tts\.venv`, `tts\voices\` and `art\` (or re-run `setup.ps1`).
3. If the cat's look changed: regenerate the icon first with
   `& $env:GODOT --path godot -- --render-icon` (your Godot 4.7.2 console exe).
