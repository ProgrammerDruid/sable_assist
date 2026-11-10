extends SceneTree
## Dev check for the chat tools (no LLM involved). From the repo root:
##   & $env:GODOT --headless --path godot --script res://dev/test_tools.gd -- "search terms"

const BrainScript := preload("res://scripts/brain.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var q := args[0] if args.size() > 0 else "godot engine latest stable release"
	var brain: Node = BrainScript.new()
	root.add_child(brain)
	print("search url: ", brain._search_url, " engines: ", brain._search_engines)
	var allowed := {}
	var res: String = await brain._run_tool("web_search", {query = q}, allowed, Callable())
	print("--- web_search ---\n", res)
	print("--- allowed: ", allowed.keys())
	if not allowed.is_empty():
		var url: String = allowed.keys()[0]
		var page: String = await brain._run_tool("fetch_page", {url = url}, allowed, Callable())
		print("--- fetch_page %s ---\n%s" % [url, page.left(1200)])
	var denied: String = await brain._run_tool("fetch_page", {url = "http://192.168.1.1/admin"}, allowed, Callable())
	print("--- not allowed: ", denied)
	quit()
