extends RefCounted
## Little retro chat sounds, synthesized at runtime (original, no sampled audio):
## a rising "door open" arpeggio, a falling "door close", a two-tone "message
## received" chime and a short "sent" blip.

const RATE := 22050


static func door_open() -> AudioStreamWAV:
	return _notes([[523.25, 0.06], [659.25, 0.06], [783.99, 0.06], [1046.5, 0.28]])


static func door_close() -> AudioStreamWAV:
	return _notes([[1046.5, 0.06], [783.99, 0.06], [659.25, 0.06], [523.25, 0.28]])


static func receive() -> AudioStreamWAV:
	return _notes([[987.77, 0.09], [739.99, 0.3]])


static func send() -> AudioStreamWAV:
	var n := int(RATE * 0.09)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := lerpf(480.0, 960.0, t / 0.09)
		phase += TAU * f / RATE
		var env := minf(1.0, t / 0.004) * exp(-t / 0.05)
		data.encode_s16(i * 2, int(sin(phase) * env * 0.35 * 32767.0))
	return _stream(data)


## Sequential bell-ish notes: [[freq, seconds], ...]
static func _notes(notes: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	for note in notes:
		var f: float = note[0]
		var dur: float = note[1]
		var n := int(RATE * dur)
		var start := data.size()
		data.resize(start + n * 2)
		for i in n:
			var t := float(i) / RATE
			var env := minf(1.0, t / 0.005) * exp(-t / (dur * 0.45))
			var s := sin(TAU * f * t) + 0.35 * sin(TAU * f * 2.0 * t) + 0.12 * sin(TAU * f * 3.0 * t)
			data.encode_s16(start + i * 2, int(clampf(s * env * 0.22, -1.0, 1.0) * 32767.0))
	return _stream(data)


static func _stream(data: PackedByteArray) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s
