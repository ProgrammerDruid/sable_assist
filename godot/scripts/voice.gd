extends Node
## Sable's voice: text -> Pocket TTS server (tts/serve.ps1, CPU) -> audio.
##
## The TTS server owns which voice is used (azelma preset, or the custom
## voices/sable.safetensors); this only sends text. Failures are silent: if the
## server is down or slow, Sable just doesn't speak and the bubble still shows.

const DEFAULT_URL := "http://127.0.0.1:8890"
const CACHE_MAX := 40
## Amplitude envelope resolution for mouth movement.
const ENV_STEP := 0.04

var base_url := DEFAULT_URL
var enabled := true
var volume := 0.8:
	set(v):
		volume = clampf(v, 0.0, 1.0)
		if _player:
			_player.volume_db = linear_to_db(maxf(volume, 0.001))

var _player: AudioStreamPlayer
var _cache := {}          # text -> {stream, env}
var _cache_order: Array[String] = []
var _env := PackedFloat32Array()


func _ready() -> void:
	base_url = base_url.trim_suffix("/")  # main sets it from settings (.env default)
	if OS.get_environment("SABLE_VOICE").to_lower() == "off":
		enabled = false
	_player = AudioStreamPlayer.new()
	add_child(_player)
	volume = volume


## Render `text`. Returns {stream, env} or {} on failure/timeout. Cached.
## timeout <= 0 scales with length: Pocket TTS runs ~3x real time on CPU, so a
## 60-word vibe check needs ~8 s, more while the CPU is busy.
func synthesize(text: String, timeout: float = 0.0) -> Dictionary:
	if not enabled or text.strip_edges().is_empty():
		return {}
	if _cache.has(text):
		return _cache[text]
	if timeout <= 0.0:
		timeout = clampf(3.0 + text.length() * 0.06, 6.0, 25.0)
	var t0 := Time.get_ticks_msec()
	var wav := await _post_tts(text, timeout)
	if wav.is_empty():
		return {}
	var clip := _parse_wav(wav)
	if clip.is_empty():
		print("[voice] could not parse %d bytes of audio" % wav.size())
		return {}
	print("[voice] %d chars -> %.1f s audio in %d ms" % [text.length(), (clip.stream as AudioStreamWAV).get_length(), Time.get_ticks_msec() - t0])
	_cache[text] = clip
	_cache_order.append(text)
	while _cache_order.size() > CACHE_MAX:
		_cache.erase(_cache_order.pop_front())
	return clip


func play(clip: Dictionary) -> void:
	if clip.is_empty():
		return
	_env = clip.env
	_player.stream = clip.stream
	_player.play()


func stop() -> void:
	_player.stop()


func is_speaking() -> bool:
	return _player.playing


## 0..1 loudness right now, for the mouth.
func level() -> float:
	if not _player.playing or _env.is_empty():
		return 0.0
	var i := int(_player.get_playback_position() / ENV_STEP)
	return _env[clampi(i, 0, _env.size() - 1)]


func _post_tts(text: String, timeout: float) -> PackedByteArray:
	var boundary := "----sable%d" % randi()
	var body := PackedByteArray()
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\n" % boundary).to_utf8_buffer())
	body.append_array(text.to_utf8_buffer())
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())

	var http := HTTPRequest.new()
	http.timeout = timeout
	# Threaded with big chunks: the WAV is a few hundred KB, and the default
	# 64 KB-per-frame read crawls at the 10 fps idle frame rate.
	http.use_threads = true
	http.download_chunk_size = 1 << 20
	add_child(http)
	var err := http.request_raw(base_url + "/tts",
		["Content-Type: multipart/form-data; boundary=" + boundary], HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		print("[voice] TTS request could not start (error %d)" % err)
		return PackedByteArray()
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		print("[voice] TTS failed: result %d, HTTP %d, %d bytes (timeout %.1f s)" % [res[0], res[1], (res[3] as PackedByteArray).size(), timeout])
		return PackedByteArray()
	return res[3]


## Minimal RIFF/WAV reader for 16-bit PCM. Also builds a loudness envelope.
func _parse_wav(b: PackedByteArray) -> Dictionary:
	if b.size() < 44 or b.slice(0, 4).get_string_from_ascii() != "RIFF":
		return {}
	var channels := 1
	var rate := 24000
	var bits := 16
	var data := PackedByteArray()
	var pos := 12
	while pos + 8 <= b.size():
		var id := b.slice(pos, pos + 4).get_string_from_ascii()
		var size := b.decode_u32(pos + 4)
		var start := pos + 8
		if id == "fmt ":
			channels = b.decode_u16(start + 2)
			rate = b.decode_u32(start + 4)
			bits = b.decode_u16(start + 14)
		elif id == "data":
			data = b.slice(start, mini(start + size, b.size()))
			break
		pos = start + size + (size & 1)
	if data.is_empty() or bits != 16:
		return {}

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = channels == 2
	stream.data = data

	# Peak per ENV_STEP window, normalized, for mouth flaps.
	var frame_bytes := 2 * channels
	var win := maxi(1, int(rate * ENV_STEP))
	var frames := data.size() / frame_bytes
	var env := PackedFloat32Array()
	var peak_all := 1.0
	var i := 0
	while i < frames:
		var peak := 0
		var j := i
		while j < mini(i + win, frames):
			peak = maxi(peak, absi(data.decode_s16(j * frame_bytes)))
			j += 4  # sampling every 4th frame is plenty for a mouth
		env.append(float(peak))
		peak_all = maxf(peak_all, float(peak))
		i += win
	for k in env.size():
		env[k] = clampf(env[k] / peak_all * 1.3, 0.0, 1.0)
	return {stream = stream, env = env}
