// "What's your take on this, Sable?" - a vibe check of the latest Claude Code turns.
//
// Reads the current session's transcript (raw, so Sable judges what actually
// happened rather than Claude's summary of it), asks the local Sable brain (her
// llama.cpp slot) for a short take, prints it, and has the desktop pet say it.
//
//   node sable_take.mjs [--session <id>] [--cwd <dir>] [--transcript <file>]
//                       [--turns 2] [--focus "extra question"] [--no-pet]
//
// Everything is local: the llama.cpp server from .env, pet bus on 127.0.0.1:47800.

import dgram from "node:dgram";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");

// Same config as the app: a real environment variable wins, then <root>/.env.
const dotenv = {};
try {
  for (const raw of fs.readFileSync(path.join(root, ".env"), "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    const eq = line.indexOf("=");
    if (!line || line.startsWith("#") || eq < 0) continue;
    dotenv[line.slice(0, eq).trim()] = line.slice(eq + 1).trim().replace(/^(["'])(.*)\1$/, "$2");
  }
} catch { /* no .env: defaults */ }
const env = (key, fallback = "") => process.env[key] || dotenv[key] || fallback;

const LLM_URL = env("SABLE_LLM_URL", "http://127.0.0.1:8080").replace(/\/$/, "");
const PET_SLOT = parseInt(env("SABLE_LLM_SLOT", "1"), 10);
const USER = env("SABLE_USER_NAME", os.userInfo().username);
const BRAIN = env("SABLE_BRAIN_NAME", "the GPU");
const PERSONA = env("SABLE_PERSONA_DIR", path.join(root, "persona"));
const fill = (s) => s.replaceAll("{user}", USER).replaceAll("{brain}", BRAIN);
// Em and en dashes (U+2014, U+2013) become plain hyphens.
const DASHES = new RegExp("[" + String.fromCharCode(0x2014, 0x2013) + "]", "g");
const EMOTIONS = ["joy", "trust", "fear", "surprise", "sadness", "disgust", "anger", "anticipation"];

// --- args ------------------------------------------------------------------
const args = { turns: 2, pet: true };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const next = () => process.argv[++i];
  if (a === "--session") args.session = next();
  else if (a === "--cwd") args.cwd = next();
  else if (a === "--transcript") args.transcript = next();
  else if (a === "--turns") args.turns = Math.max(1, parseInt(next(), 10) || 2);
  else if (a === "--focus") args.focus = next();
  else if (a === "--no-pet") args.pet = false;
  // From the pet's tray menu: no turn asked for the take (keep the latest one),
  // nobody reads stdout (tell the pet about failures), honor the hook deny list.
  else if (a === "--from-tray") args.fromTray = true;
}

// --- find the transcript ---------------------------------------------------
function findTranscript() {
  if (args.transcript && fs.existsSync(args.transcript)) return args.transcript;
  const root = path.join(os.homedir(), ".claude", "projects");
  const dirs = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  const uuid = /^[0-9a-f-]{36}$/i;
  if (args.session && uuid.test(args.session)) {
    for (const d of dirs) {
      const f = path.join(root, d, `${args.session}.jsonl`);
      if (fs.existsSync(f)) return f;
    }
  }
  const newest = (dir) =>
    fs.readdirSync(dir).filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({ f: path.join(dir, f), t: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t)[0];
  const slug = (args.cwd || process.cwd()).replace(/[^A-Za-z0-9]/g, "-").toLowerCase();
  const match = dirs.find((d) => d.toLowerCase() === slug);
  if (match) {
    const n = newest(path.join(root, match));
    if (n) return n.f;
  }
  // Last resort: the most recently written transcript anywhere.
  return dirs.map((d) => newest(path.join(root, d))).filter(Boolean).sort((a, b) => b.t - a.t)[0]?.f;
}

// --- extract the last turns ------------------------------------------------
const clip = (s, n) => (s.length > n ? s.slice(0, n) + " [...]" : s);
const stripTags = (s) =>
  s.replace(/<(system-reminder|task-notification|ide_[a-z_]+|local-command-[a-z]+|command-[a-z]+)>[\s\S]*?<\/\1>/g, "").trim();
// Harness-generated "user" entries (background task results etc.) aren't the user.
// Real prompts have origin.kind "human" (or no origin); task notifications are
// "task-notification" and start with that tag.
const isHarnessEntry = (e, content) =>
  (e.origin?.kind && e.origin.kind !== "human") ||
  (typeof content === "string" && content.trimStart().startsWith("<task-notification>"));

function readTurns(file) {
  const size = fs.statSync(file).size;
  const fd = fs.openSync(file, "r");
  const len = Math.min(size, 6 * 1024 * 1024);
  const buf = Buffer.alloc(len);
  fs.readSync(fd, buf, 0, len, size - len);
  fs.closeSync(fd);
  const lines = buf.toString("utf8").split("\n");
  if (len < size) lines.shift(); // partial first line

  const turns = [];
  let cur = null;
  let cwd = "";
  for (const line of lines) {
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (e.cwd) cwd = e.cwd;
    const content = e.message?.content;
    if (e.type === "user" && !e.isMeta) {
      if (isHarnessEntry(e, content)) continue;
      if (typeof content === "string" || content?.some?.((c) => c.type === "text")) {
        const text = stripTags(typeof content === "string" ? content : content.filter((c) => c.type === "text").map((c) => c.text).join("\n"));
        const isSkillCall = /<command-name>\/?sable<\/command-name>/.test(typeof content === "string" ? content : JSON.stringify(content));
        if (text || isSkillCall) {
          cur = { user: text || "(asked for Sable's take)", parts: [], errors: 0, tools: 0 };
          turns.push(cur);
          continue;
        }
      }
      if (cur && Array.isArray(content)) {
        for (const c of content) {
          if (c.type === "tool_result" && c.is_error) {
            cur.errors++;
            const t = typeof c.content === "string" ? c.content : JSON.stringify(c.content);
            cur.parts.push(`[tool error: ${clip(t.replace(/\s+/g, " "), 160)}]`);
          }
        }
      }
    } else if (e.type === "assistant" && cur && Array.isArray(content)) {
      for (const c of content) {
        if (c.type === "text" && c.text.trim()) cur.parts.push(`Claude: ${clip(c.text.trim(), 2500)}`);
        else if (c.type === "tool_use") {
          cur.tools++;
          const what = c.input?.description || c.input?.file_path || c.input?.pattern || c.input?.command || "";
          if (cur.tools <= 25) cur.parts.push(`[${c.name}: ${clip(String(what).replace(/\s+/g, " "), 120)}]`);
        }
      }
    }
  }
  return { turns, cwd };
}

// --- prompt ----------------------------------------------------------------
const stripFront = (s) => s.replace(/^---[\s\S]*?---\s*/, "").trim();
function systemPrompt() {
  const parts = [];
  for (const f of [path.join(PERSONA, "SOUL.md"), path.join(PERSONA, "USER.md"), path.join(here, "pet_rules.md")]) {
    if (fs.existsSync(f)) parts.push(stripFront(fs.readFileSync(f, "utf8")));
  }
  parts.push(
    "# Vibe check request (overrides the length rule above)\n" +
      "{user} asked for your take on their recent Claude Code session. You may use up to 3 short sentences " +
      "(max 60 words). Be honest and specific: is it going well, is Claude overcomplicating or flailing, " +
      "is {user} being {user}? A real opinion, not a summary. Reply as JSON only: " +
      '{"emotion": one of ' + JSON.stringify(EMOTIONS) + ', "take": "your take"}.'
  );
  return fill(parts.join("\n\n"));
}

async function askSable(transcriptText, proj) {
  const user =
    `Project: ${proj}\n` +
    (args.focus ? `${USER}'s question: ${args.focus}\n` : "") +
    `\nThe last ${args.turns} turn(s) of the session ("${USER}:" is ${USER}, "Claude:" is the assistant, [brackets] are tool calls):\n\n` +
    transcriptText;
  // Use Sable's slot only if the server has it (a 1-slot server would queue forever).
  let slot = -1;
  try {
    const slots = await (await fetch(`${LLM_URL}/slots`, { signal: AbortSignal.timeout(4000) })).json();
    if (PET_SLOT >= 0 && Array.isArray(slots) && slots.length > PET_SLOT) slot = PET_SLOT;
  } catch { /* /slots disabled or slow: let the server pick */ }
  const body = {
    messages: [{ role: "system", content: systemPrompt() }, { role: "user", content: user }],
    max_tokens: 300,
    temperature: 0.8,
    id_slot: slot,
    chat_template_kwargs: { enable_thinking: false },
    response_format: {
      type: "json_object",
      schema: {
        type: "object",
        properties: { emotion: { type: "string", enum: EMOTIONS }, take: { type: "string" } },
        required: ["emotion", "take"],
      },
    },
  };
  const r = await fetch(`${LLM_URL}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60000),
  });
  if (!r.ok) throw new Error(`LLM HTTP ${r.status}`);
  const raw = (await r.json()).choices?.[0]?.message?.content ?? "";
  let out;
  try {
    out = JSON.parse(raw);
  } catch {
    // Cut-off JSON: salvage the fields instead of showing raw braces.
    const take = raw.match(/"take"\s*:\s*"((?:[^"\\]|\\.)*)/)?.[1];
    const emo = raw.match(/"emotion"\s*:\s*"([a-z]+)"/)?.[1];
    out = { emotion: emo, take: take ? JSON.parse(`"${take}"`) + "..." : raw.replace(/[{}"]/g, "") };
  }
  const take = String(out.take || "").replace(DASHES, "-").replace(/\*[^*]+\*/g, "").trim();
  const emotion = EMOTIONS.includes(out.emotion) ? out.emotion : "anticipation";
  return { emotion, take };
}

function tellPet(take, emotion) {
  return new Promise((resolve) => {
    const s = dgram.createSocket("udp4");
    s.on("error", () => resolve());
    const pkt = { src: "debug", say: take, ...(emotion ? { emote: emotion, seconds: 8 } : {}) };
    s.send(JSON.stringify(pkt), 47800, "127.0.0.1", () => {
      s.close();
      resolve();
    });
  });
}

// Same deny list the Claude hook uses (claude-hooks/pet-hook.config.json).
function isDenied(cwd) {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(here, "..", "claude-hooks", "pet-hook.config.json"), "utf8"));
    const norm = (s) => String(s).replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
    const c = norm(cwd);
    return (cfg.deny || []).some((d) => {
      const n = norm(d);
      return n === norm(path.basename(cwd)) || (n.includes("/") && (c === n || c.startsWith(n + "/")));
    });
  } catch {
    return false;
  }
}

// Where a message goes: Claude reads stdout; from the tray nobody does, so the
// pet says it instead.
async function report(msg) {
  console.log(msg);
  if (args.fromTray && args.pet) await tellPet(msg, "");
}

// --- main ------------------------------------------------------------------
try {
  const file = findTranscript();
  if (!file) throw new Error("no Claude Code transcript found");
  const { turns, cwd } = readTurns(file);
  if (args.fromTray && cwd && isDenied(cwd)) {
    await report(`That project's on your ignore list. My lips are sealed.`);
    process.exit(0);
  }
  // From Claude, the newest turn is the one asking for the take: skip it.
  const done = args.fromTray ? turns : turns.slice(0, -1);
  const recent = done.slice(-args.turns);
  if (!recent.length) throw new Error("no finished turns to judge yet");

  let text = recent.map((t) => [`${USER}: ${clip(t.user, 1500)}`, ...t.parts].join("\n")).join("\n\n---\n\n");
  if (text.length > 9000) text = "[...]\n" + text.slice(-9000);

  const { emotion, take } = await askSable(text, path.basename(cwd || args.cwd || "?"));
  if (!take) throw new Error("Sable had nothing to say (empty reply)");
  if (args.pet) await tellPet(take, emotion);
  console.log(`Sable (${emotion}): ${take}`);
} catch (err) {
  const msg = String(err?.message || err);
  if (/fetch failed|ECONNREFUSED|timeout|aborted/i.test(msg)) {
    await report(`Sable's brain is offline (couldn't reach the llama.cpp server at ${LLM_URL}).`);
  } else {
    await report(`Sable couldn't weigh in: ${msg}`);
  }
}
