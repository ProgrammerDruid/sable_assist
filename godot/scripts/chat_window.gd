extends Window
## AIM/ICQ-style instant-message window with Sable. Main owns the conversation
## (history, LLM calls); this is just the retro UI: buddy header, thread,
## "Sable is typing...", input box and little sounds.

signal message_sent(text: String)
signal clear_requested

const Sfx := preload("res://scripts/sfx.gd")
const Env := preload("res://scripts/env.gd")
const BG := Color("d4d0c8")          # classic dialog gray
const THREAD_BG := Color.WHITE
const USER_COLOR := "#c00000"
const SABLE := "#0030c0"

var face: Texture2D
var volume := 0.8

var _thread: RichTextLabel
var _input: TextEdit
var _typing: Label
var _mood: Label
var _sfx: AudioStreamPlayer
var _typing_dots := 0
var _typing_timer: Timer


func _init() -> void:
	title = "Sable - Instant Message"
	size = Vector2i(400, 500)
	min_size = Vector2i(320, 360)
	visible = false
	wrap_controls = true
	close_requested.connect(close_chat)


func _ready() -> void:
	theme = _make_theme()

	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	# Buddy header: face, name, mood, clear button.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	var face_rect := TextureRect.new()
	face_rect.texture = face
	face_rect.custom_minimum_size = Vector2(44, 44)
	face_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(face_rect)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(names)
	var name_label := Label.new()
	name_label.text = "Sable"
	name_label.add_theme_font_size_override("font_size", 17)
	names.add_child(name_label)
	_mood = Label.new()
	_mood.text = "Online"
	_mood.add_theme_color_override("font_color", Color("505050"))
	names.add_child(_mood)
	var clear := Button.new()
	clear.text = "Clear"
	clear.tooltip_text = "Forget this conversation (long-term memories stay; edit those in Settings)"
	clear.pressed.connect(func() -> void: clear_requested.emit())
	header.add_child(clear)

	_thread = RichTextLabel.new()
	_thread.bbcode_enabled = true
	_thread.scroll_following = true
	_thread.selection_enabled = true
	_thread.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_thread)

	_typing = Label.new()
	_typing.text = " "
	_typing.add_theme_color_override("font_color", Color("606060"))
	box.add_child(_typing)

	var row := HBoxContainer.new()
	box.add_child(row)
	_input = TextEdit.new()
	_input.custom_minimum_size = Vector2(0, 64)
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.placeholder_text = "Type a message (Enter to send, Shift+Enter for a new line)"
	_input.gui_input.connect(_on_input_key)
	row.add_child(_input)
	var send := Button.new()
	send.text = "Send"
	send.custom_minimum_size = Vector2(64, 0)
	send.pressed.connect(_send)
	row.add_child(send)

	_sfx = AudioStreamPlayer.new()
	add_child(_sfx)

	_typing_timer = Timer.new()
	_typing_timer.wait_time = 0.4
	_typing_timer.timeout.connect(_tick_typing)
	add_child(_typing_timer)


func open_chat() -> void:
	if not visible:
		popup_centered()
		_play(Sfx.door_open())
	grab_focus()
	_input.grab_focus()
	_scroll_to_end()


func close_chat() -> void:
	if visible:
		_play(Sfx.door_close())
	hide()


func set_mood(emotion: String) -> void:
	if _mood:
		_mood.text = "Online - feeling " + emotion


func set_offline(offline: bool) -> void:
	if _mood:
		_mood.text = "Away (brain offline)" if offline else "Online"


func set_typing(on: bool) -> void:
	_typing_dots = 0
	_typing.text = "Sable is typing" if on else " "
	if on:
		_typing_timer.start()
	else:
		_typing_timer.stop()


## Rebuild the thread from saved history (array of {role, content, t}).
func load_history(history: Array) -> void:
	_thread.clear()
	for m in history:
		var is_user: bool = m.get("role", "user") == "user"
		var thought: bool = m.get("kind", "") == "thought"
		_append(is_user, str(m.get("content", "")), str(m.get("t", "")), "thought" if thought else "")
	_scroll_to_end()


func add_user(text: String, t: String) -> void:
	_append(true, text, t)


## thought: a private musing while the user was away (shown in italics, gray).
func add_sable(text: String, t: String, sound: bool = true, thought: bool = false) -> void:
	_append(false, text, t, "thought" if thought else "")
	if sound:
		_play(Sfx.receive())


func add_away(t: String) -> void:
	_append(false, Env.sub("brb. My brain ({brain}) isn't answering right now. Try again in a bit."), t, "auto")
	_play(Sfx.receive())


## style: "" normal, "auto" (away auto-response), "thought" (musing to herself).
func _append(is_user: bool, text: String, t: String, style: String = "") -> void:
	var col := USER_COLOR if is_user else SABLE
	var stamp := " [color=#808080](%s)[/color]" % t if not t.is_empty() else ""
	var label := Env.user_name() if is_user else "Sable"
	var body := _escape(text)
	match style:
		"auto":
			label = "Auto response from Sable"
			body = "[i]" + body + "[/i]"
		"thought":
			label = "Sable (to herself)"
			body = "[i][color=#606060]" + body + "[/color][/i]"
	_thread.append_text("[color=%s][b]%s[/b][/color]%s: %s\n" % [col, label, stamp, body])
	_scroll_to_end()


## scroll_following alone is unreliable: text appended while the window is
## hidden, or before autowrap has laid out, leaves the view parked at the
## top. Jump to the newest line once layout has settled.
func _scroll_to_end() -> void:
	if not is_instance_valid(_thread) or not is_inside_tree():
		return
	await get_tree().process_frame
	if is_instance_valid(_thread):
		var bar := _thread.get_v_scroll_bar()
		bar.value = bar.max_value  # clamps to the last page


func _on_input_key(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and not k.shift_pressed:
		_input.accept_event()
		_send()


func _send() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_input.text = ""
	_play(Sfx.send())
	message_sent.emit(text.left(2000))


func _tick_typing() -> void:
	_typing_dots = (_typing_dots + 1) % 4
	_typing.text = "Sable is typing" + ".".repeat(_typing_dots)


func _play(stream: AudioStream) -> void:
	_sfx.stream = stream
	_sfx.volume_db = linear_to_db(maxf(volume, 0.001))
	_sfx.play()


static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


func _make_theme() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Tahoma", "Verdana", "Segoe UI"])
	t.default_font = font
	t.default_font_size = 13
	# [b] and [i] in the thread need real bold/italic faces of the same font.
	var bold := SystemFont.new()
	bold.font_names = font.font_names
	bold.font_weight = 700
	t.set_font("bold_font", "RichTextLabel", bold)
	var italic := SystemFont.new()
	italic.font_names = font.font_names
	italic.font_italic = true
	t.set_font("italics_font", "RichTextLabel", italic)

	var panel := StyleBoxFlat.new()
	panel.bg_color = BG
	t.set_stylebox("panel", "Panel", panel)

	var well := StyleBoxFlat.new()
	well.bg_color = THREAD_BG
	well.border_color = Color("808080")
	well.set_border_width_all(1)
	well.set_content_margin_all(6)
	t.set_stylebox("normal", "RichTextLabel", well)
	t.set_stylebox("normal", "TextEdit", well)
	t.set_stylebox("focus", "TextEdit", well)
	t.set_color("default_color", "RichTextLabel", Color.BLACK)
	t.set_color("font_color", "TextEdit", Color.BLACK)
	t.set_color("font_placeholder_color", "TextEdit", Color("909090"))
	t.set_color("caret_color", "TextEdit", Color.BLACK)
	t.set_color("selection_color", "TextEdit", Color("316ac5"))
	t.set_color("font_color", "Label", Color.BLACK)

	for state in ["normal", "hover", "pressed", "focus"]:
		var b := StyleBoxFlat.new()
		b.bg_color = Color("e4e0d8") if state != "pressed" else Color("c8c4bc")
		b.border_color = Color("404040") if state != "hover" else Color("316ac5")
		b.set_border_width_all(1)
		b.set_content_margin_all(4)
		t.set_stylebox(state, "Button", b)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", Color.BLACK)
	return t
