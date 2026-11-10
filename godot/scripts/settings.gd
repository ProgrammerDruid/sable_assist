extends Node
## Persistent settings in user://settings.cfg
## (%APPDATA%\Godot\app_userdata\Sable Pet\settings.cfg). Changes apply live
## through the `changed` signal and are saved immediately.

signal changed(key: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"voice_enabled": true,
	"volume": 0.8,
	"dnd": false,                    # do not disturb: no bubbles, no voice
	"idle_chatter": true,
	"idle_minutes_min": 20,
	"idle_minutes_max": 40,
	"quiet_hours": true,             # no voice and no unprompted chatter
	"quiet_start": 23,               # hour, local time
	"quiet_end": 8,
	"speak_chat": true,              # chat replies also pop in the bubble and are spoken
	"wander": true,                  # stroll along the taskbar now and then
	"wander_minutes": 12,
	"away_minutes": 10,              # no keyboard/mouse this long = the user is away
	"away_wander": true,             # while away: silent private musings (logged for the diary)
	"diary": true,                   # write a diary entry each evening
	"diary_hour": 22,
	"hide_from_capture": false,      # invisible in screen shares and recordings
	"remember_position": true,
	"window_x": -1,
	"window_y": -1,
	"llm_url": "http://127.0.0.1:8080",  # default from SABLE_LLM_URL (.env)
	"tts_url": "http://127.0.0.1:8890",  # default from SABLE_TTS_URL (.env)
}
const Env := preload("res://scripts/env.gd")

var _cfg := ConfigFile.new()
var _defaults := DEFAULTS.duplicate()


func _init() -> void:
	# .env / environment supply the server defaults; a value saved from the
	# Settings window still wins.
	_defaults.llm_url = Env.value("SABLE_LLM_URL", DEFAULTS.llm_url).trim_suffix("/")
	_defaults.tts_url = Env.value("SABLE_TTS_URL", DEFAULTS.tts_url).trim_suffix("/")


func _ready() -> void:
	_cfg.load(PATH)  # missing file is fine: defaults apply


func get_value(key: String) -> Variant:
	return _cfg.get_value("sable", key, _defaults.get(key))


## save=false applies the value live without writing the file (e.g. while a
## slider is being dragged); call save() when done.
func set_value(key: String, value: Variant, save_now: bool = true) -> void:
	if get_value(key) == value:
		return
	_cfg.set_value("sable", key, value)
	if save_now:
		save()
	changed.emit(key)


func save() -> void:
	_cfg.save(PATH)


## True inside the quiet-hours window (handles windows that cross midnight).
func in_quiet_hours() -> bool:
	if not get_value("quiet_hours"):
		return false
	var h: int = Time.get_datetime_dict_from_system().hour
	var s: int = get_value("quiet_start")
	var e: int = get_value("quiet_end")
	if s == e:
		return false
	return (h >= s or h < e) if s > e else (h >= s and h < e)


## Voice is allowed right now (enabled, not muted by DND or quiet hours).
func voice_allowed() -> bool:
	return get_value("voice_enabled") and not get_value("dnd") and not in_quiet_hours()
