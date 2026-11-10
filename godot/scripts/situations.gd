extends RefCounted
## Plain-English descriptions of moments, handed to the LLM as the situation.

const TEMPLATES := {
	"claude_start": "{user} just started a new Claude Code session in project {proj}. You're a little jealous of Claude.",
	"frustration": "{user} sounds frustrated, having just typed this to Claude in project {proj}: \"{prompt}\"",
	"hype": "{user} sounds excited, having just typed this to Claude in project {proj}: \"{prompt}\"",
	"struggle": "{user}'s Claude Code session in project {proj} just had {streak} failed {tool} calls in a row. Last error: {err}",
	"struggle_bad": "It's getting bad: {streak} failed {tool} calls in a row in project {proj}. Last error: {err}",
	"win": "After {streak} failed {tool} calls in a row, it finally worked in project {proj}.",
	"edits": "Claude has made {edits} file edits in project {proj} this session.",
	"waiting": "Claude has been waiting on a permission prompt in project {proj} for over a minute, and {user} is ignoring it.",
	"grind": "{user} has been working in project {proj} for {minutes} minutes straight.",
	"wrapup": "{user}'s long Claude session in project {proj} ({minutes} minutes) just finished a task.",
	"done": "Claude just finished a task in project {proj}.",
}


static func describe(key: String, info: Dictionary) -> String:
	var vars := {proj = "?", prompt = "", tool = "tool", streak = 0, err = "(none)", edits = 0, minutes = 0}
	vars.merge(info, true)
	if str(vars.err).strip_edges().is_empty():
		vars.err = "(none)"
	return str(TEMPLATES.get(key, "Something happened in project {proj}.")).format(vars)
