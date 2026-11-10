extends Node2D
## Sable desktop pet: window placement, input, tray, settings, and wiring
## between the cat, bubble, voice, brain, mood feed and event bus.

const CatScript := preload("res://scripts/cat.gd")
const BubbleScript := preload("res://scripts/bubble.gd")
const MoodScript := preload("res://scripts/mood_watcher.gd")
const Lines := preload("res://scripts/lines.gd")
const EventBusScript := preload("res://scripts/event_bus.gd")
const WatcherScript := preload("res://scripts/watcher.gd")
const BrainScript := preload("res://scripts/brain.gd")
const Situations := preload("res://scripts/situations.gd")
const VoiceScript := preload("res://scripts/voice.gd")
const SettingsScript := preload("res://scripts/settings.gd")
const SettingsWindowScript := preload("res://scripts/settings_window.gd")
const TrayScript := preload("res://scripts/tray.gd")
const Paths := preload("res://scripts/paths.gd")
const ChatWindowScript := preload("res://scripts/chat_window.gd")
const MemoryScript := preload("res://scripts/memory.gd")
const ActivityScript := preload("res://scripts/activity.gd")

## Base window size in viewport units (scaled up on high-DPI screens).
const WIN_SIZE := Vector2i(340, 420)
## Where the cat's feet sit, in viewport units.
const CAT_FOOT := Vector2(170, 412)
## Clickable box around the cat, including the tail.
const CAT_HIT := Rect2(80, 245, 200, 175)
## The bubble's bottom edge sits here, just above the cat's ears.
const BUBBLE_BOTTOM := 262.0
const EDGE_MARGIN := 40
## Unprompted lines (idle chatter, mood shifts) need this much quiet first.
const UNPROMPTED_GAP := 90.0
## Idle chatter only if nothing was said for this long.
const IDLE_QUIET := 10.0 * 60.0
## Frame rate when only the slow idle loop (breathing, tail, blinks) runs,
## and when something is actually moving.
const IDLE_FPS := 10
const ACTIVE_FPS := 30
## Longest text accepted from the UDP bus.
const MAX_BUS_TEXT := 600
const ICON_PATH := "res://icon.png"
## Chat: messages kept on disk, and how many are sent to the LLM as history.
const CHAT_PATH := "user://chat_history.json"
const CHAT_KEEP := 120  # bubble lines land in the thread too
const CHAT_CONTEXT := 20
## Screen peeks and chat pictures: saved as JPEGs, longest side capped.
const IMAGE_DIR := "user://chat_images"
const IMAGE_MAX := 1536
## Wandering: walking speed (viewport px/s) and how far one stroll goes.
const WALK_SPEED := 45.0
const WALK_MIN := 120
const WALK_MAX := 520
const DIARY_DIR := "user://diary"

var settings: SettingsScript
var cat: CatScript
var bubble: BubbleScript
var mood: MoodScript
var events: EventBusScript
var watcher: WatcherScript
var brain: BrainScript
var voice: VoiceScript
var tray: TrayScript
var settings_window: SettingsWindowScript
var chat_window: ChatWindowScript
var memory: MemoryScript
var activity: ActivityScript

var _scale := 1.0
var _dragging := false
var _drag_offset := Vector2i.ZERO
var _greeted := false
var _last_said := 0.0
var _idle_timer: Timer
var _say_seq := 0
var _last_line := ""
var _chat_history: Array = []  # [{role, content, t}]
var _wander_timer: Timer
var _walk_target_x := -1.0
var _walk_x := 0.0
var _diary_writing := false
var _last_chat_message := ""
## Sable's chat line before the user's latest message (context for memory extraction).
var _prev_sable_line := ""
## the user is away (no keyboard/mouse for away_minutes), per tools/idle_watch.ps1.
var _away := false
var _away_since := 0.0
var _away_thoughts: Array[String] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--render-icon"):
		set_process(false)
		_render_icon()
		return

	# One Sable at a time: if another instance owns the event port, ask it to
	# show itself and leave. (--allow-multiple is for testing.)
	events = EventBusScript.new()
	add_child(events)
	if not events.bound and not args.has("--allow-multiple"):
		events.send_local({src = "debug", show = true})
		set_process(false)
		set_process_input(false)
		get_tree().quit()
		return

	settings = SettingsScript.new()
	add_child(settings)
	settings.changed.connect(_on_setting_changed)

	var win := get_window()
	win.title = "Sable"
	_place_window()
	_apply_capture_flag()
	var icon := _load_icon()
	if icon:
		DisplayServer.set_icon(icon.get_image())
	if not args.has("--keep-taskbar"):
		OS.create_process("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
			"-File", Paths.file("tools/hide_from_taskbar.ps1"), "-ProcessId", str(OS.get_process_id())])
	# Reports the user's keyboard/mouse idle time over the bus; exits with Sable.
	if not args.has("--no-idle-watch") and FileAccess.file_exists(Paths.file("tools/idle_watch.ps1")):
		OS.create_process("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
			"-File", Paths.file("tools/idle_watch.ps1"), "-ProcessId", str(OS.get_process_id())])

	cat = CatScript.new()
	cat.position = CAT_FOOT
	add_child(cat)

	bubble = BubbleScript.new()
	bubble.center_x = CAT_FOOT.x
	bubble.anchor_bottom_y = BUBBLE_BOTTOM
	bubble.layout_changed.connect(_update_passthrough)
	add_child(bubble)

	voice = VoiceScript.new()
	voice.base_url = settings.get_value("tts_url")  # .env SABLE_TTS_URL is the default
	add_child(voice)
	voice.volume = settings.get_value("volume")
	_ensure_tts_server()

	memory = MemoryScript.new()
	add_child(memory)
	activity = ActivityScript.new()
	add_child(activity)

	brain = BrainScript.new()
	brain.base_url = settings.get_value("llm_url")  # .env SABLE_LLM_URL is the default
	brain.memory = memory
	brain.sleep_changed.connect(_on_sleep_changed)
	add_child(brain)

	mood = MoodScript.new()
	mood.cycle_debug = args.has("--cycle-moods")
	mood.mood_updated.connect(_on_mood_updated)
	add_child(mood)

	watcher = WatcherScript.new()
	watcher.moment.connect(_on_moment)
	watcher.flinch.connect(func(emotion: String) -> void: cat.emote(emotion, 1.5, 0.6))
	add_child(watcher)

	events.event_received.connect(_on_event)

	settings_window = SettingsWindowScript.new()
	settings_window.settings = settings
	settings_window.memory = memory
	settings_window.test_voice_requested.connect(
		func() -> void: _ask("{user} is testing your voice from the settings window. Say a line to show it off.",
			"Testing, testing. Yes, it's me. Try to contain yourself."))
	settings_window.open_diary_requested.connect(_open_diary_folder)
	add_child(settings_window)

	chat_window = ChatWindowScript.new()
	chat_window.face = icon
	chat_window.volume = settings.get_value("volume")
	chat_window.message_sent.connect(_on_chat_message)
	chat_window.clear_requested.connect(_clear_chat)
	add_child(chat_window)
	_load_chat()

	tray = TrayScript.new()
	tray.settings = settings
	tray.icon = icon
	tray.action.connect(_on_tray_action)
	add_child(tray)

	_idle_timer = Timer.new()
	_idle_timer.one_shot = true
	_idle_timer.timeout.connect(_on_idle)
	add_child(_idle_timer)
	_restart_idle_timer()

	_wander_timer = Timer.new()
	_wander_timer.one_shot = true
	_wander_timer.timeout.connect(_on_wander_timer)
	add_child(_wander_timer)
	_restart_wander_timer()

	# Diary: check now and then; the first check is a minute after startup so
	# a missed entry for yesterday gets written once the brain is up.
	var diary_timer := Timer.new()
	diary_timer.wait_time = 600.0
	diary_timer.autostart = true
	diary_timer.timeout.connect(_check_diary)
	add_child(diary_timer)
	get_tree().create_timer(60.0).timeout.connect(_check_diary)

	_update_passthrough()


# --- Window ----------------------------------------------------------------

## Pixel scale for a screen. Windows reports scaling via DPI, not screen_get_scale().
func _ui_scale(screen: int) -> float:
	var dpi := DisplayServer.screen_get_dpi(screen)
	return clampf(roundf(dpi / 96.0 * 4.0) / 4.0, 1.0, 3.0)


## Pick the screen first (saved position, else the current one), size the
## window for that screen's DPI, then position it.
func _place_window() -> void:
	var win := get_window()
	var saved := Vector2i(settings.get_value("window_x"), settings.get_value("window_y"))
	var screen := DisplayServer.window_get_current_screen()
	var use_saved := false
	if settings.get_value("remember_position") and saved.x >= 0:
		for s in DisplayServer.get_screen_count():
			if DisplayServer.screen_get_usable_rect(s).has_point(saved + Vector2i(10, 10)):
				screen = s
				use_saved = true
				break
	_set_scale(_ui_scale(screen))
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if use_saved:
		win.position = saved.clamp(usable.position, usable.end - win.size)
	else:
		win.position = usable.position + usable.size - win.size - Vector2i(EDGE_MARGIN, 0)


func _set_scale(s: float) -> void:
	_scale = s
	get_window().size = Vector2i(Vector2(WIN_SIZE) * _scale)


## After a drag: rescale if she moved to a monitor with different DPI, keep
## the whole window (and so the bubble) on that screen, remember the spot.
func _settle_after_drag() -> void:
	var win := get_window()
	var screen := DisplayServer.window_get_current_screen()
	var s := _ui_scale(screen)
	if not is_equal_approx(s, _scale):
		var feet := win.position + Vector2i(Vector2(CAT_FOOT) * _scale)
		_set_scale(s)
		win.position = feet - Vector2i(Vector2(CAT_FOOT) * _scale)
		_update_passthrough()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	win.position = win.position.clamp(usable.position, usable.end - win.size)
	if settings.get_value("remember_position"):
		settings.set_value("window_x", win.position.x)
		settings.set_value("window_y", win.position.y)


func _apply_capture_flag() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_EXCLUDE_FROM_CAPTURE, settings.get_value("hide_from_capture"))


## Imported texture when available (exported builds), else the raw PNG (dev
## runs without an editor import).
func _load_icon() -> Texture2D:
	if ResourceLoader.exists(ICON_PATH):
		var tex := load(ICON_PATH) as Texture2D
		if tex:
			return tex
	if FileAccess.file_exists(ICON_PATH):
		var img := Image.load_from_file(ICON_PATH)
		if img:
			return ImageTexture.create_from_image(img)
	return null


## Only the cat (and the bubble while it is showing) take mouse input.
## Everything else in the window passes clicks through to the desktop.
func _update_passthrough() -> void:
	var r: Rect2 = CAT_HIT
	if bubble.visible:
		r = r.merge(bubble.full_rect().grow(12))
	var poly := PackedVector2Array([
		r.position * _scale,
		Vector2(r.end.x, r.position.y) * _scale,
		r.end * _scale,
		Vector2(r.position.x, r.end.y) * _scale,
	])
	DisplayServer.window_set_mouse_passthrough(poly)


## Start tts/serve.ps1 (hidden) if voice is on, the venv exists, and nothing is
## listening on the TTS port yet. The server keeps running after Sable quits.
func _ensure_tts_server() -> void:
	if not settings.get_value("voice_enabled"):
		return
	var serve := Paths.file("tts/serve.ps1")
	if not FileAccess.file_exists(serve) or not DirAccess.dir_exists_absolute(Paths.file("tts/.venv")):
		return
	var url: String = voice.base_url
	var port := url.get_slice(":", 2).to_int() if url.count(":") >= 2 else 8890
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host("127.0.0.1", port) == OK:
		for i in 20:
			tcp.poll()
			if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTING:
				break
			await get_tree().create_timer(0.05).timeout
		if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			tcp.disconnect_from_host()
			return
	OS.create_process("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", serve])


# --- Input -----------------------------------------------------------------

func _input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if not mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT and _dragging:
			_dragging = false
			_settle_after_drag()
		return

	if mb.button_index == MOUSE_BUTTON_LEFT:
		var on_bubble := bubble.full_rect().has_point(get_local_mouse_position())
		if mb.double_click and on_bubble and not _last_line.is_empty():
			# Double-click a bubble: reply to it in the chat window.
			_open_chat(_last_line)
		elif bubble.visible and on_bubble:
			if not bubble.has_more_pages():
				voice.stop()  # closing the last page also ends the audio
			bubble.dismiss()
		elif mb.double_click:
			_dragging = false
			_poke()
		else:
			_stop_walking()
			_dragging = true
			_drag_offset = DisplayServer.mouse_get_position() - get_window().position
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		tray.popup_at_mouse()


func _process(delta: float) -> void:
	cat.talk = voice.level()
	if _dragging:
		get_window().position = DisplayServer.mouse_get_position() - _drag_offset
	elif _walk_target_x >= 0.0:
		_walk_step(delta)
	# Frame-rate governor: the idle loop is slow, so it doesn't need 30 fps.
	var busy := _dragging or voice.is_speaking() or bubble.visible or cat.is_active()
	var want := ACTIVE_FPS if busy else IDLE_FPS
	if Engine.max_fps != want:
		Engine.max_fps = want


func _poke() -> void:
	cat.poke()
	var line := Lines.pick("poke")
	brain.remember(line)
	_say(line)


# --- Tray and settings -----------------------------------------------------

func _on_tray_action(id: int) -> void:
	match id:
		TrayScript.SHOW:
			_set_pet_visible(not get_window().visible)
		TrayScript.MUTE:
			settings.set_value("voice_enabled", not settings.get_value("voice_enabled"))
		TrayScript.DND:
			settings.set_value("dnd", not settings.get_value("dnd"))
		TrayScript.VIBE:
			cat.emote("anticipation", 8.0)
			OS.create_process("node", [Paths.file("brain/sable_take.mjs"), "--from-tray"])
		TrayScript.SETTINGS:
			settings_window.open()
		TrayScript.CHAT:
			_open_chat()
		TrayScript.PEEK:
			_peek()
		TrayScript.QUIET:
			settings.set_value("quiet_hours", not settings.get_value("quiet_hours"))
		TrayScript.DIARY_NOW:
			_write_diary(ActivityScript.today(), true)
		TrayScript.DIARY_OPEN:
			_open_diary_folder()
		TrayScript.QUIT:
			get_tree().quit()


## Hidden Sable is fully quiet: no bubbles, no voice, no LLM calls.
func _set_pet_visible(on: bool) -> void:
	get_window().visible = on
	tray.set_pet_visible(on)
	if not on:
		voice.stop()
		bubble.hide_now()


func _on_setting_changed(key: String) -> void:
	match key:
		"volume":
			voice.volume = settings.get_value("volume")
			chat_window.volume = settings.get_value("volume")
		"wander", "wander_minutes":
			if not settings.get_value("wander"):
				_stop_walking()
			_restart_wander_timer()
		"voice_enabled", "quiet_hours", "quiet_start", "quiet_end":
			if not settings.voice_allowed():
				voice.stop()
			elif key == "voice_enabled":
				_ensure_tts_server()
		"dnd":
			if settings.get_value("dnd"):
				voice.stop()
				bubble.hide_now()
		"hide_from_capture":
			_apply_capture_flag()
		"idle_chatter", "idle_minutes_min", "idle_minutes_max":
			_restart_idle_timer()


# --- Talking ---------------------------------------------------------------

## Show a line and speak it. The bubble waits for the audio so text and voice
## start together; if voice is off, down or slow, it shows silently.
## Do not disturb or a hidden Sable suppresses both. A newer line wins.
## kind: "" for a normal line, "chat" for a chat reply (already in the thread),
## "thought" for a private musing while the user is away.
func _say(line: String, kind: String = "") -> void:
	if settings.get_value("dnd") or not get_window().visible:
		return
	_last_said = Time.get_unix_time_from_system()
	_last_line = line
	_say_seq += 1
	var seq := _say_seq
	var clip := {}
	if settings.voice_allowed() and not _away:  # nobody to hear it while the user is away
		clip = await voice.synthesize(line)
	if seq != _say_seq:
		print("[say] dropped (a newer line took over): ", line.left(40))
		return
	if kind != "chat":
		# Everything she says out loud also lands in the IM thread, so it reads
		# as one running conversation and the user can reply to it.
		_prev_sable_line = line
		_add_chat("assistant", line, kind)
		chat_window.add_sable(line, _hhmm(), false, kind == "thought")
	if clip.is_empty():
		print("[say] silent (voice allowed: %s, user away: %s): %s" % [settings.voice_allowed(), _away, line.left(40)])
		voice.stop()  # never leave an older clip talking under a new line
		bubble.say(line)
		return
	voice.play(clip)
	bubble.say(line, 0.0, (clip.stream as AudioStreamWAV).get_length())


## Ask the brain for a line and say it, unless something else was said while
## it was thinking (a late LLM reply must not replace a newer, more relevant
## line). Unprompted lines also respect a shared quiet gap.
func _ask(situation: String, fallback: String, unprompted: bool = false, ttl: float = 15.0) -> void:
	if settings.get_value("dnd") or not get_window().visible:
		return
	if unprompted and Time.get_unix_time_from_system() - _last_said < UNPROMPTED_GAP:
		return
	var seq := _say_seq
	var done := func(line: String) -> void:
		if _say_seq == seq:
			_say(line)
	brain.ask(situation, fallback, done, ttl)


## Routes bus events. "debug" packets let local scripts drive the pet directly:
##   {"src":"debug","say":"text"}            say exactly this
##   {"src":"debug","think":"situation"}     ask the LLM for a line about it
##   {"src":"debug","emote":"joy","seconds":4}
##   {"src":"debug","mute":true}             same as the tray's Mute voice
##   {"src":"debug","open":"settings"}       open the settings window ("chat" too)
##   {"src":"debug","chat":"text"}           send a chat message as the user
##     (add "image":"C:/path/pic.png" to send a picture with it)
##   {"src":"debug","peek":true}             look at the screen and comment
##   {"src":"debug","wander":true}           take a stroll now
##   {"src":"debug","diary":true}            write today's diary now
##   {"src":"debug","muse":true}             have a private thought now (if away)
## "system" packets come from tools/idle_watch.ps1: {"src":"system","idle":secs}
##   {"src":"debug","show":true}             show Sable (sent by a second launch)
## Anything local can send these; nothing leaves the machine. Text is capped.
func _on_event(ev: Dictionary) -> void:
	if ev.get("src", "") == "system":
		if ev.get("idle") is float:
			_on_idle_report(ev.idle)
		return
	if ev.get("src", "") == "debug":
		if ev.has("emote"):
			cat.emote(str(ev.emote), float(ev.get("seconds", 4.0)) if ev.get("seconds") is float else 4.0)
		if ev.has("say"):
			_say(str(ev.say).left(MAX_BUS_TEXT))
		if ev.has("think"):
			_ask(str(ev.think).left(MAX_BUS_TEXT), "")
		if ev.has("mute"):
			settings.set_value("voice_enabled", not (ev.mute == true))
		if str(ev.get("open", "")) == "settings":
			settings_window.open()
		if str(ev.get("open", "")) == "chat":
			_open_chat()
		if ev.has("chat"):  # type a chat message as the user (testing / scripting)
			_open_chat()
			var pic: Image = null
			if ev.has("image"):  # local image file to send along (testing)
				pic = Image.load_from_file(str(ev.image))
			_on_chat_message(str(ev.chat).left(MAX_BUS_TEXT), pic)
		if ev.get("peek", false) == true:
			_peek()
		if ev.get("wander", false) == true:
			_wander_timer.stop()
			_on_wander_timer()
		if ev.get("diary", false) == true:
			_write_diary(ActivityScript.today(), true)
		if ev.get("muse", false) == true and _away:
			_muse()
		if ev.get("show", false) == true:
			_set_pet_visible(true)
		return
	watcher.handle(ev)


func _on_mood_updated(emotion: String, level: int, intensity: float, emotion_changed: bool) -> void:
	cat.set_mood(emotion, intensity)
	brain.mood_text = "%s (level %d of 3)" % [emotion, level]
	if not brain.asleep:
		chat_window.set_mood(emotion)
	if not _greeted:
		_greeted = true
		_ask("The pet app just started and you appeared on {user}'s desktop. Greet them.", Lines.pick("greet"))
	elif emotion_changed:
		var cause := mood.last_trigger if not mood.last_trigger.is_empty() else "nothing in particular"
		activity.log_event("mood", "Your mood shifted to %s (cause: %s)" % [emotion, cause])
		_ask("Your own mood just shifted to %s. Cause, from {user}'s pi coding session: %s." % [emotion, cause],
			Lines.pick(emotion), true)


func _on_moment(line_key: String, emotion: String, info: Dictionary) -> void:
	# React instantly with the face; the words follow once the LLM answers.
	cat.emote(emotion, 10.0)
	var situation := Situations.describe(line_key, info)
	activity.log_event("claude", situation)
	_ask(situation, Lines.pick(line_key, info))


func _on_sleep_changed(asleep: bool, offline_secs: float) -> void:
	cat.set_sleeping(asleep)
	chat_window.set_offline(asleep)
	activity.log_event("brain", "Your brain went offline, you napped" if asleep
		else "Your brain came back after %d minutes" % int(offline_secs / 60.0))
	if asleep:
		_stop_walking()
		_say(Lines.pick("sleep"))
	else:
		_ask("You just woke up: your brain (the LLM server on {brain}) came back online after %d minutes offline." % int(offline_secs / 60.0),
			Lines.pick("wake"))


func _restart_idle_timer() -> void:
	var lo: float = settings.get_value("idle_minutes_min") * 60.0
	var hi: float = maxf(lo, settings.get_value("idle_minutes_max") * 60.0)
	_idle_timer.start(randf_range(lo, hi))


func _on_idle() -> void:
	_restart_idle_timer()
	if _away:
		_muse()
		return
	if not settings.get_value("idle_chatter") or settings.in_quiet_hours():
		return
	if Time.get_unix_time_from_system() - _last_said < IDLE_QUIET:
		return
	_ask("Nothing has happened for a while. Say something unprompted: a tease, an observation about the time of day or the work, or a musing about life as a cat living on a GPU.",
		Lines.pick("idle"), true, 30.0)


# --- Away detection ----------------------------------------------------------

## Idle seconds from tools/idle_watch.ps1 (about every 20 s).
func _on_idle_report(idle_secs: float) -> void:
	var threshold: float = settings.get_value("away_minutes") * 60.0
	if not _away and idle_secs >= threshold:
		_away = true
		_away_since = Time.get_unix_time_from_system() - idle_secs
		_away_thoughts.clear()
		voice.stop()
		activity.log_event("away", "{user} stepped away from their desk")
	elif _away and idle_secs < 60.0:
		_away = false
		var minutes := int((Time.get_unix_time_from_system() - _away_since) / 60.0)
		activity.log_event("away", "{user} came back after %d minutes away" % minutes)
		var situation := "{user} just came back to their desk after %d minutes away." % minutes
		if not _away_thoughts.is_empty():
			situation += " While they were gone your mind wandered; you thought: " + " / ".join(_away_thoughts)
		_ask(situation + " Welcome them back.", "Oh, you're back. I was busy. Thinking. Important cat things.")


## While the user is away: a private, silent musing (bubble only, logged for the
## diary), if allowed. Ignores quiet hours on purpose; off-hours musings
## are the fun part.
func _muse() -> void:
	if not settings.get_value("away_wander") or settings.get_value("dnd") or brain.asleep:
		return
	var minutes := int((Time.get_unix_time_from_system() - _away_since) / 60.0)
	var situation := "{user} has been away from their desk for %d minutes and nobody is watching. Let your mind wander: a private thought to yourself about the quiet machine, the night, the GPUs humming, the code they left half-done, or your strange life as a cat living on a GPU. Talk to yourself, not to {user}." % minutes
	var seq := _say_seq
	var done := func(line: String) -> void:
		_on_musing(line, seq)
	brain.ask(situation, "", done, 30.0)


func _on_musing(line: String, seq: int) -> void:
	_away_thoughts.append(line)
	while _away_thoughts.size() > 3:
		_away_thoughts.pop_front()
	activity.log_event("thought", "While {user} was away you thought: " + line)
	if _say_seq == seq and _away:
		_say(line, "thought")  # silent while away: _say skips the voice


# --- Chat (AIM/ICQ-style window) -------------------------------------------

## Open the chat window. reply_to: a bubble line the user double-clicked, added to
## the thread as Sable's message so their reply has context.
func _open_chat(reply_to: String = "") -> void:
	if not reply_to.is_empty():
		# Spoken lines are already in the thread; only add one that isn't
		# among the recent messages (e.g. said while DND was just toggled).
		var known := false
		for m in _chat_history.slice(-10):
			known = known or str(m.get("content", "")) == reply_to
		if not known:
			_add_chat("assistant", reply_to)
			chat_window.add_sable(reply_to, _hhmm(), false)
		_prev_sable_line = reply_to
	chat_window.open_chat()


## image: a picture pasted or dropped into the chat window, or null.
func _on_chat_message(text: String, image: Image = null) -> void:
	_last_chat_message = text
	var image_path := _save_chat_image(image) if image else ""
	_add_chat("user", text, "", image_path)
	chat_window.add_user(text, _hhmm(), image_path)
	activity.log_event("chat", "{user} said to you in chat: " + text.left(160) + (" (with an image)" if image else ""))
	chat_window.set_typing(true)
	cat.emote("anticipation", 8.0)
	brain.chat(_llm_history(), _chat_context(), _on_chat_reply, _on_chat_tool)


## She's using a tool mid-reply: say so in the status line and the thread, so
## it's visible what left the machine.
func _on_chat_tool(tool_name: String, detail: String) -> void:
	match tool_name:
		"web_search":
			chat_window.set_typing(true, "is searching")
			chat_window.add_note("searched the web for \"%s\"" % detail, _hhmm())
		"fetch_page":
			chat_window.set_typing(true, "is reading")
			chat_window.add_note("read " + detail, _hhmm())


## Recent thread as LLM messages. Bubble lines make runs of assistant
## messages, so consecutive same-role turns are merged and the list starts
## with a user turn (some chat templates insist on strict user/assistant
## alternation). Her opening lines stay, behind a placeholder user turn, so
## she remembers what she said before the user typed anything.
## Only the newest image is actually sent (images are expensive to encode);
## older ones become a short "[image]" note.
func _llm_history() -> Array:
	var recent: Array = _chat_history.slice(-CHAT_CONTEXT)
	var newest_image := -1
	for i in recent.size():
		if not str(recent[i].get("image", "")).is_empty():
			newest_image = i
	var history: Array = []
	for i in recent.size():
		var m: Dictionary = recent[i]
		var text := str(m.content)
		if m.get("kind", "") == "thought":
			text = "(thinking to yourself while {user} was away) " + text
		var parts: Array = [{type = "text", text = text}]
		var image := str(m.get("image", ""))
		if not image.is_empty():
			var jpg := FileAccess.get_file_as_bytes(image) if i == newest_image else PackedByteArray()
			if jpg.is_empty():
				parts[0].text += " [image]"
			else:
				parts.append({type = "image_url", image_url = {url = "data:image/jpeg;base64," + Marshalls.raw_to_base64(jpg)}})
		if history.is_empty() and m.role != "user":
			history.append({role = "user", content = [{type = "text", text = "({user} is working; you speak up on your own now and then in your desktop bubble.)"}]})
		if not history.is_empty() and history.back().role == m.role:
			history.back().content.append({type = "text", text = "\n\n"})
			history.back().content.append_array(parts)
		else:
			history.append({role = m.role, content = parts})
	# Text-only turns go back to plain strings (simplest for every chat template).
	for h in history:
		var only_text := true
		var joined := ""
		for p in h.content:
			only_text = only_text and p.type == "text"
			joined += str(p.get("text", ""))
		if only_text:
			h.content = joined
	return history


# --- Images: screen peeks and pictures in chat --------------------------------

## Save a chat image (downscaled JPEG) and return its user:// path.
func _save_chat_image(img: Image) -> String:
	var copy := img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGB8)
	var longest := maxi(copy.get_width(), copy.get_height())
	if longest > IMAGE_MAX:
		var s := float(IMAGE_MAX) / longest
		copy.resize(int(copy.get_width() * s), int(copy.get_height() * s), Image.INTERPOLATE_LANCZOS)
	DirAccess.make_dir_recursive_absolute(IMAGE_DIR)
	var path := IMAGE_DIR.path_join("%d_%d.jpg" % [Time.get_unix_time_from_system(), randi() % 10000])
	copy.save_jpg(path, 0.82)
	return path


## "What do you make of my screen?": give the user a moment to point the mouse
## at the screen they mean, grab it (with Sable herself excluded), and ask
## the vision model for a reaction. Only ever on an explicit request.
func _peek() -> void:
	if brain.asleep:
		_say_or_chat("I can't see anything with my brain offline.")
		return
	cat.emote("anticipation", 6.0)
	if DisplayServer.get_screen_count() > 1:
		_say_or_chat("Show me. Put the mouse on the screen you mean.")
		await get_tree().create_timer(3.0).timeout
	else:
		await get_tree().create_timer(0.4).timeout  # let the menu close
	var shot := await _grab_screen()
	if shot == null:
		_say_or_chat("I tried to look and saw nothing. Windows wouldn't let me.")
		return
	var path := _save_chat_image(shot)
	_add_chat("user", "(You took a peek at {user}'s screen. Screenshot attached.)", "peek", path)
	chat_window.add_peek(path, _hhmm())
	activity.log_event("peek", "You peeked at {user}'s screen when asked")
	cat.emote("surprise", 4.0)
	var jpg := FileAccess.get_file_as_bytes(path)
	brain.look("{user} asked what you make of their screen; the screenshot is attached. React to something specific you can actually see (an app, code, an error, a window title, the tab situation). For this one you may use up to two short sentences, max 40 words.",
		Marshalls.raw_to_base64(jpg), _on_peek_line)


func _on_peek_line(line: String) -> void:
	_say_or_chat(line if not line.is_empty() else "I looked. I have no words. Or my brain timed out.")


## Explicit requests should answer even under Do Not Disturb: then the reply
## goes to the chat window instead of the bubble.
func _say_or_chat(line: String) -> void:
	if settings.get_value("dnd") or not get_window().visible:
		_add_chat("assistant", line)
		chat_window.add_sable(line, _hhmm())
		_open_chat()
	else:
		_say(line)


## The screen under the mouse, with Sable and her chat window excluded from
## the capture. Ultra-wide screens are cropped to a 16:9 area centered on the
## mouse, so text stays readable after downscaling.
func _grab_screen() -> Image:
	var flag := DisplayServer.WINDOW_FLAG_EXCLUDE_FROM_CAPTURE
	var chat_id := chat_window.get_window_id()
	DisplayServer.window_set_flag(flag, true)
	if chat_id != DisplayServer.INVALID_WINDOW_ID:
		DisplayServer.window_set_flag(flag, true, chat_id)
	await get_tree().process_frame
	await get_tree().process_frame
	var mouse := DisplayServer.mouse_get_position()
	var screen := DisplayServer.get_primary_screen()
	for i in DisplayServer.get_screen_count():
		if Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)).has_point(mouse):
			screen = i
	var img := DisplayServer.screen_get_image(screen)
	_apply_capture_flag()
	if chat_id != DisplayServer.INVALID_WINDOW_ID:
		DisplayServer.window_set_flag(flag, false, chat_id)
	if img == null or img.is_empty():
		return null
	var w := img.get_width()
	var h := img.get_height()
	if w > h * 2:
		var crop_w := int(h * 16.0 / 9.0)
		var local_x := mouse.x - DisplayServer.screen_get_position(screen).x
		var x := clampi(local_x - crop_w / 2, 0, w - crop_w)
		img = img.get_region(Rect2i(x, 0, crop_w, h))
	return img


func _on_chat_reply(raw: String) -> void:
	chat_window.set_typing(false)
	if raw.strip_edges().is_empty():
		chat_window.add_away(_hhmm())
		return
	var parts: Dictionary = memory.extract(raw)
	for fact in parts.facts:
		memory.add(fact)
	if parts.facts.is_empty():
		# Runs in the background; uses the line before this exchange as context.
		brain.extract_fact(_last_chat_message, _prev_sable_line, memory.facts, _add_facts)
	var text: String = brain.clean_block(parts.text)
	if text.is_empty():
		text = "..."
	_prev_sable_line = text
	_add_chat("assistant", text)
	chat_window.add_sable(text, _hhmm())
	brain.remember(text.left(160))
	if settings.get_value("speak_chat"):
		_say(text, "chat")


func _add_facts(lines: String) -> void:
	for fact in lines.split("\n", false):
		memory.add(fact)


## Time, mood and what she has noticed today, appended to the chat prompt.
func _chat_context() -> String:
	var lines := PackedStringArray(["# Right now", "Local time: " + brain.clock(), "Your current mood: " + brain.mood_text])
	var recent := activity.recent(8, ["chat"])
	if not recent.is_empty():
		lines.append("Things you noticed on {user}'s screen today (most recent last):")
		for e in recent:
			lines.append("- %s %s" % [e.t, e.text])
	return "\n".join(lines)


func _add_chat(role: String, content: String, kind: String = "", image_path: String = "") -> void:
	var m := {role = role, content = content, t = _hhmm()}
	if not kind.is_empty():
		m.kind = kind
	if not image_path.is_empty():
		m.image = image_path
	_chat_history.append(m)
	while _chat_history.size() > CHAT_KEEP:
		var old: Dictionary = _chat_history.pop_front()
		if old.has("image"):
			DirAccess.remove_absolute(str(old.image))
	var f := FileAccess.open(CHAT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_chat_history))


func _load_chat() -> void:
	if FileAccess.file_exists(CHAT_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(CHAT_PATH))
		if typeof(data) == TYPE_ARRAY:
			for m in data:
				if typeof(m) == TYPE_DICTIONARY and m.has("role") and m.has("content"):
					_chat_history.append(m)
					if m.role == "assistant":
						_prev_sable_line = str(m.content)
	chat_window.load_history(_chat_history)


func _clear_chat() -> void:
	_chat_history = []
	if FileAccess.file_exists(CHAT_PATH):
		DirAccess.remove_absolute(CHAT_PATH)
	if DirAccess.dir_exists_absolute(IMAGE_DIR):
		for f in DirAccess.get_files_at(IMAGE_DIR):
			DirAccess.remove_absolute(IMAGE_DIR.path_join(f))
	chat_window.load_history([])


static func _hhmm() -> String:
	return Time.get_time_string_from_system().left(5)


# --- Wandering -------------------------------------------------------------

func _restart_wander_timer() -> void:
	var m: float = settings.get_value("wander_minutes") * 60.0
	_wander_timer.start(randf_range(m * 0.6, m * 1.4))


## Take a stroll along the bottom of the screen, if nothing else is going on.
func _on_wander_timer() -> void:
	_restart_wander_timer()
	if not settings.get_value("wander") or settings.get_value("dnd") or brain.asleep:
		return
	if not get_window().visible or _dragging or bubble.visible or voice.is_speaking():
		return
	var win := get_window()
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var lo := float(usable.position.x)
	var hi := float(usable.end.x - win.size.x)
	if hi - lo < WALK_MIN * _scale:
		return
	var x := float(win.position.x)
	var dist := randf_range(WALK_MIN, WALK_MAX) * _scale
	var dir := -1 if randf() < 0.5 else 1
	if x + dir * dist > hi or x + dir * dist < lo:
		dir = -dir  # not enough room that way: turn around
	_walk_x = x
	_walk_target_x = clampf(x + dir * dist, lo, hi)
	cat.set_walking(dir)


func _walk_step(delta: float) -> void:
	var dir := signf(_walk_target_x - _walk_x)
	_walk_x += dir * WALK_SPEED * _scale * delta
	var arrived := dir == 0.0 or (dir > 0.0 and _walk_x >= _walk_target_x) or (dir < 0.0 and _walk_x <= _walk_target_x)
	if arrived:
		_walk_x = _walk_target_x
	get_window().position.x = int(_walk_x)
	if arrived:
		_stop_walking()
		_settle_after_drag()  # clamps and remembers the new spot


func _stop_walking() -> void:
	_walk_target_x = -1.0
	if cat:
		cat.set_walking(0)


# --- Diary -----------------------------------------------------------------

## Writes yesterday's entry if it was missed (PC off, app closed), and today's
## once it's past the diary hour and something happened.
func _check_diary() -> void:
	if not settings.get_value("diary") or _diary_writing or brain.asleep:
		return
	var y := ActivityScript.yesterday()
	if not _diary_exists(y) and not activity.read_day(y).is_empty():
		_write_diary(y, false)
		return
	var today := ActivityScript.today()
	var hour: int = Time.get_datetime_dict_from_system().hour
	if hour >= int(settings.get_value("diary_hour")) and not _diary_exists(today) \
			and not activity.read_day(today).is_empty():
		_write_diary(today, false)


func _write_diary(date: String, manual: bool) -> void:
	if _diary_writing:
		return
	if brain.asleep:
		if manual:
			_say("Can't write the diary right now, my brain's offline.")
		return
	_diary_writing = true
	var lines := PackedStringArray()
	for e in activity.read_day(date).slice(-80):
		if e.get("kind", "") != "diary":
			lines.append("- %s [%s] %s" % [e.get("t", ""), e.get("kind", ""), e.get("text", "")])
	var log_text := "\n".join(lines) if not lines.is_empty() else "(nothing was logged; a quiet day)"
	var prompt := "Date: %s\n\nThe day's log (local times):\n%s\n\nWrite tonight's diary entry." % [_date_label(date), log_text]
	if manual:
		cat.emote("anticipation", 10.0)
	brain.write("diary_rules.md", prompt, 380, func(text: String) -> void: _on_diary_written(date, text, manual))


func _on_diary_written(date: String, text: String, manual: bool) -> void:
	_diary_writing = false
	if text.is_empty():
		if manual:
			_say("The diary didn't come out. Brain fog. Try again later.")
		return
	DirAccess.make_dir_recursive_absolute(DIARY_DIR)
	var f := FileAccess.open(_diary_path(date), FileAccess.WRITE)
	if f == null:
		return
	f.store_string("# Sable's diary - %s\n\n%s\n" % [_date_label(date), text])
	f.close()
	activity.log_event("diary", "You wrote your diary for " + date)
	cat.emote("trust", 5.0)
	_say(Lines.pick("diary"))


func _diary_path(date: String) -> String:
	return DIARY_DIR.path_join(date + ".md")


func _diary_exists(date: String) -> bool:
	return FileAccess.file_exists(_diary_path(date))


static func _date_label(date: String) -> String:
	var d := Time.get_datetime_dict_from_datetime_string(date + "T12:00:00", true)
	return "%s %s" % [BrainScript.WEEKDAYS[d.weekday], date]


func _open_diary_folder() -> void:
	DirAccess.make_dir_recursive_absolute(DIARY_DIR)
	OS.shell_open(ProjectSettings.globalize_path(DIARY_DIR))


# --- Icon rendering (run with: -- --render-icon) ----------------------------

## Draws the cat's head into icon.png and icon.ico (16-256 px) in the project
## folder, then quits. Re-run after changing the cat's look.
func _render_icon() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(256, 256)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var c := CatScript.new()
	c.scale = Vector2(2.35, 2.35)
	c.position = Vector2(128, 128 + 96 * 2.35)  # center on the head
	vp.add_child(c)
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://")
	img.save_png(dir.path_join("icon.png"))
	var sizes := [16, 24, 32, 48, 64, 128, 256]
	var pngs: Array[PackedByteArray] = []
	for s in sizes:
		var copy := img.duplicate() as Image
		copy.resize(s, s, Image.INTERPOLATE_LANCZOS)
		pngs.append(copy.save_png_to_buffer())
	var n := sizes.size()
	var ico := PackedByteArray()
	ico.resize(6 + 16 * n)
	ico.encode_u16(2, 1)  # type: icon
	ico.encode_u16(4, n)
	var offset := 6 + 16 * n
	for i in n:
		var e := 6 + 16 * i
		var px: int = sizes[i] % 256  # 256 is stored as 0
		ico.encode_u8(e, px)
		ico.encode_u8(e + 1, px)
		ico.encode_u16(e + 4, 1)   # planes
		ico.encode_u16(e + 6, 32)  # bits per pixel
		ico.encode_u32(e + 8, pngs[i].size())
		ico.encode_u32(e + 12, offset)
		offset += pngs[i].size()
	for p in pngs:
		ico.append_array(p)
	var f := FileAccess.open(dir.path_join("icon.ico"), FileAccess.WRITE)
	f.store_buffer(ico)
	f.close()
	print("Wrote icon.png and icon.ico to ", dir)
	get_tree().quit()
