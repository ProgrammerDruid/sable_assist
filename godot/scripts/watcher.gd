extends Node
## Turns raw Claude Code events into "moments" Sable reacts to.
##
## Keeps a small digest per Claude session (failure streaks, edit counts,
## session length, pending permission prompts) and fires a moment when a
## heuristic trips. Rate-limited so Sable comments, not narrates.

## line_key: kind of moment (also the canned-line key in lines.gd).
## emotion: cat emote. info: details for the LLM (proj, tool, streak, err, prompt, ...).
signal moment(line_key: String, emotion: String, info: Dictionary)
## Small non-verbal reaction (no bubble), e.g. a flinch on a failed tool call.
signal flinch(emotion: String)

enum Priority { LOW, MED, HIGH }
## Minimum seconds since the last bubble, per priority.
const MIN_GAP := { Priority.LOW: 120.0, Priority.MED: 45.0, Priority.HIGH: 8.0 }

const STREAK_STRUGGLE := 3
const STREAK_BAD := 6
const EDIT_MILESTONES := [25, 75, 150]
const WAITING_NUDGE_SEC := 90.0
const LONG_SESSION_SEC := 45.0 * 60.0
const GRIND_SEC := 2.0 * 3600.0
const STALE_SESSION_SEC := 8.0 * 3600.0
## No events for this long = a break; grind/wrapup timers restart after it.
const BREAK_SEC := 20.0 * 60.0
const EDIT_TOOLS := ["Edit", "Write", "MultiEdit", "NotebookEdit"]

var _frustrated := RegEx.create_from_string(
	"(?i)\\b(wtf|ffs|ugh+|dammit|damn it|still (broken|failing|not working)|why (is|does|won't|isn't|the hell)|doesn't work|not working|come on)\\b")
var _hyped := RegEx.create_from_string(
	"(?i)\\b(awesome|amazing|hell yes|hell yeah|love it|perfect|nailed it|so cool)\\b")

var _sessions := {}
var _last_bubble := -1000.0


func _ready() -> void:
	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.autostart = true
	timer.timeout.connect(_tick)
	add_child(timer)


func handle(ev: Dictionary) -> void:
	if ev.get("src", "") != "claude":
		return
	var sid := str(ev.get("sid", ""))
	if sid.is_empty():
		return
	var now := _now()
	var s: Dictionary = _sessions.get(sid, {})
	if s.is_empty():
		s = {first = now, last = now, active_since = now, streak = 0, fail_tool = "", err = "",
			edits = 0, waiting_since = 0.0, grind_said = 0.0, wrapup_said = false,
			proj = str(ev.get("proj", ""))}
		_sessions[sid] = s
	# A long quiet gap ends a stretch of continuous work.
	if now - s.last > BREAK_SEC:
		s.active_since = now
		s.wrapup_said = false
	s.last = now
	var minutes := int((now - s.active_since) / 60.0)

	match ev.get("ev", ""):
		"SessionStart":
			if ev.get("source", "") in ["startup", "resume"]:
				_fire("claude_start", "anticipation", s, Priority.LOW)
		"UserPromptSubmit":
			s.waiting_since = 0.0
			var prompt := str(ev.get("prompt", ""))
			if _frustrated.search(prompt):
				_fire("frustration", "sadness", s, Priority.MED, {prompt = prompt})
			elif _hyped.search(prompt):
				_fire("hype", "joy", s, Priority.MED, {prompt = prompt})
			elif now - s.active_since > GRIND_SEC and now - s.grind_said > 3600.0:
				s.grind_said = now
				_fire("grind", "anticipation", s, Priority.MED, {minutes = minutes})
		"PostToolUse":
			s.waiting_since = 0.0
			var tool := str(ev.get("tool", ""))
			if tool in EDIT_TOOLS:
				s.edits += 1
				if s.edits in EDIT_MILESTONES:
					_fire("edits", "surprise", s, Priority.LOW, {edits = s.edits})
			if tool == s.fail_tool:
				if s.streak >= STREAK_STRUGGLE:
					_fire("win", "joy", s, Priority.HIGH, {tool = tool, streak = s.streak})
				s.streak = 0
				s.fail_tool = ""
		"PostToolUseFailure":
			s.waiting_since = 0.0
			if ev.get("interrupt", false):
				return
			var tool := str(ev.get("tool", ""))
			s.streak = s.streak + 1 if tool == s.fail_tool or s.fail_tool == "" else 1
			s.fail_tool = tool
			s.err = str(ev.get("err", ""))
			var info := {tool = tool, streak = s.streak, err = s.err}
			if s.streak == STREAK_STRUGGLE:
				_fire("struggle", "sadness", s, Priority.HIGH, info)
			elif s.streak == STREAK_BAD:
				_fire("struggle_bad", "anger", s, Priority.HIGH, info)
			else:
				flinch.emit("fear")
		"Notification":
			if ev.get("ntype", "") == "permission_prompt":
				s.waiting_since = now
		"Stop":
			s.waiting_since = 0.0
			# One recap per long stretch of work, not one per Claude turn.
			if now - s.active_since > LONG_SESSION_SEC and not s.wrapup_said:
				s.wrapup_said = true
				_fire("wrapup", "trust", s, Priority.LOW, {minutes = minutes})
			elif randf() < 0.15:
				_fire("done", "joy", s, Priority.LOW)
		"SessionEnd":
			_sessions.erase(sid)


func _tick() -> void:
	var now := _now()
	for sid in _sessions.keys():
		var s: Dictionary = _sessions[sid]
		if now - s.last > STALE_SESSION_SEC:
			_sessions.erase(sid)
		elif s.waiting_since > 0.0 and now - s.waiting_since > WAITING_NUDGE_SEC:
			s.waiting_since = 0.0
			_fire("waiting", "anticipation", s, Priority.MED)


func _fire(key: String, emotion: String, s: Dictionary, priority: Priority, info: Dictionary = {}) -> void:
	var now := _now()
	if now - _last_bubble < MIN_GAP[priority]:
		return
	_last_bubble = now
	info["proj"] = s.proj
	moment.emit(key, emotion, info)


func _now() -> float:
	return Time.get_unix_time_from_system()
