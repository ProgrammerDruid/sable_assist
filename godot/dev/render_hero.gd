extends SceneTree
## Renders the README hero image: a few moods with speech bubbles, laid out
## like the real pet window. Dev only (excluded from exports). From the repo root:
##   & $env:GODOT --path godot --script res://dev/render_hero.gd -- docs/hero.png

const CatScript := preload("res://scripts/cat.gd")
const BubbleScript := preload("res://scripts/bubble.gd")

## [pose, line]. Lines come from scripts/lines.gd so the image stays honest.
const SCENES := [
	["joy", "Fixed! I never doubted you. Much."],
	["disgust", "I've coughed up hairballs cleaner than that diff."],
	["anger", "One more failed build and something goes off your desk."],
]
## Same geometry as main.gd: window 340 wide, feet at 412, bubble bottom at 262.
const CELL_W := 340.0
const FOOT_Y := 412.0
const BUBBLE_BOTTOM := 262.0
## Crop away the empty top of the window.
const TOP := 195.0
const PAD := 20.0
const BG := Color("2b2838")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out_rel := "docs/hero.png"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_rel = args[0]
	var out_path := ProjectSettings.globalize_path("res://").path_join("..").path_join(out_rel).simplify_path()

	var size := Vector2i(int(SCENES.size() * CELL_W + PAD * 2), int(FOOT_Y + 14 - TOP + PAD * 2))
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

	for i in SCENES.size():
		# One "pet window" per scene, shifted up so its empty top is cropped.
		var win := Node2D.new()
		win.position = Vector2(PAD + i * CELL_W, PAD - TOP)
		vp.add_child(win)

		var cat: Node2D = CatScript.new()
		cat.position = Vector2(CELL_W * 0.5, FOOT_Y)
		win.add_child(cat)
		cat.set_mood(SCENES[i][0], 1.0)

		var bubble: Control = BubbleScript.new()
		bubble.center_x = CELL_W * 0.5
		bubble.anchor_bottom_y = BUBBLE_BOTTOM
		win.add_child(bubble)
		bubble.say(SCENES[i][1], 30.0)

	# Poses ease in over about 1.5 s; the first random blink is at 3 s.
	await create_timer(1.8).timeout
	await process_frame
	await process_frame

	var img := vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err := img.save_png(out_path)
	print("render_hero: ", out_path, " err=", err, " size=", img.get_size())
	quit(0 if err == OK else 1)
