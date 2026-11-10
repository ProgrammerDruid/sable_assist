extends Node2D
## Sable, the black cat. Drawn in code as a placeholder until real art exists.
## If <emotion>.png (or idle.png) exists in art/sable next to the app (user art,
## checked first) or in res://art/sable (bundled art), that image is shown
## instead and the code-drawn cat is hidden. Origin is at the cat's feet.

const Paths := preload("res://scripts/paths.gd")
const BUNDLED_ART_DIR := "res://art/sable"
## Seconds of full frame rate after a pose change, so the transition is smooth.
const SETTLE_SEC := 1.5
const SPRITE_HEIGHT := 150.0

const RIM := Color(0.29, 0.29, 0.36)
const FUR := Color(0.07, 0.07, 0.09)
const INNER_EAR := Color(0.36, 0.23, 0.30)
const NOSE := Color(0.79, 0.48, 0.55)

## Pose parameters per emotion.
## ear: 0 upright, + flattened back, - perked. eye: openness 0..1.
## pupil: width 0..1 (slit to round). tail: -1 tucked to 1 straight up.
## tail_speed and bob: animation speed multipliers.
var NEUTRAL := {ear = 0.1, eye = 0.7, pupil = 0.35, color = Color("d9b85c"), tail = 0.2, tail_speed = 1.0, bob = 1.0}
var MOODS := {
	"joy": {ear = 0.0, eye = 0.75, pupil = 0.45, color = Color("f2c94c"), tail = 0.7, tail_speed = 2.2, bob = 1.6, mouth = "w"},
	"trust": {ear = 0.05, eye = 0.35, pupil = 0.3, color = Color("d9b85c"), tail = 0.3, tail_speed = 0.8, bob = 0.8, mouth = "w"},
	"fear": {ear = 0.9, eye = 1.0, pupil = 0.85, color = Color("e8e2c0"), tail = -0.8, tail_speed = 3.5, bob = 2.8, mouth = "o"},
	"surprise": {ear = -0.15, eye = 1.0, pupil = 0.75, color = Color("f7e27a"), tail = 1.0, tail_speed = 1.0, bob = 1.0, mouth = "o"},
	"sadness": {ear = 0.6, eye = 0.5, pupil = 0.55, color = Color("7fa6c9"), tail = -0.5, tail_speed = 0.5, bob = 0.5, mouth = "frown"},
	"disgust": {ear = 0.35, eye = 0.4, pupil = 0.2, color = Color("a6b84a"), tail = 0.0, tail_speed = 1.2, bob = 1.0, mouth = "flat"},
	"anger": {ear = 1.0, eye = 0.45, pupil = 0.12, color = Color("e0533d"), tail = 0.1, tail_speed = 4.0, bob = 1.0, mouth = "flat"},
	"anticipation": {ear = -0.2, eye = 0.9, pupil = 0.6, color = Color("9fd36b"), tail = 0.5, tail_speed = 3.0, bob = 1.4, mouth = "none"},
	"sleep": {ear = 0.25, eye = 0.0, pupil = 0.3, color = Color("d9b85c"), tail = -0.6, tail_speed = 0.3, bob = 0.45, mouth = "none"},
}
const FLOAT_KEYS := ["ear", "eye", "pupil", "tail", "tail_speed", "bob"]

var _cur := {}
var _target := {}
var _mouth := "none"
var _t := 0.0
var _next_blink := 3.0
var _blink_until := 0.0
var _sprite: Sprite2D
var _textures := {}
var _tween: Tween
var _base_emotion := ""
var _base_intensity := 0.15
var _emote_until := 0.0
var _sleeping := false
## 0..1 how open the mouth is while speaking (set every frame by main).
var talk := 0.0
var _active_until := 0.0
var _walk_dir := 0
var _facing := 1.0  # 1 = tail on the right (default), -1 = mirrored


func _ready() -> void:
	_cur = NEUTRAL.duplicate()
	_target = NEUTRAL.duplicate()
	_sprite = Sprite2D.new()
	_sprite.visible = false
	add_child(_sprite)
	_show_pose("idle")


## Sets the resting mood (from pi-persona). intensity is 0..1; higher means a
## stronger expression. An active emote stays on top until it expires.
func set_mood(emotion: String, intensity: float) -> void:
	_base_emotion = emotion
	_base_intensity = intensity
	if _t >= _emote_until:
		_apply_resting()


## Asleep while the brain (LLM server) is offline. Emotes still wake her briefly.
func set_sleeping(on: bool) -> void:
	_sleeping = on
	if _t >= _emote_until:
		_apply_resting()


func _apply_resting() -> void:
	if _sleeping:
		_apply_pose("sleep", 1.0)
	else:
		_apply_pose(_base_emotion, _base_intensity)


## Temporary reaction that overrides the resting mood for a few seconds.
## Unknown emotion names are ignored (they come from the UDP bus too).
func emote(emotion: String, seconds: float, intensity: float = 0.8) -> void:
	if not MOODS.has(emotion):
		return
	_emote_until = _t + clampf(seconds, 0.0, 60.0)
	_apply_pose(emotion, intensity)


## True while something visibly animates beyond the slow idle loop (pose
## transitions, emotes, pokes, walking). Main uses it to raise the frame rate.
func is_active() -> bool:
	return _walk_dir != 0 or _t < _active_until or _t < _emote_until or (_tween != null and _tween.is_running())


## -1 walking left, 1 walking right, 0 standing. She keeps facing the last
## direction she walked; the tail trails behind her.
func set_walking(dir: int) -> void:
	_walk_dir = dir
	if dir != 0:
		_facing = -float(dir)
		_sprite.flip_h = _facing < 0.0


func _apply_pose(emotion: String, intensity: float) -> void:
	_active_until = _t + SETTLE_SEC
	var m: Dictionary = MOODS.get(emotion, NEUTRAL)
	var k := clampf(0.45 + 0.55 * (intensity - 0.15) / 0.85, 0.45, 1.0)
	for key in FLOAT_KEYS:
		_target[key] = lerpf(NEUTRAL[key], m[key], k)
	_target.color = (NEUTRAL.color as Color).lerp(m.color, k)
	_mouth = m.get("mouth", "none")
	_show_pose(emotion)


func poke() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2(1.15, 0.85), 0.07)
	_tween.tween_property(self, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_blink_until = _t + 0.25


func _process(delta: float) -> void:
	_t += delta
	if _emote_until > 0.0 and _t >= _emote_until:
		_emote_until = 0.0
		_apply_resting()
	var w := 1.0 - exp(-4.0 * delta)
	for key in FLOAT_KEYS:
		_cur[key] = lerpf(_cur[key], _target[key], w)
	_cur.color = (_cur.color as Color).lerp(_target.color, w)

	if _t >= _next_blink:
		_blink_until = _t + 0.13
		_next_blink = _t + randf_range(2.5, 6.0)

	if _sprite.visible:
		_sprite.position.y = sin(_t * 1.8 * _cur.bob) * 1.5 - (absf(sin(_t * 11.0)) * 2.5 if _walk_dir != 0 else 0.0)
	queue_redraw()


func _show_pose(pose: String) -> void:
	var tex := _texture_for(pose)
	if tex == null and pose != "idle":
		tex = _texture_for("idle")
	_sprite.visible = tex != null
	if tex:
		_sprite.texture = tex
		_sprite.centered = true
		_sprite.offset = Vector2(0, -tex.get_height() * 0.5)
		_sprite.scale = Vector2.ONE * (SPRITE_HEIGHT / tex.get_height())


## Loads art at runtime so new PNGs work without an editor import step.
## Only known pose names reach here (MOODS keys plus "idle").
func _texture_for(pose: String) -> Texture2D:
	if _textures.has(pose):
		return _textures[pose]
	var tex: Texture2D = null
	for dir in [Paths.file("art/sable"), BUNDLED_ART_DIR]:
		var path: String = dir.path_join(pose + ".png")
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				tex = ImageTexture.create_from_image(img)
				break
	_textures[pose] = tex
	return tex


# --- Placeholder drawing -------------------------------------------------

func _draw() -> void:
	if _sprite.visible:
		return
	var p := _cur
	var breath := sin(_t * 1.8 * p.bob)
	var head := Vector2(0, -86 + breath * 1.5)
	# Walking: face the way she's going (tail trails), little hop, paws alternate.
	var step := sin(_t * 11.0) if _walk_dir != 0 else 0.0
	draw_set_transform(Vector2(0, -absf(step) * 2.5), 0.0, Vector2(_facing, 1.0))

	var tail := _tail_points(p)
	var body := _ellipse(Vector2(0, -36), 44, 32 + breath * 0.8)
	var paw_l := _ellipse(Vector2(-20, -6 - maxf(step, 0.0) * 5.0), 13, 8)
	var paw_r := _ellipse(Vector2(16, -6 - maxf(-step, 0.0) * 5.0), 13, 8)
	var ear_l := _ear(head, -1, p.ear)
	var ear_r := _ear(head, 1, p.ear)
	var head_poly := _ellipse(head, 33, 28)

	# Outlines first, then fills, so overlapping parts read as one silhouette.
	draw_polyline(tail, RIM, 13.0, true)
	draw_circle(tail[tail.size() - 1], 6.5, RIM)
	for shape in [body, paw_l, paw_r, ear_l, ear_r, head_poly]:
		_outline(shape)

	draw_polyline(tail, FUR, 8.0, true)
	draw_circle(tail[tail.size() - 1], 4.0, FUR)
	for shape in [body, paw_l, paw_r, ear_l, ear_r]:
		draw_colored_polygon(shape, FUR)
	draw_colored_polygon(_shrink(ear_l, 0.5), INNER_EAR)
	draw_colored_polygon(_shrink(ear_r, 0.5), INNER_EAR)
	draw_colored_polygon(head_poly, FUR)

	_draw_eyes(head, p)
	_draw_face(head)
	if _sleeping and _t >= _emote_until:
		_draw_zzz(head)


func _draw_zzz(head: Vector2) -> void:
	var font := ThemeDB.fallback_font
	for i in 3:
		var phase := fmod(_t * 0.35 + i / 3.0, 1.0)
		var pos := head + Vector2(24 + phase * 18, -30 - phase * 34)
		var col := Color(0.75, 0.72, 0.95, sin(phase * PI) * 0.9)
		draw_string(font, pos, "z", HORIZONTAL_ALIGNMENT_LEFT, -1, int(11 + phase * 9), col)


func _tail_points(p: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var pos := Vector2(34, -14)
	var heading := 0.0
	var bend := lerpf(-0.15, 1.9, (p.tail + 1.0) * 0.5) / 12.0
	pts.append(pos)
	for i in 12:
		heading += bend + sin(_t * p.tail_speed * 2.0 + i * 0.4) * 0.03
		pos += Vector2(cos(heading), -sin(heading)) * 6.0
		pts.append(pos)
	return pts


func _ear(head: Vector2, side: int, tilt: float) -> PackedVector2Array:
	var base_a := head + Vector2(side * 28, -10)
	var base_b := head + Vector2(side * 6, -25)
	var tip := head + Vector2(side * 27, -50)
	var pivot := (base_a + base_b) * 0.5
	var ang := side * tilt * 0.9
	return PackedVector2Array([
		base_a, base_b, pivot + (tip - pivot).rotated(ang),
	])


func _draw_eyes(head: Vector2, p: Dictionary) -> void:
	var blink := 0.0 if _t < _blink_until else 1.0
	var open: float = p.eye * blink
	var col: Color = p.color
	for side in [-1, 1]:
		var e := head + Vector2(side * 13, -2)
		var ry := 8.5 * open
		if ry < 1.2:
			draw_line(e - Vector2(7, 0), e + Vector2(7, 0), col.darkened(0.3), 2.0, true)
			continue
		draw_colored_polygon(_ellipse(e, 8, ry, 20), col)
		draw_colored_polygon(_ellipse(e, maxf(1.2, 7.2 * p.pupil), ry * 0.92, 16), Color.BLACK)
		draw_circle(e + Vector2(2.5, -ry * 0.4), 1.4, Color(1, 1, 1, 0.8))


func _draw_face(head: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([
		head + Vector2(-3.5, 7), head + Vector2(3.5, 7), head + Vector2(0, 10.5),
	]), NOSE)
	var m := head + Vector2(0, 12)
	if talk > 0.08:
		var mouth := _ellipse(m + Vector2(0, 4), 4.0 + talk * 2.5, 1.5 + talk * 6.0, 14)
		draw_colored_polygon(mouth, Color(0.25, 0.08, 0.12))
		_outline_thin(mouth)
		_draw_whiskers(head)
		return
	match _mouth:
		"w":
			draw_polyline(PackedVector2Array([
				m + Vector2(-6, 0), m + Vector2(-3, 3), m, m + Vector2(3, 3), m + Vector2(6, 0),
			]), RIM, 1.6, true)
		"o":
			draw_arc(m + Vector2(0, 3), 3.0, 0.0, TAU, 16, RIM, 1.6, true)
		"flat":
			draw_line(m + Vector2(-5, 2), m + Vector2(5, 2), RIM, 1.6, true)
		"frown":
			draw_arc(m + Vector2(0, 6), 5.0, PI * 1.15, PI * 1.85, 10, RIM, 1.6, true)
	_draw_whiskers(head)


func _draw_whiskers(head: Vector2) -> void:
	for side in [-1, 1]:
		for k in 3:
			draw_line(head + Vector2(side * 14, 8 + k * 3), head + Vector2(side * 36, 3 + k * 6), RIM, 1.0, true)


func _outline_thin(poly: PackedVector2Array) -> void:
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_polyline(closed, RIM, 1.4, true)


func _outline(poly: PackedVector2Array) -> void:
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_polyline(closed, RIM, 6.0, true)


func _shrink(poly: PackedVector2Array, f: float) -> PackedVector2Array:
	var c := Vector2.ZERO
	for v in poly:
		c += v
	c /= poly.size()
	var out := PackedVector2Array()
	for v in poly:
		out.append(c + (v - c) * f)
	return out


static func _ellipse(c: Vector2, rx: float, ry: float, n: int = 28) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts
