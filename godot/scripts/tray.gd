extends Node
## Windows tray icon for Sable. Left-click toggles her visibility; right-click
## opens the menu. The same menu is shown when right-clicking the cat.

signal action(id: int)

enum { SHOW, MUTE, DND, VIBE, SETTINGS, QUIT, CHAT, QUIET, DIARY_NOW, DIARY_OPEN }

var settings: Node  # settings.gd
var icon: Texture2D
var menu: PopupMenu
var _tray: StatusIndicator
var _pet_visible := true


func _ready() -> void:
	_tray = StatusIndicator.new()
	_tray.tooltip = "Sable"
	if icon:
		_tray.icon = icon
	add_child(_tray)

	menu = PopupMenu.new()
	menu.name = "TrayMenu"
	menu.prefer_native_menu = true
	menu.add_item("Hide Sable", SHOW)
	menu.add_item("Chat with Sable...", CHAT)
	menu.add_separator()
	menu.add_check_item("Mute voice", MUTE)
	menu.add_check_item("Do not disturb", DND)
	menu.add_check_item("Quiet hours", QUIET)
	menu.add_separator()
	menu.add_item("Vibe check: Sable's take on my last Claude turns", VIBE)
	menu.add_item("Write today's diary now", DIARY_NOW)
	menu.add_item("Open diary folder", DIARY_OPEN)
	menu.add_item("Settings...", SETTINGS)
	menu.add_separator()
	menu.add_item("Quit Sable", QUIT)
	menu.id_pressed.connect(func(id: int) -> void: action.emit(id))
	_tray.add_child(menu)
	_tray.menu = _tray.get_path_to(menu)

	_tray.pressed.connect(_on_tray_pressed)
	settings.changed.connect(func(_k: String) -> void: sync())
	sync()


## Main calls this when Sable is shown or hidden so the menu label matches.
func set_pet_visible(on: bool) -> void:
	_pet_visible = on
	sync()


func _on_tray_pressed(button: int, _pos: Vector2i) -> void:
	if button == MOUSE_BUTTON_LEFT:
		action.emit(SHOW)


## Refresh check marks and labels from current state.
func sync() -> void:
	menu.set_item_checked(menu.get_item_index(MUTE), not settings.get_value("voice_enabled"))
	menu.set_item_checked(menu.get_item_index(DND), settings.get_value("dnd"))
	menu.set_item_checked(menu.get_item_index(QUIET), settings.get_value("quiet_hours"))
	menu.set_item_text(menu.get_item_index(SHOW), "Hide Sable" if _pet_visible else "Show Sable")


## Show the menu at the mouse (used for right-click on the cat).
func popup_at_mouse() -> void:
	menu.position = DisplayServer.mouse_get_position()
	menu.popup()
