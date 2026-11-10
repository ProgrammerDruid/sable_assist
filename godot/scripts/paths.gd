extends RefCounted
## Where Sable's support files live (brain/, claude-hooks/, tts/, tools/, art/).
## Dev: the repo root (one level above the Godot project).
## Packaged: the folder containing Sable.exe (same layout as the repo).
## Override with the SABLE_HOME environment variable.


static func home() -> String:
	var env := OS.get_environment("SABLE_HOME")
	if not env.is_empty():
		return env
	if OS.has_feature("template"):  # running from an exported build
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


static func file(relative: String) -> String:
	return home().path_join(relative)
