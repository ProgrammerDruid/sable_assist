// Adds (or removes) the Sable pet hook in ~/.claude/settings.json.
//   node install.mjs             install (or re-point after moving the folder)
//   node install.mjs --uninstall remove
// Existing hooks are left untouched; running install twice does not add
// duplicates. The first run saves the original as settings.json.bak-sable
// (never overwritten later). Writes are atomic (temp file + rename), so Claude
// Code, which watches the file, never reads half-written JSON.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EVENTS = [
  "SessionStart",
  "UserPromptSubmit",
  "PostToolUse",
  "PostToolUseFailure",
  "Notification",
  "Stop",
  "SessionEnd",
];

const hookScript = path.join(path.dirname(fileURLToPath(import.meta.url)), "pet-hook.mjs").replace(/\\/g, "/");
const command = `"${process.execPath.replace(/\\/g, "/")}" "${hookScript}"`;
const isPetHook = (h) => typeof h.command === "string" && h.command.includes("pet-hook.mjs");

const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
const backupPath = settingsPath + ".bak-sable";
const exists = fs.existsSync(settingsPath);
const settings = exists ? JSON.parse(fs.readFileSync(settingsPath, "utf8")) : {};
if (exists && !fs.existsSync(backupPath)) fs.copyFileSync(settingsPath, backupPath);

const uninstall = process.argv.includes("--uninstall");
settings.hooks ??= {};

for (const ev of EVENTS) {
  const groups = (settings.hooks[ev] ?? [])
    .map((g) => ({ ...g, hooks: (g.hooks ?? []).filter((h) => !isPetHook(h)) }))
    .filter((g) => g.hooks.length > 0);
  if (!uninstall) groups.push({ hooks: [{ type: "command", command, timeout: 2 }] });
  if (groups.length) settings.hooks[ev] = groups;
  else delete settings.hooks[ev];
}
if (Object.keys(settings.hooks).length === 0) delete settings.hooks;

fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
const tmp = settingsPath + ".sable-tmp";
fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + "\n");
fs.renameSync(tmp, settingsPath);

console.log(`${uninstall ? "Removed" : "Installed"} Sable pet hook (${EVENTS.length} events) in ${settingsPath}`);
if (fs.existsSync(backupPath)) console.log(`Original settings backup: ${backupPath}`);
if (!uninstall) console.log(`Command: ${command}`);
