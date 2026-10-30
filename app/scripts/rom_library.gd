# Rom: the asset library imported from the player's own ROM (models, textures, level scenes).
# An autoload. cmtools builds the library (`import-assets`); this loads its catalog and turns
# its glTF files into nodes, cached so each model is only parsed once.
extends Node

signal library_changed

var catalog := {}
var dir := ""
var models := {}            # id -> catalog entry
var scenes := {}            # id -> catalog entry
var world_scale := 0.01
var importing := false
var import_result := {}
var _packed := {}           # path -> PackedScene
var _donor_libraries := {}  # model id -> AnimationLibrary borrowed by look-alike characters
var _roles := {}            # model id -> {idle, walk, run, attack, hurt, die}
var _thread: Thread

const AnimRoles := preload("res://scripts/anim_roles.gd")
const CATALOG_REVISION := 2   # matches cmtools; older catalogs are rebuilt on load


func _ready() -> void:
	reload()


func reload() -> void:
	catalog = {}
	models.clear()
	scenes.clear()
	_packed.clear()
	_donor_libraries.clear()
	_roles.clear()
	dir = App.settings.get("library_dir", "")
	var path := dir.path_join("catalog.json")
	if dir != "" and FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and int(data.get("catalog_revision", 1)) < CATALOG_REVISION \
				and App.settings.get("rom_path", "") != "":
			# A library from an older Conker Maker: rebuild its catalog (a few seconds, no re-import).
			App.run_cmtools(["refresh-catalog", "--rom", App.settings.rom_path, "--library", dir])
			data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and data.get("rom_sha1", "") != "":
			catalog = data
			world_scale = float(data.get("world_scale", 0.01))
			for m in data.get("models", []):
				models[m.id] = m
			for s in data.get("scenes", []):
				scenes[s.id] = s
	library_changed.emit()


func is_ready() -> bool:
	return not models.is_empty()


func model_name(id) -> String:
	if id is Dictionary:
		id = id.get("id", "")
	return models.get(id, {}).get("name", str(id))


# A model reference as stored in a level: enough for the runtime to find it in the ROM.
func model_ref(id: String) -> Dictionary:
	var m: Dictionary = models.get(id, {})
	return {"id": id, "bank": int(m.get("bank", 0)), "entry": int(m.get("entry", 0)), "segment": int(m.get("segment", 0))}


func categories() -> Dictionary:
	return catalog.get("categories", {})


# --- music -------------------------------------------------------------------------------------

func music_list() -> Array:
	return catalog.get("audio", {}).get("music", [])


# A dropdown of the ROM's music by name (or a number box before the assets are imported).
func music_picker(current: int, on_pick: Callable) -> Control:
	var tracks := music_list()
	if tracks.is_empty():
		var spin := SpinBox.new()
		spin.max_value = 148
		spin.value = current
		spin.prefix = "track"
		spin.value_changed.connect(func(v): on_pick.call(int(v)))
		return spin
	var option := OptionButton.new()
	option.fit_to_longest_item = false
	option.clip_text = true
	option.add_item("(no music)")
	option.set_item_metadata(0, 0)
	for t in tracks:
		if int(t.index) == 0:
			continue
		option.add_item("%s — %s" % [t.name, t.category])
		option.set_item_metadata(option.item_count - 1, int(t.index))
		if int(t.index) == current:
			option.select(option.item_count - 1)
	option.item_selected.connect(func(i): on_pick.call(option.get_item_metadata(i)))
	return option


# The rendered WAV of a music track, or null (needs Godot 4.4+ to load WAVs at runtime).
func music_stream(index: int) -> AudioStream:
	for t in music_list():
		if int(t.index) == index and t.get("wav"):
			var path := dir.path_join(t.wav)
			if FileAccess.file_exists(path) and ClassDB.class_has_method("AudioStreamWAV", "load_from_file"):
				var stream: AudioStreamWAV = AudioStreamWAV.load_from_file(path)
				if stream:
					stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
					stream.loop_end = int(stream.get_length() * stream.mix_rate) if stream.loop_end == 0 else stream.loop_end
				return stream
	return null


# --- loading -----------------------------------------------------------------------------------

func instance_model(id: String) -> Node3D:
	if not models.has(id):
		return null
	var node := _instance(dir.path_join(models[id].path), true)
	if node == null:
		return null
	node.set_meta("rom_id", id)
	node.set_meta("anim_source", id)
	var donor: String = models[id].get("anim_from", "")
	if donor != "" and models.has(donor) and animation_player(node) == null:
		var library := _donor_library(donor)
		if library:
			var player := AnimationPlayer.new()
			player.name = "AnimationPlayer"
			player.add_animation_library("", library)
			node.add_child(player)
			player.root_node = NodePath("..")
			node.set_meta("anim_source", donor)
	return node


# Some characters are stored without animations (the Tedi soldiers, the Tedi General...) but
# share their skeleton with one that has them: cmtools records that donor as `anim_from`.
# Only the root joint keeps its movement; the others just rotate, so the borrowed clips fit
# a body with different proportions.
func _donor_library(donor: String) -> AnimationLibrary:
	if _donor_libraries.has(donor):
		return _donor_libraries[donor]
	var source := _instance(dir.path_join(models[donor].path), true)
	var library: AnimationLibrary = null
	var player := animation_player(source) if source else null
	if player:
		library = AnimationLibrary.new()
		var skeletons := source.find_children("*", "Skeleton3D", true, false)
		var root_bone: String = (skeletons[0] as Skeleton3D).get_bone_name(0) if not skeletons.is_empty() else ""
		for name in player.get_animation_list():
			var anim: Animation = player.get_animation(name).duplicate(true)
			for t in range(anim.get_track_count() - 1, -1, -1):
				if anim.track_get_type(t) == Animation.TYPE_POSITION_3D \
						and String(anim.track_get_path(t).get_concatenated_subnames()) != root_bone:
					anim.remove_track(t)
			library.add_animation(name, anim)
	if source:
		source.free()
	_donor_libraries[donor] = library
	return library


# Which animation plays for idle, walk, run, attack, hurt and die on this model (names in
# its AnimationPlayer, "" if it has none). Checked-by-eye names in catalog/objects.json win;
# the rest are worked out from the poses (anim_roles.gd).
func roles(model: Node) -> Dictionary:
	var player := animation_player(model)
	if player == null:
		return {}
	var source: String = model.get_meta("anim_source", "")
	if source != "" and _roles.has(source):
		return _roles[source]
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	var found := {"idle": find_animation(player)}
	if player.get_animation_list().size() <= 150:   # Conker's 764 are named in the catalog instead
		found = AnimRoles.classify(player, skeletons[0] if not skeletons.is_empty() else null)
	var reviewed: Dictionary = App.catalog.get("character_animations", {}).get(source, {})
	if source == "b01-0000-00":   # Conker: the player section names his
		reviewed = App.catalog.get("player", {}).get("animations", {}).duplicate()
		reviewed.attack = App.catalog.get("player", {}).get("animations", {}).get("attack", "")
	for role in reviewed:
		var name := find_animation(player, str(reviewed[role]))
		if name != "" and str(reviewed[role]) != "":
			found[role] = name
	if source != "":
		_roles[source] = found
	return found


func instance_scene(id: String) -> Node3D:
	if not scenes.has(id):
		return null
	return _instance(dir.path_join(scenes[id].path))


func _instance(path: String, double_sided := false) -> Node3D:
	if not _packed.has(path):
		if not FileAccess.file_exists(path):
			return null
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) != OK:
			return null
		var root := doc.generate_scene(state)
		if root == null:
			return null
		_own(root, root)
		if double_sided:
			_double_sided(root)
		var packed := PackedScene.new()
		packed.pack(root)
		root.free()
		_packed[path] = packed
	return _packed[path].instantiate()


# The N64 often draws both sides of a surface; glTF materials default to one side, which
# leaves holes in thin models like the cash bundle. Models (not level scenes) show both.
func _double_sided(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as BaseMaterial3D
			if m:
				m.cull_mode = BaseMaterial3D.CULL_DISABLED


func _own(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own(child, owner_node)


# The bounding box of a node tree, in the node's own space (works before it's in the tree).
static func aabb_of(root: Node) -> AABB:
	var box := AABB()
	var first := true
	var stack := [[root, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xf: Transform3D = item[1]
		if node is Node3D and node != root:
			xf = xf * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh:
			var b: AABB = xf * (node as MeshInstance3D).mesh.get_aabb()
			box = b if first else box.merge(b)
			first = false
		for child in node.get_children():
			stack.append([child, xf])
	return box


static func is_skinned(root: Node) -> bool:
	return not root.find_children("*", "Skeleton3D", true, false).is_empty()


static func animation_player(root: Node) -> AnimationPlayer:
	var found := root.find_children("*", "AnimationPlayer", true, false)
	return found[0] if not found.is_empty() else null


# The animation whose name contains `key` (e.g. "pair_0001_"), or the first one.
static func find_animation(player: AnimationPlayer, key := "") -> String:
	var names := Array(player.get_animation_list())
	names.sort()
	for n in names:
		if key != "" and key in n:
			return n
	return names[0] if not names.is_empty() and key == "" else ""


# --- importing -----------------------------------------------------------------------------------

# Where the library for this ROM goes (asks cmtools, which owns the rule).
func library_for_rom() -> Dictionary:
	return App.run_cmtools(["library", "--rom", App.settings.rom_path])


func start_import() -> String:
	if importing:
		return ""
	var info := library_for_rom()
	if not info.get("ok", false):
		return info.get("error", "Couldn't find where to put the library.")
	App.settings.library_dir = info.library
	App.save_settings()
	dir = info.library
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("status.json"))
	importing = true
	import_result = {}
	_thread = Thread.new()
	_thread.start(_import_worker.bind(App.settings.rom_path, dir))
	return ""


func _import_worker(rom_path: String, library: String) -> void:
	var result := App.run_cmtools(["import-assets", "--rom", rom_path, "--library", library])
	call_deferred("_import_finished", result)


func _import_finished(result: Dictionary) -> void:
	_thread.wait_to_finish()
	importing = false
	import_result = result
	reload()


# Progress while importing: {state, step, steps, message} from cmtools' status.json.
func import_status() -> Dictionary:
	var path := dir.path_join("status.json")
	if dir == "" or not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}
