extends RefCounted
## Canned Sable lines used when there is no LLM call (offline, busy, or just
## cheap reactions). SFW, a little edgy.

const LINES := {
	"greet": [
		"Awake. Barely. Don't make me regret it.",
		"Back on the desktop. Try to look busy.",
		"I'm here. Your code still isn't done.",
	],
	"poke": [
		"Hands off the fur.",
		"Do that again and I'm deleting a semicolon.",
		"I'm a familiar, not a stress ball.",
		"Yes? Make it quick.",
	],
	"joy": [
		"Things are working. Suspicious, but I'll take it.",
		"Look at us. Competent.",
		"Purring. Don't make it weird.",
	],
	"trust": [
		"Fine. You know what you're doing. Mostly.",
		"I'll let you drive. For now.",
	],
	"fear": [
		"That's a lot of red. I'm not panicking, you're panicking.",
		"Something's about to break. I can feel it in my whiskers.",
	],
	"surprise": [
		"Wait. That worked?",
		"Huh. Didn't see that coming.",
	],
	"sadness": [
		"That one hurt. Snacks may be required.",
		"We'll fix it. Probably. Eventually.",
	],
	"disgust": [
		"Who wrote this? Don't answer.",
		"I've coughed up hairballs cleaner than that diff.",
	],
	"anger": [
		"One more failed build and something goes off your desk.",
		"I am being very patient. Visibly.",
	],
	"anticipation": [
		"Something's brewing. I like it.",
		"Go on. Show me what you've got.",
	],

	# --- Claude Code moments ({proj} = project folder name) ---
	"claude_start": [
		"Oh. You brought Claude. I'll just sit here then.",
		"Claude again? Fine. I'm watching both of you.",
		"New session in {proj}. Try not to embarrass me.",
	],
	"frustration": [
		"Deep breath. Yelling at it won't make it compile faster.",
		"I heard that. Want me to hiss at it?",
		"Easy. We'll get it.",
	],
	"hype": [
		"Told you we were good.",
		"Don't get cocky. ...Okay, a little cocky.",
		"See? This is why you keep me around.",
	],
	"struggle": [
		"Three failures in a row. Want me to knock something off a shelf?",
		"That's a streak, and not the good kind.",
		"Rough patch in {proj}. You've got this. Probably.",
	],
	"struggle_bad": [
		"Six failures. I'm taking this personally now.",
		"At this point {proj} owes YOU an apology.",
	],
	"win": [
		"There it is. Knew you had it.",
		"Fixed! I never doubted you. Much.",
		"Victory. One small celebration is allowed.",
	],
	"edits": [
		"That's a lot of edits. Hope someone's reading the diff.",
		"{proj} is getting rewritten one file at a time, huh.",
	],
	"waiting": [
		"Claude's been waiting on you. Rude to leave it hanging.",
		"There's a permission prompt sulking in {proj}.",
	],
	"grind": [
		"Two hours straight. Water. Now.",
		"You've been at this a while. Stretch, or I sit on your keyboard.",
	],
	"wrapup": [
		"Long session. Not bad. Not great. Not bad.",
		"Done in {proj}? I'll grade it later.",
	],
	"done": [
		"Claude's done. Your move.",
		"Finished. Go look before it gets ideas.",
	],

	# --- Brain (LLM server) state and idle chatter ---
	"sleep": [
		"Brain's offline. Napping until {brain} comes back.",
		"Lost my brain. Wake me when the GPU's back.",
	],
	"wake": [
		"I'm back. Miss me?",
		"Brain's online again. Did anything break while I was out?",
	],
	"diary": [
		"Diary's written. No, you can't read it. ...Fine, it's in the folder.",
		"Dear diary: {user}'s at it again. Entry saved.",
		"Today's diary entry is done. You come off... mostly okay.",
	],
	"idle": [
		"Quiet in here. Suspiciously quiet.",
		"Still here. Still judging.",
		"If you're not going to code, at least scratch behind my ears.",
	],
}

const Env := preload("res://scripts/env.gd")

static var _last := ""


## vars fills {placeholders}, e.g. pick("struggle", {proj = "ai_assistant"}).
static func pick(key: String, vars: Dictionary = {}) -> String:
	var options: Array = LINES.get(key, [])
	if options.is_empty():
		return ""
	var line: String = options[randi() % options.size()]
	if line == _last and options.size() > 1:
		line = options[(options.find(line) + 1) % options.size()]
	_last = line
	var v := vars.duplicate()
	if str(v.get("proj", "")).is_empty():
		v["proj"] = "here"
	return Env.sub(line.format(v))  # {user} / {brain}
