// Scripted demo for the Sable pet: sends fake Claude events and debug lines
// over the localhost UDP bus. Run with: node tools/demo.mjs
import dgram from "node:dgram";

const sock = dgram.createSocket("udp4");
const send = (pkt) => new Promise((r) => sock.send(Buffer.from(JSON.stringify(pkt)), 47800, "127.0.0.1", r));
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const claude = (ev, extra = {}) => send({ src: "claude", ev, sid: "demo", proj: "ai_assistant", ...extra });
const say = (text, emote, seconds = 6) => send({ src: "debug", say: text, ...(emote ? { emote, seconds } : {}) });

const steps = [
  [0, () => say("Oh. We have an audience. Act natural.", "surprise")],
  [6, () => claude("SessionStart", { source: "startup" })],
  [14, async () => { for (let i = 0; i < 3; i++) { await claude("PostToolUseFailure", { tool: "Bash" }); await sleep(0.7); } }],
  [26, () => claude("PostToolUse", { tool: "Bash" })],
  [35, () => say("I keep a list of every build you've broken this week. It's a long list.", "anger", 5)],
  [43, () => say(
    "Fine, here's my whole job description. I live on a GPU under your desk, not in anyone's cloud. " +
    "I watch every Claude session and every failed build. When things go well I take the credit. " +
    "When they go badly I offer emotional support, which mostly looks like judging you from the corner of the screen. " +
    "Long thoughts get split into pages so nothing gets cut off. Click the bubble to skip ahead.", "anticipation", 12)],
  [80, () => say("That's the demo. Applause accepted in the form of treats.", "joy", 6)],
];

const start = Date.now();
for (const [at, fn] of steps) {
  const wait = at - (Date.now() - start) / 1000;
  if (wait > 0) await sleep(wait);
  await fn();
}
sock.close();
