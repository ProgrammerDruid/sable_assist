extends Node
## Long-term facts Sable remembers about the user, learned in chat.
## Stored in user://memory.json, shown and editable in Settings, and appended to
## every system prompt (at the end, so the prompt cache prefix stays stable).

signal changed

const PATH := "user://memory.json"
const MAX_FACTS := 40

var facts: PackedStringArray = []
var _remember_re := RegEx.create_from_string("(?im)^\\s*REMEMBER:\\s*(.+?)\\s*$")


func _ready() -> void:
	if FileAccess.file_exists(PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if typeof(data) == TYPE_DICTIONARY:
			for f in data.get("facts", []):
				facts.append(str(f))


func add(fact: String) -> void:
	fact = fact.strip_edges().left(200)
	if fact.is_empty():
		return
	for f in facts:
		if f.to_lower() == fact.to_lower():
			return
	facts.append(fact)
	while facts.size() > MAX_FACTS:
		facts.remove_at(0)
	_save()


## Replace everything (from the Settings editor). One fact per line.
func set_all(lines: PackedStringArray) -> void:
	var clean := PackedStringArray()
	for l in lines:
		if not l.strip_edges().is_empty():
			clean.append(l.strip_edges().left(200))
	if clean == facts:
		return
	facts = clean
	_save()


## Pulls "REMEMBER: ..." lines out of a reply. Returns {text, facts}.
func extract(reply: String) -> Dictionary:
	var found := PackedStringArray()
	for m in _remember_re.search_all(reply):
		found.append(m.get_string(1))
	return {text = _remember_re.sub(reply, "", true).strip_edges(), facts = found}


func prompt_block() -> String:
	if facts.is_empty():
		return ""
	return "# Things you remember about {user} (from past chats)\n- " + "\n- ".join(facts)


func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({facts = Array(facts)}, "  "))
	changed.emit()
