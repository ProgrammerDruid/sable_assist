extends Node
## Receives JSON events over UDP on localhost from the Claude Code hook,
## sable_take.mjs and debug tools. Fire-and-forget on the sender side.
## Windows refuses a second bind on the port, which main uses as a
## single-instance check (`bound` is false in the second copy).

signal event_received(ev: Dictionary)

const PORT := 47800
const HOST := "127.0.0.1"
## Ignore oversized packets outright (real ones are well under 1 KB).
const MAX_PACKET := 8192

var bound := false
var _udp := PacketPeerUDP.new()


func _ready() -> void:
	var err := _udp.bind(PORT, HOST)
	bound = err == OK
	if not bound:
		push_warning("Sable event bus could not bind %s:%d (error %d). Is another pet running?" % [HOST, PORT, err])


func _process(_delta: float) -> void:
	if not bound:
		return
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		if pkt.size() > MAX_PACKET:
			continue
		var data = JSON.parse_string(pkt.get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY:
			event_received.emit(data)


## Send one packet to whoever owns the port (used by a second instance).
func send_local(ev: Dictionary) -> void:
	var out := PacketPeerUDP.new()
	out.set_dest_address(HOST, PORT)
	out.put_packet(JSON.stringify(ev).to_utf8_buffer())
	out.close()


func _exit_tree() -> void:
	_udp.close()
