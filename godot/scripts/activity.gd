extends Node
## A plain log of what happened today (moments, mood shifts, chats, brain
## naps), one JSON line per event in user://activity/YYYY-MM-DD.jsonl.
## Feeds the chat context ("things you noticed recently") and the diary.

const DIR := "user://activity"
const KEEP_DAYS := 30

var _recent: Array[Dictionary] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_prune()
	for e in read_day(today()):
		_recent.append(e)
	while _recent.size() > 50:
		_recent.pop_front()


func log_event(kind: String, text: String) -> void:
	var e := {t = Time.get_datetime_string_from_system(false, true).right(8).left(5), kind = kind, text = text.left(300)}
	_recent.append(e)
	while _recent.size() > 50:
		_recent.pop_front()
	var path := DIR.path_join(today() + ".jsonl")
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line(JSON.stringify(e))


## Most recent events (newest last), optionally skipping some kinds.
func recent(count: int, skip_kinds: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_recent.size() - 1, -1, -1):
		if not (_recent[i].kind in skip_kinds):
			out.push_front(_recent[i])
			if out.size() >= count:
				break
	return out


func read_day(date: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := DIR.path_join(date + ".jsonl")
	if not FileAccess.file_exists(path):
		return out
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var e = JSON.parse_string(line)
		if typeof(e) == TYPE_DICTIONARY:
			out.append(e)
	return out


static func today() -> String:
	return Time.get_date_string_from_system()


static func yesterday() -> String:
	return Time.get_date_string_from_unix_time(int(Time.get_unix_time_from_system()) - 86400 + _tz_offset())


static func _tz_offset() -> int:
	return int(Time.get_time_zone_from_system().bias) * 60


func _prune() -> void:
	var cutoff := Time.get_unix_time_from_system() - KEEP_DAYS * 86400
	for f in DirAccess.get_files_at(DIR):
		var d := Time.get_unix_time_from_datetime_string(f.get_basename())
		if d > 0 and d < cutoff:
			DirAccess.remove_absolute(DIR.path_join(f))
