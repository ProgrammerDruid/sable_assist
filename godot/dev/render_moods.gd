extends SceneTree
## Renders every mood of the code-drawn cat into one labelled sheet for the
## README. Dev only (excluded from exports). Run from the repo root:
##   & $env:GODOT --path godot --script res://dev/render_moods.gd -- docs/moods.png
## The output path is relative to the repo root (the parent of godot/).

const CatScript := preload("res://scripts/cat.gd")

## [pose, label]. "" is her neutral resting face; "sleep" uses the asleep state.
const MOODS := [
	["", "neutral"],
	["joy", "joy"],
	["trust", "content"],
	["anticipation", "curious"],
	["surprise", "surprise"],
	["fear", "spooked"],
	["sadness", "sad"],
	["disgust", "unimpressed"],
	["anger", "angry"],
	["sleep", "asleep"],
]
const COLS := 5
const CELL := Vector2(240, 280)
const CAT_SCALE := 1.2
const PAD := 24.0
const BG := Color("2b2838")
const CARD := Color("3a3650")
const LABEL := Color("e8e2f4")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out_rel := "docs/moods.png"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_rel = args[0]
	var out_path := ProjectSettings.globalize_path("res://").path_join("..").path_join(out_rel).simplify_path()

	var rows := ceili(MOODS.size() / float(COLS))
	var size := Vector2i(int(COLS * CELL.x + PAD * 2), int(rows * CELL.y + PAD * 2))

	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var bg := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.set_corner_radius_all(18)
	bg.add_theme_stylebox_override("panel", sb)
	bg.size = size
	vp.add_child(bg)

	# All cards first so no card covers a neighbouring cat's tail.
	var csb := StyleBoxFlat.new()
	csb.bg_color = CARD
	csb.set_corner_radius_all(14)
	for i in MOODS.size():
		var card := Panel.new()
		card.add_theme_stylebox_override("panel", csb)
		card.position = _origin(i) + Vector2(8, 8)
		card.size = CELL - Vector2(16, 16)
		vp.add_child(card)

	for i in MOODS.size():
		var pose: String = MOODS[i][0]
		var origin := _origin(i)
		var cat: Node2D = CatScript.new()
		# Off-centre to the left: the tail sweeps out to her right.
		cat.position = origin + Vector2(CELL.x * 0.5 - 22, CELL.y - 64)
		cat.scale = Vector2.ONE * CAT_SCALE
		vp.add_child(cat)
		if pose == "sleep":
			cat.set_sleeping(true)
		else:
			cat.set_mood(pose, 1.0)

		var label := Label.new()
		label.text = MOODS[i][1]
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", LABEL)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = origin + Vector2(0, CELL.y - 52)
		label.size = Vector2(CELL.x, 32)
		vp.add_child(label)

	# Let poses ease in (about 1.5 s) but stop before the first random blink (3 s).
	await create_timer(1.8).timeout
	await process_frame
	await process_frame

	var img := vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err := img.save_png(out_path)
	print("render_moods: ", out_path, " err=", err, " size=", img.get_size())
	quit(0 if err == OK else 1)


func _origin(i: int) -> Vector2:
	return Vector2(PAD + (i % COLS) * CELL.x, PAD + (i / COLS) * CELL.y)
