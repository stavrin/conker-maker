# The right-hand panel: settings for the selected object, or for the level and game when
# nothing is selected. Built from the catalog, so new object types need no new UI code.
extends VBoxContainer

signal before_change
signal object_changed(uid)        # redraw this object
signal object_renamed(old_uid, new_uid)
signal level_changed              # redraw the whole level (ground etc.)
signal game_changed               # titles, chapters

const Main := preload("res://scripts/main.gd")

var level := {}
var obj := {}
var browser   # the editor's ModelBrowser

# Which part of the ROM's model list to open on, by object type.
const BROWSE_CATEGORY := {"npc": "characters", "enemy": "characters", "cash": "collectables",
		"chocolate": "collectables", "squirrel_tail": "collectables", "prop": "scene-items", "platform": "scene-items"}


func show_object(new_level: Dictionary, uid: String) -> void:
	level = new_level
	obj = {}
	for o in level.get("objects", []):
		if o.uid == uid:
			obj = o
	_rebuild()


func _rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	if obj.is_empty():
		_build_level_settings()
	else:
		_build_object()


# --- object ---------------------------------------------------------------------------------

func _build_object() -> void:
	var spec: Dictionary = App.object_types().get(obj.type, {})
	add_child(Main.title_label(spec.get("label", obj.type), 22))
	add_child(Main.note_label(spec.get("help", "")))
	var uid_edit := LineEdit.new()
	uid_edit.text = obj.uid
	uid_edit.text_submitted.connect(_rename)
	uid_edit.focus_exited.connect(func(): _rename(uid_edit.text))
	_row("Name (id)", uid_edit)
	var p: Array = obj.position
	_row("Position", _vec3_editor(p, func(v): obj.position = v; object_changed.emit(obj.uid)))
	_row("Turn (°)", _number(float(obj.get("rotation_y", 0)), -360, 360, 15, func(v): obj.rotation_y = v; object_changed.emit(obj.uid)))
	_row("Scale", _number(float(obj.get("scale", 1.0)), 0.1, 20, 0.1, func(v): obj.scale = v; object_changed.emit(obj.uid)))
	var props_spec: Dictionary = spec.get("props", {})
	if not obj.has("props"):
		obj.props = {}
	for key in props_spec:
		var field: Dictionary = props_spec[key]
		if not obj.props.has(key):
			obj.props[key] = field.get("default")
		_row(key.capitalize(), _prop_editor(key, field))
	var hint := Main.note_label("Delete: remove   Ctrl+D: duplicate   Q/E: turn   F: focus")
	add_child(hint)


func _rename(new_uid: String) -> void:
	new_uid = new_uid.strip_edges().to_lower().replace(" ", "_")
	if new_uid == "" or new_uid == obj.uid:
		return
	for o in level.objects:
		if o.uid == new_uid:
			return   # taken
	before_change.emit()
	var old_uid: String = obj.uid
	obj.uid = new_uid
	# Keep events pointing at the renamed object.
	for event in level.get("events", []):
		if event.get("when", {}).get("object") == old_uid:
			event.when.object = new_uid
		for action in event.get("do", []):
			if action.get("object") == old_uid:
				action.object = new_uid
	object_renamed.emit(old_uid, new_uid)


func _prop_editor(key: String, field: Dictionary) -> Control:
	var value = obj.props[key]
	var set_value := func(v):
		obj.props[key] = v
		object_changed.emit(obj.uid)
	match field.get("kind"):
		"int":
			return _number(float(value), field.get("min", -99999), field.get("max", 99999), 1, func(v): set_value.call(int(v)))
		"float":
			return _number(float(value), field.get("min", -99999), field.get("max", 99999), 0.5, set_value)
		"bool":
			var check := CheckBox.new()
			check.button_pressed = bool(value)
			check.toggled.connect(func(on): before_change.emit(); set_value.call(on))
			return check
		"vec3":
			return _vec3_editor(value if value is Array else [0, 0, 0], set_value)
		"level":
			var option := OptionButton.new()
			option.add_item("(choose a level)")
			option.set_item_metadata(0, "")
			for id in App.level_ids():
				option.add_item(App.levels[id].get("title", id))
				option.set_item_metadata(option.item_count - 1, id)
				if id == value:
					option.select(option.item_count - 1)
			option.item_selected.connect(func(i): before_change.emit(); set_value.call(option.get_item_metadata(i)))
			return option
		"lines":
			var text := TextEdit.new()
			text.custom_minimum_size = Vector2(0, 110)
			text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			text.text = "\n".join(value if value is Array else [])
			text.placeholder_text = "One line of dialogue per line"
			text.focus_entered.connect(func(): before_change.emit())
			text.text_changed.connect(func():
				var lines := []
				for line in text.text.split("\n"):
					if line.strip_edges() != "":
						lines.append(line)
				obj.props[key] = lines)
			return text
		"rom_model":
			var box := HBoxContainer.new()
			var label := Label.new()
			var default_id: String = App.object_types().get(obj.type, {}).get("rom_model", "")
			if value is Dictionary and value.get("id", "") != "":
				label.text = Rom.model_name(value)
			elif default_id != "" and Rom.is_ready():
				label.text = "Default (%s)" % Rom.model_name(default_id)
			else:
				label.text = "Stand-in shape"
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.clip_text = true
			box.add_child(label)
			var browse := Button.new()
			browse.text = "Choose from ROM..."
			browse.disabled = not Rom.is_ready() or browser == null
			if browse.disabled:
				browse.tooltip_text = "Import your ROM's assets first (project hub)."
			browse.pressed.connect(func():
				browser.pick(BROWSE_CATEGORY.get(obj.type, ""), func(id):
					before_change.emit()
					obj.props[key] = Rom.model_ref(id)
					object_changed.emit(obj.uid)
					_rebuild()))
			box.add_child(browse)
			if value is Dictionary:
				var clear := Button.new()
				clear.text = "✕"
				clear.tooltip_text = "Back to the default"
				clear.pressed.connect(func():
					before_change.emit()
					obj.props[key] = null
					object_changed.emit(obj.uid)
					_rebuild())
				box.add_child(clear)
			return box
		_:
			var line := LineEdit.new()
			line.text = str(value if value != null else "")
			line.focus_entered.connect(func(): before_change.emit())
			line.text_changed.connect(func(t): set_value.call(t))
			return line


# --- level and game -------------------------------------------------------------------------

func _build_level_settings() -> void:
	add_child(Main.title_label("Level", 22))
	add_child(Main.note_label("Nothing selected. Click an object to edit it, or pick one from the palette to place it."))
	var title := LineEdit.new()
	title.text = level.get("title", "")
	title.focus_entered.connect(func(): before_change.emit())
	title.text_changed.connect(func(t): level.title = t; game_changed.emit())
	_row("Title", title)
	var id_label := Label.new()
	id_label.text = level.get("id", "")
	_row("Id", id_label)
	var base: Dictionary = level.base
	var base_pick := OptionButton.new()
	base_pick.fit_to_longest_item = false
	base_pick.clip_text = true
	base_pick.add_item("Flat ground")
	base_pick.set_item_metadata(0, "")
	for s in Rom.catalog.get("scenes", []):
		base_pick.add_item("BFD scene %d: %s" % [s.index, s.name])
		base_pick.set_item_metadata(base_pick.item_count - 1, s.id)
		if base.get("kind") == "rom_scene" and base.get("scene") == s.id:
			base_pick.select(base_pick.item_count - 1)
	base_pick.item_selected.connect(func(i):
		before_change.emit()
		var scene_id: String = base_pick.get_item_metadata(i)
		base.kind = "rom_scene" if scene_id != "" else "blank"
		if scene_id != "":
			base.scene = scene_id
		else:
			base.erase("scene")
		level_changed.emit()
		_rebuild())
	_row("Stands on", base_pick)
	if not Rom.is_ready():
		add_child(Main.note_label("Import your ROM's assets (project hub) to build on real Bad Fur Day scenes."))
	if base.get("kind") == "rom_scene":
		add_child(Main.note_label("Place Conker Start on the scene's floor: things you place land on its surfaces."))
		_build_game_settings()
		return
	var ground: Dictionary = level.base.ground
	var size: Array = ground.get("size", [60, 60])
	var sx := _number(float(size[0]), 10, 1000, 5, func(v): ground.size = [v, ground.size[1]]; level_changed.emit())
	var sz := _number(float(size[1]), 10, 1000, 5, func(v): ground.size = [ground.size[0], v]; level_changed.emit())
	var size_box := HBoxContainer.new()
	size_box.add_child(sx)
	size_box.add_child(sz)
	_row("Ground size", size_box)
	var color := ColorPickerButton.new()
	color.color = Color(ground.get("color", "#5f8a3a"))
	color.custom_minimum_size = Vector2(80, 30)
	color.color_changed.connect(func(c): ground.color = "#" + c.to_html(false); level_changed.emit())
	_row("Ground colour", color)
	_row("Music (ROM track)", _number(float(level.get("music", {}).get("rom_track", 0)), 0, 452, 1,
			func(v): level.music = {"rom_track": int(v)}))

	_build_game_settings()


func _build_game_settings() -> void:
	add_child(HSeparator.new())
	add_child(Main.title_label("Game", 22))
	var game_title := LineEdit.new()
	game_title.text = App.game.get("title", "")
	game_title.text_changed.connect(func(t): App.game.title = t; game_changed.emit())
	_row("Title", game_title)
	var start := OptionButton.new()
	for id in App.level_ids():
		start.add_item(App.levels[id].get("title", id))
		start.set_item_metadata(start.item_count - 1, id)
		if id == App.game.get("start_level"):
			start.select(start.item_count - 1)
	start.item_selected.connect(func(i): App.game.start_level = start.get_item_metadata(i))
	_row("Starts in", start)
	add_child(Main.note_label("Chapters: " + ", ".join(App.game.get("chapters", []).map(
			func(c): return "%s (%d levels)" % [c.title, c.levels.size()]))))


# --- small widgets --------------------------------------------------------------------------

func _row(label_text: String, control: Control) -> void:
	var label := Label.new()
	label.text = label_text
	label.add_theme_color_override("font_color", Color("c9b8a0"))
	add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(control)


func _number(value: float, low: float, high: float, step: float, on_change: Callable) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = 1 if step >= 1 else 0.01
	spin.custom_arrow_step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.get_line_edit().focus_entered.connect(func(): before_change.emit())
	spin.value_changed.connect(func(v): on_change.call(v))
	return spin


func _vec3_editor(value: Array, on_change: Callable) -> HBoxContainer:
	var box := HBoxContainer.new()
	var v := [float(value[0]), float(value[1]), float(value[2])]
	for i in 3:
		var spin := _number(v[i], -9999, 9999, 0.5, func(x):
			v[i] = x
			on_change.call(v.duplicate()))
		spin.prefix = ["x", "y", "z"][i]
		box.add_child(spin)
	return box
