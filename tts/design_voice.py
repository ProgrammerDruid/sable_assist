"""Generate candidate Sable voices with Qwen3-TTS VoiceDesign (needs a CUDA GPU).

Each voice brief below is rendered several times reading the same reference
script, so you can compare designs and pick the best take. See VOICE_RUNBOOK.md.

Usage (from the tts folder, with the design venv):
    .venv-design\\Scripts\\python design_voice.py              # 3 takes per brief
    .venv-design\\Scripts\\python design_voice.py --takes 5 --only dry_alto
"""

import argparse
import html
import pathlib

import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel

# About 25 seconds of speech: varied sounds, a question, some sarcasm, a
# softer ending. The clone copies HOW this is read, so it should sound like Sable.
REFERENCE_SCRIPT = (
    "Oh, you're back. I was starting to think you'd finally found a hobby. "
    "Look, the build failed three times, and honestly? I'm not even surprised. "
    "Fix the import, run it again, and try not to look so pleased with yourself when it works. "
    "...Fine. That was actually clever. Don't let it go to your head."
)

# Natural-language descriptions of the voice. Edit freely; add as many as you like.
VOICE_BRIEFS = {
    "dry_alto": (
        "A woman in her early thirties with a low, smoky alto voice. Dry, sardonic "
        "delivery, unhurried pacing, a smirk audible in the voice. Clear American "
        "accent, close microphone, no reverb, no background noise."
    ),
    "bright_tease": (
        "A young woman with a bright, quick, playful voice, teasing and mischievous, "
        "crisp consonants, light vocal fry at the ends of sentences. Clean studio recording."
    ),
    "velvet_deadpan": (
        "A calm, velvety mid-range female voice, deadpan and confident, like a bored but "
        "brilliant engineer. Even pace, subtle warmth, studio quality."
    ),
    "sly_rasp": (
        "A sly, slightly raspy female voice with a hint of a purr, playful and knowing, "
        "measured pace, very articulate. Studio quality, no background noise."
    ),
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--takes", type=int, default=3, help="renders per brief")
    ap.add_argument("--only", nargs="*", help="brief names to render (default: all)")
    ap.add_argument("--out", default="design/candidates")
    ap.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    briefs = {k: v for k, v in VOICE_BRIEFS.items() if not args.only or k in args.only}

    print(f"Loading {args.model} on {torch.cuda.get_device_name(0)} ...")
    model = Qwen3TTSModel.from_pretrained(
        args.model,
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",  # flash-attn is painful to build on Windows; sdpa is fine
    )

    rows = []
    for name, brief in briefs.items():
        for take in range(args.takes):
            torch.manual_seed(1000 + take)
            wavs, sr = model.generate_voice_design(
                text=REFERENCE_SCRIPT, language="English", instruct=brief
            )
            path = out / f"{name}_{take}.wav"
            sf.write(path, wavs[0], sr)
            print(f"  wrote {path}")
            rows.append((name, take, brief, path.name))

    page = [
        "<!doctype html><meta charset=utf-8><title>Sable voice design</title>",
        "<style>body{font:15px system-ui;background:#141418;color:#eee;max-width:760px;"
        "margin:24px auto;padding:0 16px}div{margin:10px 0}small{color:#aaa}</style>",
        "<h2>Sable voice design candidates</h2>",
        f"<p><i>{html.escape(REFERENCE_SCRIPT)}</i></p>",
    ]
    for name, take, brief, file in rows:
        page.append(
            f"<div><b>{name} #{take}</b> <small>{html.escape(brief)}</small><br>"
            f"<audio controls preload=none src='{file}'></audio></div>"
        )
    (out / "index.html").write_text("\n".join(page), encoding="utf-8")
    print(f"Open {out / 'index.html'} to listen.")


if __name__ == "__main__":
    main()
