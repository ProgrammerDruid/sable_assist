// Claude Code hook -> Sable desktop pet.
//
// Reads the hook JSON from stdin, sends one trimmed UDP packet to the pet on
// localhost, and exits 0. It must never slow down or break Claude:
//   - every error is swallowed (exit 0 always)
//   - a hard timer exits after 300 ms no matter what
//   - it prints nothing (UserPromptSubmit stdout would be injected into context)
// If the pet is not running, the packet is simply dropped.
//
// Optional config: pet-hook.config.json next to this file, e.g.
//   { "port": 47800, "deny": ["SomeWorkProject", "C:/dev/secret"], "sendPromptText": true }

import dgram from "node:dgram";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

setTimeout(() => process.exit(0), 300).unref();

const here = path.dirname(fileURLToPath(import.meta.url));

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(path.join(here, "pet-hook.config.json"), "utf8"));
  } catch {
    return {};
  }
}

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", () => resolve(data));
  });
}

function isDenied(cfg, cwd, proj) {
  const norm = (s) => String(s).replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
  const c = norm(cwd);
  return (cfg.deny || []).some((d) => {
    const n = norm(d);
    // A path entry matches that folder and everything under it, not "C:/dev/secret-v2".
    return n === norm(proj) || (n.includes("/") && (c === n || c.startsWith(n + "/")));
  });
}

const clip = (s, n) => String(s ?? "").slice(0, n);

try {
  const cfg = { port: 47800, host: "127.0.0.1", deny: [], sendPromptText: true, ...loadConfig() };
  const h = JSON.parse(await readStdin());
  const proj = path.basename(h.cwd || "");
  if (isDenied(cfg, h.cwd || "", proj)) process.exit(0);

  const pkt = { src: "claude", ev: h.hook_event_name, sid: h.session_id, proj, ts: Date.now() };
  if (h.tool_name) pkt.tool = h.tool_name;
  if (h.transcript_path) pkt.transcript = h.transcript_path;

  switch (h.hook_event_name) {
    case "UserPromptSubmit":
      if (cfg.sendPromptText) pkt.prompt = clip(h.prompt, 200);
      break;
    case "PostToolUse":
      pkt.ok = true;
      break;
    case "PostToolUseFailure":
      pkt.ok = false;
      pkt.interrupt = Boolean(h.is_interrupt);
      pkt.err = clip(h.error, 160);
      break;
    case "Notification":
      pkt.ntype = h.notification_type || "";
      pkt.msg = clip(h.message, 120);
      break;
    case "SessionStart":
      pkt.source = h.source || "";
      break;
  }

  const sock = dgram.createSocket("udp4");
  sock.on("error", () => process.exit(0));
  sock.send(Buffer.from(JSON.stringify(pkt)), cfg.port, cfg.host, () => {
    sock.close();
    process.exit(0);
  });
} catch {
  process.exit(0);
}
