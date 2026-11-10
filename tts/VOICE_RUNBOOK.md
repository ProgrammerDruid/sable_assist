# Runbook: a custom synthetic voice for Sable

Goal: give Sable a voice nobody else has, without cloning a real person.
Everything here runs locally on your machine. No cloud services.

How it works:

1. **Describe** the voice in words ("low smoky alto, dry and sardonic...").
2. **Design** it: a voice-design model invents a brand new voice from that
   description and reads a reference script with it.
3. **Clean** the best take into a short, tidy WAV clip.
4. **Clone** it with Pocket TTS, the CPU engine Sable already uses: it learns the
   voice from that clip and can then say anything in it.
5. **Export** the clone to a voice file and point Sable's TTS server at it.

Time: about an hour the first time, most of it listening. Steps 1-3 use an
NVIDIA GPU once. Day to day, everything runs on the CPU.

All commands are PowerShell, run from `<repo>\tts` unless a step says
otherwise.

---

## 0. Prerequisites

- `uv` and Python 3.12 via uv
- `ffmpeg` (e.g. via winget). Check with `ffmpeg -version`.
- Pocket TTS in `tts\.venv` (installed by `setup.ps1`)
- An NVIDIA GPU for the design step (about 8 GB VRAM, free of other jobs)

---

## 1. Write the voice brief

Open `design_voice.py` and edit `VOICE_BRIEFS`. There are four starting
points already (`dry_alto`, `bright_tease`, `velvet_deadpan`, `sly_rasp`).

Tips for good briefs:
- Describe **timbre** (low/high, smoky, bright, raspy, velvety), **age**,
  **accent**, **pace**, and **attitude** (dry, teasing, deadpan).
- Always add the recording quality: "studio quality, close microphone, no
  reverb, no background noise". A noisy design clones badly.
- Describe a voice, never a person. "Sounds like <actor>" is off the table.
- Make 3-5 variations. The first idea is rarely the winner.

Also check `REFERENCE_SCRIPT`. The clone copies *how* that script is read
(rhythm, attitude), so it should sound like something Sable would say. The
default is about 25 seconds, which is the sweet spot.

---

## 2. Install the design model (one time, about 6 GB of downloads)

Use a separate venv with CUDA PyTorch. The commands below use the CUDA 12.8
builds (needed for RTX 50-series cards; older cards work with them too).

```powershell
uv venv .venv-design --python 3.12
uv pip install --python .venv-design\Scripts\python.exe `
    torch torchaudio qwen-tts soundfile `
    --extra-index-url https://download.pytorch.org/whl/cu128 `
    --index-strategy unsafe-best-match
.venv-design\Scripts\python -c "import torch; print(torch.__version__, torch.cuda.get_device_name(0))"
```

The last line should print a `+cu128` version and your GPU's name. If it
says CUDA is unavailable, the CPU build of torch got installed. Re-run the
install line with `--reinstall-package torch`.

The model itself (`Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`, ~3.4 GB) downloads
from Hugging Face on first run.

---

## 3. Generate candidates

```powershell
.venv-design\Scripts\python design_voice.py              # every brief, 3 takes each
.venv-design\Scripts\python design_voice.py --only dry_alto sly_rasp --takes 5
start design\candidates\index.html
```

Listen to everything. Each take of the same brief is a slightly different
voice. Shortlist 2-4 favourites. Judge the **voice itself**, not small reading
mistakes: the clone will say new lines anyway.

Not happy? Edit the briefs and run again. This loop is the fun part.

---

## 4. Clone-test the shortlist (the step people skip)

A designed voice doesn't always survive cloning. Run every candidate through
Pocket TTS and listen to what Sable will actually sound like. The TTS server
must be running (`.\serve.ps1`).

```powershell
mkdir design\clones -Force | Out-Null
$name = "Sam"   # whatever SABLE_USER_NAME is in your .env
$line = "Three failures in a row, $name. Want me to knock something off a shelf? Fine. You've got this. Probably."
Get-ChildItem design\candidates\*.wav | ForEach-Object {
    curl.exe -s -F "text=$line" -F "voice_wav=@$($_.FullName)" http://127.0.0.1:8890/tts -o "design\clones\$($_.BaseName).wav"
    Write-Host "cloned $($_.Name)"
}
explorer design\clones
```

Pick the clone you like best. Its matching file in `design\candidates` is your
reference clip.

---

## 5. Clean the reference clip

Trim silence at both ends, convert to mono 24 kHz (Pocket TTS's native
format), and normalize loudness:

```powershell
ffmpeg -y -i design\candidates\dry_alto_1.wav -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,loudnorm=I=-18:TP=-2:LRA=7" -ac 1 -ar 24000 design\sable_ref.wav
```

(Replace `dry_alto_1.wav` with your pick.) A good reference clip is:
- 10-30 seconds long, one speaker, no music, no reverb, no clicks
- in the mood you want by default. A sad reference makes a sad Sable.

Optional: if the take has a fumbled word, cut it out in Audacity before
exporting. Small cuts are fine.

---

## 6. Export the voice and switch Sable to it

```powershell
mkdir voices -Force | Out-Null
.venv\Scripts\pocket-tts export-voice design\sable_ref.wav voices\sable.safetensors
.venv\Scripts\pocket-tts generate --voice voices\sable.safetensors --text "Brain's online. Did anything break while I was out?" --output-path design\final_test.wav
start design\final_test.wav
```

If that sounds right, restart the TTS server. `serve.ps1` automatically uses
`voices\sable.safetensors` when it exists:

```powershell
# stop the running server (Ctrl+C in its window, or:)
Get-NetTCPConnection -LocalPort 8890 -State Listen | ForEach-Object { Stop-Process -Id $_.OwningProcess }
.\serve.ps1
```

Sable needs no change: she just sends text, and the server owns the voice.
To go back to the preset, delete or rename `voices\sable.safetensors`, or run
`.\serve.ps1 -Voice azelma` (`SABLE_TTS_VOICE` in `.env` sets the preset).

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| Clone sounds generic or different from the design | Use a longer (20-30 s) or more expressive reference, or try another candidate in step 4. |
| Clone is muffled or echoey | The reference has reverb or noise. Pick a cleaner take, or add "close microphone, no reverb" to the brief. |
| Clone sounds bored or monotone | The reference was read flat. Change `REFERENCE_SCRIPT` to have more attitude and redesign. |
| Odd pauses or breaths | Trim them out of the reference (step 5 or Audacity). |
| `CUDA not available` in step 2 | The CPU torch build got installed. Reinstall with the cu128 index. |
| Out of memory on the GPU | Close other GPU jobs (ComfyUI, an LLM server on the same card), or render fewer briefs at once with `--only`. |
| First run is slow | That's the model download. Later runs start in seconds. |

---

## 8. Rules of the road

- Only clone voices you have the right to use: a designed synthetic voice,
  your own, or someone who said yes. Never a real actor, streamer or
  character. Kyutai's terms prohibit that too.
- Licenses: Qwen3-TTS is Apache-2.0. Pocket TTS code is MIT; its weights and
  preset voices have their own licenses (see the Pocket TTS voices page).
  All fine for a personal desktop pet.

## References

- Qwen3-TTS (VoiceDesign, design-then-clone workflow): https://github.com/QwenLM/Qwen3-TTS
- Pocket TTS: https://github.com/kyutai-labs/pocket-tts (serve docs: https://kyutai-labs.github.io/pocket-tts/CLI%20Commands/serve/)
