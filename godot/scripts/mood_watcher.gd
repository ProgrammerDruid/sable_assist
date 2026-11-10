extends Node
## Mirrors Sable's emotional state from pi-persona's mood-state.json in the
## persona dir (SABLE_PERSONA_DIR). Optional: without that file she stays at a
## calm baseline mood.
##
## pi-persona stores an angle on Plutchik's wheel plus an intensity. Intensity
## decays toward a baseline over time, and reads never write the decay back to
## disk, so we recompute it here with the same formula pi-persona uses
## (mood-engine.ts tick()).

signal mood_updated(emotion: String, level: int, intensity: float, emotion_changed: bool)

const EMOTIONS: Array[String] = [
	"joy", "trust", "fear", "surprise", "sadness", "disgust", "anger", "anticipation",
]
const BASELINE := 0.15
const LAMBDA_BASE := 0.00054
const POLL_SEC := 2.0
const CYCLE_SEC := 3.0

## Preview mode: cycle through every emotion and level instead of reading the file.
var cycle_debug := false

const Env := preload("res://scripts/env.gd")
## Re-read the file at least this often even if its mtime looks unchanged
## (mtime has 1 s resolution, so two writes in one second could hide one).
const FORCE_READ_SEC := 30.0

var agent_dir := ""
var emotion := ""
var level := 0
var intensity := BASELINE
## What caused the latest mood change, from pi-persona's history
## (e.g. "user praise", "command error"). Empty if unknown.
var last_trigger := ""

var _angle := 0.0
var _stored_intensity := BASELINE
var _last_interaction_ms := 0.0
var _updates_enabled := true
var _neuroticism := 0.5
var _last_raw := ""
var _last_mtime := -1
var _last_read := -1000.0
var _cycle_i := 0


func _ready() -> void:
	agent_dir = Env.persona_dir()
	_neuroticism = _read_neuroticism()

	var timer := Timer.new()
	timer.wait_time = CYCLE_SEC if cycle_debug else POLL_SEC
	timer.autostart = true
	timer.timeout.connect(_poll)
	add_child(timer)
	_poll.call_deferred()


func _poll() -> void:
	if cycle_debug:
		_advance_cycle()
		return
	_read_state()
	_recompute()


func _read_state() -> void:
	var path := agent_dir.path_join("mood-state.json")
	if not FileAccess.file_exists(path):
		return
	var mtime := FileAccess.get_modified_time(path)
	var now := Time.get_unix_time_from_system()
	if mtime == _last_mtime and now - _last_read < FORCE_READ_SEC:
		return
	_last_mtime = mtime
	_last_read = now
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty() or raw == _last_raw:
		return
	var data = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		# Leave _last_raw alone so the next poll retries.
		return
	_last_raw = raw
	_angle = float(data.get("lastAngle", 0.0))
	_stored_intensity = float(data.get("lastIntensity", BASELINE))
	_last_interaction_ms = float(data.get("lastInteraction", 0.0))
	_updates_enabled = bool(data.get("emotionUpdatesEnabled", true))
	var history: Array = data.get("history", [])
	if not history.is_empty() and typeof(history[-1]) == TYPE_DICTIONARY:
		last_trigger = str(history[-1].get("trigger", "")).replace("_", " ")


func _recompute() -> void:
	var inten := _stored_intensity
	if _updates_enabled and _last_interaction_ms > 0.0:
		var now_ms := Time.get_unix_time_from_system() * 1000.0
		var elapsed := maxf(0.0, (now_ms - _last_interaction_ms) / 1000.0)
		var lam := LAMBDA_BASE / (0.5 + _neuroticism * 1.5)
		inten = clampf(BASELINE + (_stored_intensity - BASELINE) * exp(-lam * elapsed), 0.0, 1.0)
	_apply(_nearest_emotion(_angle), inten)


func _apply(emo: String, inten: float) -> void:
	var lvl := 1 if inten <= 0.33 else (2 if inten <= 0.66 else 3)
	var changed := emo != emotion
	if changed or lvl != level or absf(inten - intensity) > 0.02:
		emotion = emo
		level = lvl
		intensity = inten
		mood_updated.emit(emotion, level, intensity, changed)


func _advance_cycle() -> void:
	var levels := [0.2, 0.5, 0.85]
	var emo: String = EMOTIONS[_cycle_i % EMOTIONS.size()]
	var inten: float = levels[(_cycle_i / EMOTIONS.size()) % levels.size()]
	_cycle_i += 1
	_apply(emo, inten)


static func _nearest_emotion(angle: float) -> String:
	var a := fposmod(angle, 360.0)
	var best := "joy"
	var best_dist := INF
	for i in EMOTIONS.size():
		var dist := absf(a - i * 45.0)
		if dist > 180.0:
			dist = 360.0 - dist
		if dist < best_dist:
			best_dist = dist
			best = EMOTIONS[i]
	return best


func _read_neuroticism() -> float:
	var path := agent_dir.path_join("IDENTIFY.md")
	if not FileAccess.file_exists(path):
		return 0.5
	var re := RegEx.create_from_string("(?m)^neuroticism:\\s*([0-9.]+)")
	var m := re.search(FileAccess.get_file_as_string(path))
	return clampf(m.get_string(1).to_float(), 0.0, 1.0) if m else 0.5
