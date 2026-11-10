extends Window
## Settings window, opened from the tray menu. Every control writes straight
## to the settings node, so changes apply live and persist immediately.

const Env := preload("res://scripts/env.gd")
const Paths := preload("res://scripts/paths.gd")

signal test_voice_requested
signal open_diary_requested

var settings: Node  # settings.gd
var memory: Node    # memory.gd
var _hook_cfg_path := ""
var _deny_edit: LineEdit
var _memory_edit: TextEdit


func _init() -> void:
	title = "Sable Settings"
	size = Vector2i(460, 640)
	min_size = Vector2i(420, 480)
	transient = false
	exclusive = false
	unresizable = false
	wrap_controls = true
	visible = false
	close_requested.connect(hide)


func _ready() -> void:
	_hook_cfg_path = Paths.file("claude-hooks/pet-hook.config.json")

	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	scroll.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	_header(box, "Voice")
	_check(box, "Speak lines out loud", "voice_enabled")
	_slider(box, "Volume", "volume")
	var test := Button.new()
	test.text = "Test voice"
	test.pressed.connect(func() -> void: test_voice_requested.emit())
	box.add_child(test)

	_header(box, "Behavior")
	_check(box, "Do not disturb (no bubbles, no voice)", "dnd")
	_check(box, "Unprompted idle chatter", "idle_chatter")
	_spin(box, "Idle chatter at least every (min)", "idle_minutes_min", 5, 240)
	_spin(box, "Idle chatter at most every (min)", "idle_minutes_max", 5, 480)
	_check(box, "Quiet hours (no voice, no idle chatter)", "quiet_hours")
	_spin(box, "Quiet hours start (hour)", "quiet_start", 0, 23)
	_spin(box, "Quiet hours end (hour)", "quiet_end", 0, 23)

	_header(box, "Window")
	_check(box, "Hide Sable from screen sharing and recordings", "hide_from_capture")
	_check(box, "Remember position", "remember_position")
	_check(box, "Wander along the taskbar now and then", "wander")
	_spin(box, "Wander about every (min)", "wander_minutes", 2, 120)

	_header(box, "When I'm away")
	_spin(box, "Away after no keyboard/mouse for (min)", "away_minutes", 2, 120)
	_check(box, "Let her mind wander while I'm away (silent musings, even in quiet hours)", "away_wander")

	_header(box, "Chat")
	_check(box, "Chat replies also pop in the bubble and are spoken", "speak_chat")

	_header(box, "Diary")
	_check(box, "Write a diary entry each evening", "diary")
	_spin(box, "Diary time (hour)", "diary_hour", 0, 23)
	var open_diary := Button.new()
	open_diary.text = "Open diary folder"
	open_diary.pressed.connect(func() -> void: open_diary_requested.emit())
	box.add_child(open_diary)

	_header(box, "Memory")
	var mem_label := Label.new()
	mem_label.text = "Things Sable remembers about you, one per line. She adds to this when you tell her things in chat. Edit or delete freely."
	mem_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(mem_label)
	_memory_edit = TextEdit.new()
	_memory_edit.custom_minimum_size = Vector2(0, 120)
	_memory_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_memory_edit.placeholder_text = "(nothing yet)"
	_memory_edit.focus_exited.connect(_save_memory)
	box.add_child(_memory_edit)
	var forget := Button.new()
	forget.text = "Forget everything"
	forget.pressed.connect(_forget_all)
	box.add_child(forget)
	if memory:
		memory.changed.connect(_load_memory)
		_load_memory()

	_header(box, "Claude Code")
	var deny_label := Label.new()
	deny_label.text = "Ignore these projects (folder names or path prefixes, comma separated)"
	deny_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(deny_label)
	_deny_edit = LineEdit.new()
	_deny_edit.text = ", ".join(_read_deny())
	_deny_edit.placeholder_text = "e.g. main, C:/dev/secret"
	_deny_edit.text_submitted.connect(func(_t: String) -> void: _write_deny())
	_deny_edit.focus_exited.connect(_write_deny)
	box.add_child(_deny_edit)

	_header(box, "Servers (restart Sable after changing)")
	_line(box, "LLM (llama.cpp)", "llm_url")
	_line(box, "TTS (Pocket TTS)", "tts_url")

	var env_note := Label.new()
	env_note.text = "Sable calls you %s. Your name, voice, persona folder and server defaults live in %s (run setup.ps1 -Customize to change them)." % [
		Env.user_name(), Paths.file(".env")]
	env_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(env_note)

	var where := Label.new()
	where.text = "Saved to " + ProjectSettings.globalize_path("user://settings.cfg")
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.modulate = Color(1, 1, 1, 0.55)
	box.add_child(where)


func open() -> void:
	if not visible:
		_load_memory()
		popup_centered()
	grab_focus()


func _load_memory() -> void:
	if memory and _memory_edit and not _memory_edit.has_focus():
		_memory_edit.text = "\n".join(memory.facts)


func _forget_all() -> void:
	_memory_edit.text = ""
	_save_memory()


func _save_memory() -> void:
	if memory:
		memory.set_all(_memory_edit.text.split("\n", false))


# --- builders --------------------------------------------------------------

func _header(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", Color(0.72, 0.64, 1.0))
	box.add_child(HSeparator.new())
	box.add_child(l)


func _check(box: VBoxContainer, text: String, key: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = settings.get_value(key)
	c.toggled.connect(func(on: bool) -> void: settings.set_value(key, on))
	box.add_child(c)


func _row(box: VBoxContainer, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	box.add_child(row)
	return row


func _slider(box: VBoxContainer, text: String, key: String) -> void:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = settings.get_value(key)
	s.custom_minimum_size = Vector2(180, 0)
	s.value_changed.connect(func(v: float) -> void: settings.set_value(key, v, false))
	s.drag_ended.connect(func(_changed: bool) -> void: settings.save())
	_row(box, text).add_child(s)


func _spin(box: VBoxContainer, text: String, key: String, lo: int, hi: int) -> void:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = settings.get_value(key)
	s.value_changed.connect(func(v: float) -> void: settings.set_value(key, int(v)))
	_row(box, text).add_child(s)


func _line(box: VBoxContainer, text: String, key: String) -> void:
	var e := LineEdit.new()
	e.text = settings.get_value(key)
	e.custom_minimum_size = Vector2(220, 0)
	var commit := func(_t: String = "") -> void: settings.set_value(key, e.text.strip_edges())
	e.text_submitted.connect(commit)
	e.focus_exited.connect(commit)
	_row(box, text).add_child(e)


# --- Claude hook deny list (claude-hooks/pet-hook.config.json) --------------

func _read_deny() -> PackedStringArray:
	if not FileAccess.file_exists(_hook_cfg_path):
		return PackedStringArray()
	var data = JSON.parse_string(FileAccess.get_file_as_string(_hook_cfg_path))
	if typeof(data) != TYPE_DICTIONARY:
		return PackedStringArray()
	return PackedStringArray(data.get("deny", []))


func _write_deny() -> void:
	var items := PackedStringArray()
	for part in _deny_edit.text.split(",", false):
		if not part.strip_edges().is_empty():
			items.append(part.strip_edges())
	var data := {}
	if FileAccess.file_exists(_hook_cfg_path):
		var existing = JSON.parse_string(FileAccess.get_file_as_string(_hook_cfg_path))
		if typeof(existing) == TYPE_DICTIONARY:
			data = existing
	if PackedStringArray(data.get("deny", [])) == items:
		return
	data["deny"] = Array(items)
	var f := FileAccess.open(_hook_cfg_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  ") + "\n")
