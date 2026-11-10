extends Node
## Sable's voice: asks the local llama.cpp server for one short line.
##
## Server state is three-way:
##  - offline: connection refused or /health failing. She sleeps; health checks
##    back off 5 s -> 5 min until it answers again.
##  - busy: another request is running (or /slots timed out because the server
##    is swamped). She waits, polling, until the thought's TTL expires, then
##    uses the canned line. Busy never puts her to sleep.
##  - free: she asks for her line on her own slot.
## One request at a time; a new thought while one is in flight gets its canned
## line right away.
## The system prompt is SOUL.md + USER.md from the persona dir plus
## brain/pet_rules.md, reloaded whenever any of them change. Every message
## gets its {user} / {brain} placeholders filled in (env.gd) on the way out.

signal sleep_changed(asleep: bool, offline_secs: float)

const DEFAULT_URL := "http://127.0.0.1:8080"
const HEALTH_EVERY := 30.0
const RETRY_MIN := 5.0
const RETRY_MAX := 300.0
const BUSY_POLL := 3.0
const MAX_TOKENS := 80
const CHAT_MAX_TOKENS := 220
## llama-server runs with -np 2: slot 0 for coding, slot 1 for Sable
## (SABLE_LLM_SLOT). With a single-slot server she uses any slot (-1) instead
## of waiting forever.
const DEFAULT_PET_SLOT := 1
const Paths := preload("res://scripts/paths.gd")
const Env := preload("res://scripts/env.gd")
const RECENT_KEEP := 6
const WEEKDAYS := ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

var base_url := DEFAULT_URL
var asleep := false
## Set by main from the mood watcher, e.g. "joy (level 1 of 3)".
var mood_text := "neutral"

## memory.gd node (set by main); its facts end every system prompt.
var memory: Node

var _busy := false
## Set by chat()/write() while waiting, so a pet line stuck polling a busy
## server gives up (and uses its canned line) instead of holding the brain.
var _preempt := false
var _recent: Array[String] = []
var _file_cache := {}  # path -> {mtime, text}
var _down_since := 0.0
var _retry := RETRY_MIN
var _health_timer: Timer
var _agent_dir := ""
var _pet_slot := DEFAULT_PET_SLOT
var _slot := -1  # becomes _pet_slot once /slots shows the server has it
var _health_checking := false
var _frontmatter := RegEx.create_from_string("(?s)^---.*?---\\s*")
var _think := RegEx.create_from_string("(?s)<think>.*?</think>")
var _action := RegEx.create_from_string("\\*[^*]+\\*")


func _ready() -> void:
	base_url = base_url.trim_suffix("/")  # main sets it from settings (.env default)
	_pet_slot = Env.value("SABLE_LLM_SLOT", str(DEFAULT_PET_SLOT)).to_int()
	_agent_dir = Env.persona_dir()

	_health_timer = Timer.new()
	_health_timer.one_shot = true
	_health_timer.timeout.connect(_check_health)
	add_child(_health_timer)
	_check_health.call_deferred()


## Ask for a line about `situation`. `done` is called at most once, with the
## LLM's line or else `fallback`. It is NOT called if the server went offline
## during this request (the sleep announcement covers that moment) or if both
## lines are empty. Callers that care about staleness check it in `done`.
func ask(situation: String, fallback: String, done: Callable, ttl: float = 15.0) -> void:
	if asleep or _busy:
		_finish(done, fallback)
		return
	_busy = true
	var deadline := _now() + ttl
	var line := ""
	var went_offline := false
	while _now() < deadline and not _preempt:
		var state := await _slot_state()
		if state < 0:
			went_offline = true
			break
		if state == 0:
			line = await _complete(situation, maxf(3.0, deadline - _now()))
			break
		await get_tree().create_timer(BUSY_POLL).timeout
	var bumped := _preempt and line.is_empty()
	_busy = false
	if went_offline or bumped:
		return  # offline: the sleep line covers it; bumped: the user is chatting
	_finish(done, line if not line.is_empty() else fallback)


## Lines said through other paths (canned pokes etc.) so the LLM avoids repeats.
func remember(line: String) -> void:
	if line.is_empty():
		return
	_recent.append(line)
	while _recent.size() > RECENT_KEEP:
		_recent.pop_front()


func _finish(done: Callable, line: String) -> void:
	if line.is_empty():
		return
	remember(line)
	done.call(line)


# --- llama.cpp calls -----------------------------------------------------

## 0 = free, 1 = busy (someone else's request, or too swamped to answer),
## -1 = offline (connection failed; also kicks off a health check).
func _slot_state() -> int:
	var r := await _http("/slots", null, 4.0)
	if r.result == HTTPRequest.RESULT_TIMEOUT:
		return 1
	if r.result != HTTPRequest.RESULT_SUCCESS:
		await _check_health()  # a one-off hiccup counts as busy, not offline
		return -1 if asleep else 1
	if r.code != 200 or typeof(r.data) != TYPE_ARRAY:
		return 0  # /slots disabled: assume free
	_slot = _pet_slot if _pet_slot >= 0 and r.data.size() > _pet_slot else -1
	for slot in r.data:
		if typeof(slot) == TYPE_DICTIONARY and slot.get("is_processing", false):
			return 1
	return 0


func _complete(situation: String, timeout: float) -> String:
	var recent := "(none)" if _recent.is_empty() else "- " + "\n- ".join(_recent)
	var user := "Local time: %s\nYour current mood: %s\n\nSituation: %s\n\nRecent things you said:\n%s\n\nSay your line." % [
		clock(), mood_text, situation, recent]
	var raw := await _post([{role = "system", content = _system_for("pet_rules.md")},
		{role = "user", content = user}], MAX_TOKENS, 0.9, timeout)
	return _clean(raw)


# --- Chat and long-form writing --------------------------------------------

## One chat turn. `history` is [{role, content}, ...] ending with the user's
## message; `context` (time, mood, recent events) goes at the end of the system
## prompt. The user is actively waiting, so this doesn't defer to a busy coding
## slot; it only waits for Sable's own in-flight line. `done` gets the raw
## reply (may contain REMEMBER: lines), or "" if offline or failed.
func chat(history: Array, context: String, done: Callable) -> void:
	var ok: bool = await _acquire(30.0)
	if not ok:
		done.call("")
		return
	var msgs: Array = [{role = "system", content = _system_for("chat_rules.md") + "\n\n" + context}]
	msgs.append_array(history)
	var raw := await _post(msgs, CHAT_MAX_TOKENS, 0.85, 60.0)
	_release()
	done.call(raw)


## Long-form writing (the diary). Not urgent: waits politely for a free server
## for up to 10 minutes. `done` gets the cleaned text or "".
func write(rules_file: String, prompt: String, max_tokens: int, done: Callable) -> void:
	var ok: bool = await _acquire(120.0)
	if not ok:
		done.call("")
		return
	var deadline := _now() + 600.0
	while _now() < deadline:
		var state: int = await _slot_state()
		if state != 1:
			break
		await get_tree().create_timer(10.0).timeout
	var raw := ""
	if not asleep:
		raw = await _post([{role = "system", content = _system_for(rules_file)}, {role = "user", content = prompt}],
			max_tokens, 0.85, 120.0)
	_release()
	done.call(clean_block(raw))


## Memory extraction, run after every chat message (the approach mem0 and
## similar systems use: the LLM is the classifier and says NONE when nothing is
## worth keeping). No persona, low temperature. It sees Sable's previous line
## for context and the facts already stored, so it doesn't repeat them.
## `done` gets up to two new facts, one per line, or "".
func extract_fact(message: String, previous_reply: String, known: PackedStringArray, done: Callable) -> void:
	var ok: bool = await _acquire(30.0)
	if not ok:
		done.call("")
		return
	var sys := "You keep a short list of long-term facts about {user}, the user. Read their latest chat message " + \
		"(and what was said just before it, for context). Reply with up to two NEW short facts worth remembering " + \
		"for weeks or months: lasting preferences, people in their life, ongoing projects or plans, running jokes. " + \
		"Not moods, not one-off tasks, not things only true today. One per line, third person, for example: " + \
		"{user}'s favorite coding drink is cold brew with oat milk. No numbering or bullets. Never repeat or rephrase " + \
		"a fact that is already known. If nothing new is worth remembering, reply exactly: NONE"
	var known_text := "(none yet)" if known.is_empty() else "- " + "\n- ".join(known)
	var user := "Already known:\n%s\n\nSable said just before: %s\n\n{user}'s message: %s" % [
		known_text, previous_reply.left(400) if not previous_reply.is_empty() else "(nothing)", message]
	var raw := await _post([{role = "system", content = sys}, {role = "user", content = user}], 90, 0.2, 30.0)
	_release()
	var facts := PackedStringArray()
	for line in clean_block(raw).split("\n", false):
		var f := line.strip_edges().trim_prefix("-").strip_edges()
		if not f.is_empty() and not f.to_upper().begins_with("NONE") and facts.size() < 2:
			facts.append(f)
	done.call("\n".join(facts))


func _acquire(wait: float) -> bool:
	if asleep:
		return false
	_preempt = true
	var deadline := _now() + wait
	while _busy and _now() < deadline:
		await get_tree().create_timer(0.25).timeout
	_preempt = false
	if _busy or asleep:
		return false
	_busy = true
	return true


func _release() -> void:
	_busy = false


func _post(messages: Array, max_tokens: int, temperature: float, timeout: float) -> String:
	var filled: Array = []
	for m in messages:
		filled.append({role = m.role, content = Env.sub(str(m.content))})
	var body := {
		messages = filled,
		max_tokens = max_tokens,
		temperature = temperature,
		# Sable's own slot, so her prompt never evicts a coding session's KV cache.
		id_slot = _slot,
		chat_template_kwargs = {enable_thinking = false},
	}
	var r := await _http("/v1/chat/completions", body, timeout)
	if r.code != 200 or typeof(r.data) != TYPE_DICTIONARY:
		return ""
	var choices: Array = r.data.get("choices", [])
	if choices.is_empty():
		return ""
	return str(choices[0].get("message", {}).get("content", ""))


func _http(path: String, body: Variant, timeout: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	# Threaded, so requests don't crawl at the 10 fps idle frame rate.
	http.use_threads = true
	add_child(http)
	var err: int
	if body == null:
		err = http.request(base_url + path)
	else:
		err = http.request(base_url + path, ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {result = HTTPRequest.RESULT_CANT_CONNECT, code = 0, data = null}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return {result = res[0], code = 0, data = null}
	return {result = res[0], code = res[1],
		data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())}


# --- Health and sleep ----------------------------------------------------

## The only place that decides offline vs online. A /health timeout while she
## is awake means the server is swamped, which counts as busy, not offline.
func _check_health() -> void:
	if _health_checking:
		return
	_health_checking = true
	var r := await _http("/health", null, 4.0)
	_health_checking = false
	if r.code == 200 or (r.result == HTTPRequest.RESULT_TIMEOUT and not asleep):
		_retry = RETRY_MIN
		if asleep:
			asleep = false
			sleep_changed.emit(false, _now() - _down_since)
		_health_timer.start(HEALTH_EVERY)
		return
	if not asleep:
		asleep = true
		_down_since = _now()
		sleep_changed.emit(true, 0.0)
	_health_timer.start(_retry)
	_retry = minf(_retry * 2.0, RETRY_MAX)


# --- Prompt helpers ------------------------------------------------------

## SOUL.md + USER.md (persona dir) + brain/<rules_file> + remembered facts.
## Files are re-read only when they change; memory goes last so the cached
## prompt prefix on the server stays the same between calls.
func _system_for(rules_file: String) -> String:
	var parts: PackedStringArray = []
	for p in [_agent_dir.path_join("SOUL.md"), _agent_dir.path_join("USER.md"), Paths.file("brain/" + rules_file)]:
		var text := _read_cached(p)
		if not text.is_empty():
			parts.append(text)
	if memory:
		var m: String = memory.prompt_block()
		if not m.is_empty():
			parts.append(m)
	return "\n\n".join(parts)


func _read_cached(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var mtime := FileAccess.get_modified_time(path)
	var hit: Dictionary = _file_cache.get(path, {})
	if hit.get("mtime", -1) != mtime:
		hit = {mtime = mtime, text = _frontmatter.sub(FileAccess.get_file_as_string(path), "").strip_edges()}
		_file_cache[path] = hit
	return hit.text


## Multi-sentence cleanup (chat, diary): drop think blocks and *actions*,
## plain hyphens, collapse blank lines, strip wrapping quotes.
func clean_block(s: String) -> String:
	s = _think.sub(s, "", true)
	s = _action.sub(s, "", true)
	s = s.replace(char(0x2014), "-").replace(char(0x2013), "-")
	var lines := PackedStringArray()
	for line in s.split("\n", false):
		if not line.strip_edges().is_empty():
			lines.append(line.strip_edges())
	s = "\n".join(lines).strip_edges()
	return s.trim_prefix("\"").trim_suffix("\"").strip_edges()


func _clean(s: String) -> String:
	s = _think.sub(s, "", true)
	s = _action.sub(s, "", true)
	# Em and en dashes (U+2014, U+2013) become plain hyphens.
	s = s.replace(char(0x2014), "-").replace(char(0x2013), "-")
	for line in s.split("\n", false):
		var t := line.strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges()
		t = t.trim_prefix("“").trim_suffix("”").strip_edges()
		if not t.is_empty():
			return t.left(300)
	return ""


func clock() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%s %02d:%02d" % [WEEKDAYS[d.weekday], d.hour, d.minute]


func _now() -> float:
	return Time.get_unix_time_from_system()
