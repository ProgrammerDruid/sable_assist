extends PanelContainer
## Speech bubble above the cat. Pops in, waits, fades out.
## Text that would not fit in max_text_height is split into pages that are
## shown one after another, so nothing is ever clipped.

signal layout_changed

const MAX_WIDTH := 300.0
const MIN_WIDTH := 60.0
const FONT_SIZE := 14
const PADDING := 10
const BG := Color(0.09, 0.09, 0.12, 0.94)
const BORDER := Color(0.62, 0.52, 1.0)

## Horizontal center and bottom edge, in parent coords.
var center_x := 170.0
var anchor_bottom_y := 260.0
## Tallest the text block may get before it is split into pages (~6 lines).
var max_text_height := 145.0

var _label: Label
var _timer: Timer
var _tween: Tween
var _pages: PackedStringArray = []
var _page_seconds := 0.0
## Keep the whole text up at least this long (e.g. the length of its audio).
var _min_total := 0.0
var _total_chars := 1


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.border_color = BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(PADDING)
	add_theme_stylebox_override("panel", sb)

	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", Color(0.93, 0.92, 0.96))
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	add_child(_label)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_next_page)
	add_child(_timer)

	# Autowrapped labels can settle their size a frame late; keep the bubble
	# anchored and the click region current whenever that happens.
	resized.connect(_relayout)


## Show text. seconds <= 0 picks a duration per page from its length;
## a positive value is used for every page. min_total stretches the pages so
## the whole text stays up at least that long (used to match spoken audio).
func say(text: String, seconds: float = 0.0, min_total: float = 0.0) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	_pages = _paginate(text)
	_page_seconds = seconds
	_min_total = min_total
	_total_chars = maxi(1, text.length())
	_next_page()


func has_more_pages() -> bool:
	return visible and not _pages.is_empty()


## Close right away, dropping any remaining pages (do not disturb, hiding).
func hide_now() -> void:
	_pages = []
	dismiss()


## Click on the bubble: skip to the next page, or close on the last one.
func dismiss() -> void:
	if not visible:
		return
	if not _pages.is_empty():
		_next_page()
		return
	_timer.stop()
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, 0.2)
	_tween.tween_callback(_hide_now)


func _next_page() -> void:
	if _pages.is_empty():
		_pages = []
		dismiss()
		return
	var page := _pages[0]
	_pages.remove_at(0)
	var more := not _pages.is_empty()
	_show_page(page + (" ..." if more else ""))
	var secs := _page_seconds if _page_seconds > 0.0 else clampf(2.5 + page.length() * 0.06, 3.0, 12.0)
	secs = maxf(secs, _min_total * page.length() / _total_chars + 0.8)
	_timer.start(secs)


func _show_page(text: String) -> void:
	_label.custom_minimum_size = Vector2(clampf(_text_width(text), MIN_WIDTH, MAX_WIDTH), 0)
	_label.text = text
	var was_visible := visible and modulate.a > 0.5
	visible = true
	reset_size()
	_relayout()

	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel()
	if not was_visible:
		modulate.a = 0.0
		scale = Vector2(0.7, 0.7)
		_tween.tween_property(self, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		scale = Vector2.ONE
	_tween.tween_property(self, "modulate:a", 1.0, 0.12)

	# Second pass once the wrapped label has its final height.
	await get_tree().process_frame
	reset_size()


# --- Measuring and paging ------------------------------------------------

func _font() -> Font:
	return _label.get_theme_font("font")


func _text_width(text: String) -> float:
	return _font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 4.0


## Height the Label will actually use. Font metrics alone leave out the
## Label's line_spacing, so count lines and add it back per line.
func _text_height(text: String) -> float:
	var w := clampf(_text_width(text), MIN_WIDTH, MAX_WIDTH)
	var font := _font()
	var raw := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, w, FONT_SIZE).y
	var lines := maxf(1.0, roundf(raw / font.get_height(FONT_SIZE)))
	return lines * (font.get_height(FONT_SIZE) + _label.get_theme_constant("line_spacing"))


func _fits(text: String) -> bool:
	# Leave room for the " ..." continuation marker.
	return _text_height(text + " ...") <= max_text_height


## Greedy split on sentence boundaries, falling back to words for very long
## sentences, so every page fits in max_text_height.
func _paginate(text: String) -> PackedStringArray:
	if _fits(text):
		return PackedStringArray([text])
	var pages := PackedStringArray()
	var current := ""
	for piece in _pieces(text):
		var candidate := piece if current.is_empty() else current + " " + piece
		if _fits(candidate):
			current = candidate
		else:
			if not current.is_empty():
				pages.append(current)
			current = piece
	if not current.is_empty():
		pages.append(current)
	return pages


## Sentences, with any sentence too long for one page broken into words.
func _pieces(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var re := RegEx.create_from_string("[^.!?\\n]+[.!?]*")
	for m in re.search_all(text):
		var sentence := m.get_string().strip_edges()
		if sentence.is_empty():
			continue
		if _fits(sentence):
			out.append(sentence)
		else:
			out.append_array(sentence.split(" ", false))
	return out


# --- Layout and drawing --------------------------------------------------

## Unscaled bounds. Control.get_rect() includes the pop-in scale, which would
## shrink the window's click/draw region mid-animation and clip the bubble.
func full_rect() -> Rect2:
	return Rect2(position, size)


func _hide_now() -> void:
	visible = false
	layout_changed.emit()


func _relayout() -> void:
	position = Vector2(center_x - size.x * 0.5, anchor_bottom_y - size.y)
	pivot_offset = Vector2(size.x * 0.5, size.y)
	queue_redraw()
	if visible:
		layout_changed.emit()


func _draw() -> void:
	# Little tail pointing down at the cat.
	var cx := size.x * 0.5
	var a := Vector2(cx - 8, size.y - 2)
	var b := Vector2(cx + 8, size.y - 2)
	var tip := Vector2(cx + 2, size.y + 10)
	draw_colored_polygon(PackedVector2Array([a, b, tip]), BG)
	draw_line(a, tip, BORDER, 2.0, true)
	draw_line(b, tip, BORDER, 2.0, true)
