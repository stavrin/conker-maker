# App: settings, the object catalog, and project files. An autoload, so every screen shares it.
extends Node

const SETTINGS_PATH := "user://settings.json"

# Raw-file SHA-1s of the ROMs Conker Maker accepts, in each byte order (cmtools/rom.py KNOWN_RAW).
const KNOWN_ROMS := {
	"4cbadd3c4e0729dec46af64ad018050eada4f47a": ["us", "z64", "US v1.0 (original)"],
	"27d3123dd4a3d84cb1a7ecf2ced3bc44389f4607": ["us", "v64", "US v1.0 (original)"],
	"772698b1e87cf1e1912920a4d99a6076c80d2e20": ["us", "n64", "US v1.0 (original)"],
	"4df27756ef604e82c6874aade21075b5bc8d405a": ["us-uncensored", "z64", "US Uncensored"],
	"c27c387653a780c06e8fa082f33acab52991d13e": ["us-uncensored", "v64", "US Uncensored"],
	"69faaf4e7f4167b2df45979e48e42e168f25a6f4": ["us-uncensored", "n64", "US Uncensored"],
}

var settings := {
	"rom_path": "",
	"rom_kind": "",
	"rom_description": "",
	"recomp_exe": "",
	"python": "python",
	"recent_projects": [],
}
var catalog := {}
var project_dir := ""
var game := {}          # game.json
var levels := {}        # id -> level dict


func _ready() -> void:
	load_settings()
	catalog = _read_json(catalog_path())


# --- paths -----------------------------------------------------------------------------------

# conker_maker/ (the folder holding app/, cmtools/ and catalog/). In an exported build the
# tools sit next to the executable instead.
func maker_root() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	return OS.get_executable_path().get_base_dir()


func catalog_path() -> String:
	var path := maker_root().path_join("catalog/objects.json")
	return path if FileAccess.file_exists(path) else "res://catalog/objects.json"


# --- settings --------------------------------------------------------------------------------

func load_settings() -> void:
	var loaded = _read_json(SETTINGS_PATH)
	if loaded is Dictionary:
		settings.merge(loaded, true)


func save_settings() -> void:
	_write_json(SETTINGS_PATH, settings)


func has_valid_rom() -> bool:
	return settings.rom_path != "" and FileAccess.file_exists(settings.rom_path) and settings.rom_kind != ""


# The ROM gate: hash the file and compare it with the known dumps. Returns
# {ok, kind, description, order, sha1, error}.
func check_rom(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Can't open that file."}
	if file.get_length() != 64 * 1024 * 1024:
		return {"ok": false, "error": "That file isn't 64 MB, so it isn't a Conker's Bad Fur Day ROM."}
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	while file.get_position() < file.get_length():
		ctx.update(file.get_buffer(1 << 20))
	var sha1 := ctx.finish().hex_encode()
	if KNOWN_ROMS.has(sha1):
		var info: Array = KNOWN_ROMS[sha1]
		return {"ok": true, "kind": info[0], "order": info[1], "description": info[2], "sha1": sha1}
	# Not a dump we know: cmtools can still accept a US asset hack (it checks the header).
	var result := run_cmtools(["check-rom", path])
	if result.get("ok", false):
		return {"ok": true, "kind": result.kind, "order": result.byte_order,
				"description": result.description, "sha1": result.sha1}
	return {"ok": false, "error": result.get("error", "This isn't a ROM Conker Maker can use.")}


# --- cmtools ---------------------------------------------------------------------------------

# Runs `python -m cmtools --json <args>` and returns its JSON answer.
func run_cmtools(args: Array) -> Dictionary:
	var output := []
	var exe: String = settings.python
	var full_args := ["-m", "cmtools", "--json"] + args
	var bundled := maker_root().path_join("cmtools.exe")
	if FileAccess.file_exists(bundled):   # exported builds ship cmtools as one exe
		exe = bundled
		full_args = ["--json"] + args
	else:
		OS.set_environment("PYTHONPATH", maker_root())   # so python finds the cmtools package
	var code := OS.execute(exe, full_args, output, true)
	var text := "\n".join(output).strip_edges()
	var lines := text.split("\n")
	var parsed = JSON.parse_string(lines[lines.size() - 1]) if lines.size() > 0 else null
	if parsed is Dictionary:
		return parsed
	if code != 0 and text == "":
		return {"ok": false, "error": "Couldn't run cmtools with '%s'. Is Python installed? (Settings)" % exe}
	return {"ok": false, "error": text}


# --- projects --------------------------------------------------------------------------------

func open_project(dir: String) -> String:
	var g = _read_json(dir.path_join("game.json"))
	if not g is Dictionary:
		return "That folder has no game.json."
	project_dir = dir
	game = g
	levels.clear()
	var level_dir := DirAccess.open(dir.path_join("levels"))
	if level_dir:
		for file_name in level_dir.get_files():
			if file_name.ends_with(".json"):
				var level = _read_json(dir.path_join("levels").path_join(file_name))
				if level is Dictionary:
					levels[level.get("id", file_name.get_basename())] = level
	var recent: Array = settings.recent_projects
	recent.erase(dir)
	recent.push_front(dir)
	settings.recent_projects = recent.slice(0, 8)
	save_settings()
	return ""


func new_project(dir: String, title: String) -> String:
	var existing := DirAccess.open(dir)
	if existing and (existing.get_files().size() > 0 or existing.get_directories().size() > 0):
		return "Pick an empty folder for a new game."
	var template := maker_root().path_join("templates/new_game")
	if not DirAccess.dir_exists_absolute(template):
		return "The new-game template is missing (%s)." % template
	_copy_dir(template, dir)
	var error := open_project(dir)
	if error == "":
		game.title = title
		save_project()
	return error


func _copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	var dir := DirAccess.open(from)
	for file_name in dir.get_files():
		DirAccess.copy_absolute(from.path_join(file_name), to.path_join(file_name))
	for sub in dir.get_directories():
		_copy_dir(from.path_join(sub), to.path_join(sub))


func save_project() -> void:
	_write_json(project_dir.path_join("game.json"), game)
	DirAccess.make_dir_recursive_absolute(project_dir.path_join("levels"))
	for id in levels:
		_write_json(project_dir.path_join("levels").path_join(id + ".json"), levels[id])


func new_level(id: String, title: String) -> Dictionary:
	var level := {
		"format": "conker-maker-level-v1", "id": id, "title": title,
		"base": {"kind": "blank", "ground": {"size": [60, 60], "color": "#5f8a3a"}},
		"music": {"rom_track": 0},
		"objects": [{"uid": "start", "type": "player_start", "position": [0, 0, 0],
				"rotation_y": 0, "scale": 1.0, "props": {}}],
		"events": [],
	}
	levels[id] = level
	return level


func delete_level(id: String) -> void:
	levels.erase(id)
	DirAccess.remove_absolute(project_dir.path_join("levels").path_join(id + ".json"))
	for chapter in game.get("chapters", []):
		chapter.levels.erase(id)


func level_ids() -> Array:
	# In chapter order first, then any level not in a chapter.
	var ids := []
	for chapter in game.get("chapters", []):
		for id in chapter.get("levels", []):
			if levels.has(id) and not ids.has(id):
				ids.append(id)
	for id in levels:
		if not ids.has(id):
			ids.append(id)
	return ids


func object_types() -> Dictionary:
	return catalog.get("objects", {})


func default_props(type: String) -> Dictionary:
	var props := {}
	var spec: Dictionary = object_types().get(type, {}).get("props", {})
	for key in spec:
		var value = spec[key].get("default")
		props[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	return props


# --- json helpers ----------------------------------------------------------------------------

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _write_json(path: String, data) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "  ") + "\n")
