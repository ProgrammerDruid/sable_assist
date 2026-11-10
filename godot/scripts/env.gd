extends RefCounted
## Local config: a real environment variable wins, then <home>/.env
## (KEY=VALUE lines, # comments; see .env.example), then the default.
## Prompts and canned lines use {user} and {brain}; sub() fills them in.

const Paths := preload("res://scripts/paths.gd")

static var _file := {}
static var _loaded := false


static func value(key: String, default: String = "") -> String:
	var v := OS.get_environment(key)
	if not v.is_empty():
		return v
	_load()
	var f: String = _file.get(key, "")
	return f if not f.is_empty() else default


static func user_name() -> String:
	return value("SABLE_USER_NAME", OS.get_environment("USERNAME").capitalize())


static func brain_name() -> String:
	return value("SABLE_BRAIN_NAME", "the GPU")


## SOUL.md / USER.md / IDENTIFY.md / mood-state.json live here.
static func persona_dir() -> String:
	var d := value("SABLE_PERSONA_DIR")
	return d if not d.is_empty() else Paths.file("persona")


## Fill {user} and {brain} placeholders.
static func sub(text: String) -> String:
	return text.replace("{user}", user_name()).replace("{brain}", brain_name())


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var path := Paths.file(".env")
	if not FileAccess.file_exists(path):
		return
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or not "=" in line:
			continue
		var key := line.get_slice("=", 0).strip_edges()
		var val := line.substr(line.find("=") + 1).strip_edges()
		if val.length() >= 2 and (val[0] == "\"" or val[0] == "'") and val[-1] == val[0]:
			val = val.substr(1, val.length() - 2)
		_file[key] = val
