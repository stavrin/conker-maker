# The level editor: palette | 3D view | inspector, with events and output underneath.
extends Control

signal closed

const Main := preload("res://scripts/main.gd")
const LevelView := preload("res://scripts/level_view.gd")
const Inspector := preload("res://scripts/inspector.gd")
const EventsPanel := preload("res://scripts/events_panel.gd")
const PlayMode := preload("res://scripts/play_mode.gd")
const ModelBrowser := preload("res://scripts/model_browser.gd")

var level_id := ""
var view: LevelView
var play: PlayMode
var viewport: SubViewport
var inspector: Inspector
var events: EventsPanel
var output: RichTextLabel
var level_picker: OptionButton
var palette_buttons := {}
var title_label: Label
var undo_stack := []
var redo_stack := []
var dirty := false
var new_level_dialog: ConfirmationDialog
var new_level_title: LineEdit
var browser: ModelBrowser
var placing_model := ""       # a ROM model the palette's "Prop" will place
var placing_label: Label


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	root.add_child(_toolbar())

	# Split containers take two children each: palette | (middle | inspector).
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	split.add_child(_palette())
	var split_right := HSplitContainer.new()
	split_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(split_right)
	var middle := VSplitContainer.new()
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.split_offset = 480
	split_right.add_child(middle)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.custom_minimum_size = Vector2(400, 300)
	container.gui_input.connect(_on_view_input)
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.focus_mode = Control.FOCUS_ALL
	middle.add_child(container)
	viewport = SubViewport.new()
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.handle_input_locally = false
	container.add_child(viewport)
	view = LevelView.new()
	viewport.add_child(view)
	view.selected.connect(_on_selected)
	view.placed.connect(_on_placed)
	view.moved.connect(func(uid): dirty = true; inspector.show_object(level(), uid))
	view.before_change.connect(_push_undo)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 180)
	middle.add_child(tabs)
	events = EventsPanel.new()
	events.name = "Events"
	events.before_change.connect(_push_undo)
	tabs.add_child(events)
	output = RichTextLabel.new()
	output.name = "Output"
	output.scroll_following = true
	output.selection_enabled = true
	tabs.add_child(output)

	var side := ScrollContainer.new()
	side.custom_minimum_size = Vector2(340, 0)
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split_right.add_child(side)
	inspector = Inspector.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(inspector)
	inspector.before_change.connect(_push_undo)
	inspector.object_changed.connect(func(uid): dirty = true; view.refresh_object(uid))
	inspector.object_renamed.connect(func(old_uid, new_uid): dirty = true; view.rename_node(old_uid, new_uid); events.rebuild(); inspector.show_object(level(), new_uid))
	inspector.level_changed.connect(func(): dirty = true; _reload_view(view.selected_uid))
	inspector.game_changed.connect(func(): dirty = true; _refresh_levels())

	browser = ModelBrowser.new()
	add_child(browser)
	inspector.browser = browser
	_make_new_level_dialog()
	_refresh_levels()
	open_level(App.game.get("start_level", App.level_ids()[0] if App.levels.size() else ""))
	log_line("Opened '%s' from %s" % [App.game.get("title", ""), App.project_dir])
	log_line("ROM: %s" % App.settings.rom_description)


# --- layout ---------------------------------------------------------------------------------

func _toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	var back := Button.new()
	back.text = "◀ Projects"
	back.pressed.connect(func(): _save(); closed.emit())
	bar.add_child(back)
	title_label = Main.title_label(App.game.get("title", ""), 22)
	bar.add_child(title_label)
	level_picker = OptionButton.new()
	level_picker.custom_minimum_size = Vector2(220, 0)
	level_picker.item_selected.connect(func(i): open_level(level_picker.get_item_metadata(i)))
	bar.add_child(level_picker)
	for spec in [["+ Level", _ask_new_level], ["Save", _save], ["Undo", undo], ["Check", _validate],
			["▶ Play here", _play], ["Build", _build], ["▶ Playtest in recomp", _playtest]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		bar.add_child(b)
	return bar


func _palette() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(200, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var group := ""
	var types := App.object_types()
	for type in types:
		var spec: Dictionary = types[type]
		if spec.get("group") != group:
			group = spec.get("group")
			var label := Label.new()
			label.text = group
			label.add_theme_color_override("font_color", Color("e8a33c"))
			box.add_child(label)
		var b := Button.new()
		b.text = spec.label
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = spec.get("help", "")
		b.add_theme_color_override("icon_normal_color", Color(spec.color))
		b.icon = _swatch(Color(spec.color))
		b.toggled.connect(func(on): _arm(type if on else ""))
		palette_buttons[type] = b
		box.add_child(b)
	var rom_label := Label.new()
	rom_label.text = "From your ROM"
	rom_label.add_theme_color_override("font_color", Color("e8a33c"))
	box.add_child(rom_label)
	var rom_button := Button.new()
	rom_button.text = "Browse models..."
	rom_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	rom_button.disabled = not Rom.is_ready()
	rom_button.tooltip_text = "Crates, barrels, signs, characters and more from Bad Fur Day." if Rom.is_ready() \
			else "Import your ROM's assets in the project hub first."
	rom_button.pressed.connect(func(): browser.pick("scene-items", _arm_model))
	box.add_child(rom_button)
	placing_label = Main.note_label("")
	box.add_child(placing_label)
	box.add_child(Main.note_label("\nPick a thing, then click in the level to place it. Right-click (or Esc) to stop placing."))
	return scroll


func _swatch(color: Color) -> Texture2D:
	var image := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _arm_model(id: String) -> void:
	_arm("prop")
	placing_model = id
	placing_label.text = "Placing: " + Rom.model_name(id)
	log_line("Click in the level to place %s. Right-click to stop." % Rom.model_name(id))


func _arm(type: String) -> void:
	placing_model = ""
	if placing_label:
		placing_label.text = ""
	view.placing_type = type
	for t in palette_buttons:
		palette_buttons[t].set_pressed_no_signal(t == type)


# --- levels ---------------------------------------------------------------------------------

func level() -> Dictionary:
	return App.levels.get(level_id, {})


func _refresh_levels() -> void:
	title_label.text = App.game.get("title", "")
	level_picker.clear()
	for id in App.level_ids():
		level_picker.add_item(App.levels[id].get("title", id))
		level_picker.set_item_metadata(level_picker.item_count - 1, id)
		if id == level_id:
			level_picker.select(level_picker.item_count - 1)


func open_level(id: String) -> void:
	if not App.levels.has(id):
		return
	level_id = id
	undo_stack.clear()
	redo_stack.clear()
	_reload_view("")
	_refresh_levels()


func _reload_view(select_uid: String) -> void:
	view.load_level(level())
	events.show_level(level())
	if select_uid != "":
		view.select(select_uid)
	else:
		inspector.show_object(level(), "")


func _make_new_level_dialog() -> void:
	new_level_dialog = ConfirmationDialog.new()
	new_level_dialog.title = "New level"
	new_level_title = LineEdit.new()
	new_level_title.placeholder_text = "Level title, e.g. Windy Woods"
	new_level_dialog.add_child(new_level_title)
	new_level_dialog.confirmed.connect(_create_level)
	add_child(new_level_dialog)


func _ask_new_level() -> void:
	new_level_title.text = ""
	new_level_dialog.popup_centered(Vector2(420, 120))
	new_level_title.grab_focus()


func _create_level() -> void:
	var title := new_level_title.text.strip_edges()
	if title == "":
		return
	var id := title.to_lower().replace(" ", "_").replace("'", "")
	var clean := ""
	for c in id:
		if c in "abcdefghijklmnopqrstuvwxyz0123456789_":
			clean += c
	id = clean.substr(0, 28)
	var base := id
	var n := 2
	while App.levels.has(id):
		id = "%s_%d" % [base, n]
		n += 1
	App.new_level(id, title)
	var chapters: Array = App.game.get("chapters", [])
	if chapters.size() > 0:
		chapters[chapters.size() - 1].levels.append(id)
	dirty = true
	open_level(id)
	log_line("Added level '%s'." % title)


# --- editing --------------------------------------------------------------------------------

func _on_selected(uid: String) -> void:
	inspector.show_object(level(), uid)


func _on_placed(type: String, pos: Vector3) -> void:
	var spec: Dictionary = App.object_types().get(type, {})
	if spec.get("unique", false):
		for obj in level().objects:
			if obj.type == type:
				_push_undo()
				obj.position = [pos.x, pos.y, pos.z]
				view.refresh_object(obj.uid)
				view.select(obj.uid)
				dirty = true
				return
	_push_undo()
	var obj := {"uid": _new_uid(type), "type": type, "position": [pos.x, pos.y, pos.z],
			"rotation_y": 0, "scale": 1.0, "props": App.default_props(type)}
	if type == "prop" and placing_model != "":
		obj.props.model = Rom.model_ref(placing_model)
		obj.uid = _new_uid(_slug(Rom.model_name(placing_model).get_slice(" —", 0)))
	level().objects.append(obj)
	view.refresh_object(obj.uid)
	view.select(obj.uid)
	dirty = true


func _slug(text: String) -> String:
	var out := ""
	for c in text.to_lower().replace(" ", "_").replace("-", "_"):
		if c in "abcdefghijklmnopqrstuvwxyz0123456789_":
			out += c
	return out.left(20).trim_suffix("_") if out != "" else "prop"


func _new_uid(type: String) -> String:
	var used := {}
	for obj in level().objects:
		used[obj.uid] = true
	var n := 1
	while used.has("%s_%d" % [type, n]):
		n += 1
	return "%s_%d" % [type, n]


# While playing with the pointer hidden, the mouse goes straight to the game wherever it is.
func _input(event: InputEvent) -> void:
	if play and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and event is InputEventMouse:
		play.handle_input(event)
		get_viewport().set_input_as_handled()


func _on_view_input(event: InputEvent) -> void:
	if play:
		play.handle_input(event)
		return
	if event is InputEventMouseButton and event.pressed:
		viewport.get_parent().grab_focus()
		if event.button_index == MOUSE_BUTTON_RIGHT and view.placing_type != "":
			_arm("")
			return
	view.handle_input(event)


func _unhandled_key_input(event: InputEvent) -> void:
	if play or not event.pressed:
		return
	var key := event as InputEventKey
	if key.ctrl_pressed and key.keycode == KEY_S:
		_save()
	elif key.ctrl_pressed and key.keycode == KEY_Z:
		undo()
	elif key.ctrl_pressed and key.keycode == KEY_Y:
		redo()
	elif get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:
		return
	elif key.keycode == KEY_ESCAPE:
		_arm("")
	elif view.selected_uid == "":
		return
	elif key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
		var obj := view.find(view.selected_uid)
		if obj.type == "player_start":
			log_line("Every level needs its Conker Start, so it can't be deleted (move it instead).")
			return
		_push_undo()
		level().objects.erase(obj)
		view.remove_node(obj.uid)
		dirty = true
	elif key.ctrl_pressed and key.keycode == KEY_D:
		var obj := view.find(view.selected_uid)
		if App.object_types().get(obj.type, {}).get("unique", false):
			return
		_push_undo()
		var copy: Dictionary = obj.duplicate(true)
		copy.uid = _new_uid(obj.type)
		copy.position = [obj.position[0] + 2, obj.position[1], obj.position[2]]
		level().objects.append(copy)
		view.refresh_object(copy.uid)
		view.select(copy.uid)
		dirty = true
	elif key.keycode == KEY_Q or key.keycode == KEY_E:
		var obj := view.find(view.selected_uid)
		_push_undo()
		# Q/E turn; with Shift they tilt forward/back (X), with Alt left/right (Z).
		var axis := "rotation_x" if key.shift_pressed else ("rotation_z" if key.alt_pressed else "rotation_y")
		obj[axis] = wrapf(float(obj.get(axis, 0)) + (15.0 if key.keycode == KEY_Q else -15.0), -180, 180)
		view.refresh_object(obj.uid)
		inspector.show_object(level(), obj.uid)
		dirty = true
	elif key.keycode == KEY_F:
		view.frame_selected()


func _push_undo() -> void:
	undo_stack.append(level().duplicate(true))
	if undo_stack.size() > 100:
		undo_stack.pop_front()
	redo_stack.clear()


func undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(level().duplicate(true))
	App.levels[level_id] = undo_stack.pop_back()
	dirty = true
	_reload_view(view.selected_uid if not view.find(view.selected_uid).is_empty() else "")


func redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(level().duplicate(true))
	App.levels[level_id] = redo_stack.pop_back()
	dirty = true
	_reload_view("")


# --- save, check, play, build ---------------------------------------------------------------

func _save() -> void:
	App.save_project()
	dirty = false
	log_line("Saved.")


func _validate() -> bool:
	_save()
	var result := App.run_cmtools(["validate", App.project_dir])
	if result.get("ok", false):
		log_line("[color=#7fd37f]No problems found.[/color]")
		return true
	for problem in result.get("problems", [result.get("error", "Unknown problem")]):
		log_line("[color=#ff8a7a]• %s[/color]" % problem)
	return false


func _play() -> void:
	if play:
		return
	_save()
	view.visible = false
	view.process_mode = Node.PROCESS_MODE_DISABLED
	play = PlayMode.new()
	viewport.add_child(play)
	play.finished.connect(_stop_play)
	play.start(level_id)
	viewport.get_parent().grab_focus()
	log_line("Playing '%s'. WASD move, mouse turns the camera, Space jump (hold to hover), F or click: frying pan, E talk/press, Esc back." % level().get("title", level_id))


func _stop_play() -> void:
	play.queue_free()
	play = null
	view.process_mode = Node.PROCESS_MODE_INHERIT
	view.visible = true


func _build() -> bool:
	if not _validate():
		log_line("Fix the problems above, then build again.")
		return false
	log_line("Building with your ROM...")
	await get_tree().process_frame
	var result := App.run_cmtools(["build", App.project_dir, "--rom", App.settings.rom_path])
	if not result.get("ok", false):
		log_line("[color=#ff8a7a]%s[/color]" % result.get("error", "Build failed."))
		return false
	_last_rom = result.rom
	log_line("[color=#7fd37f]Built.[/color] Play: %s\nShare: %s (%d bytes, a patch for players to apply to their own ROM)\nSpace used: %d of %d bytes" % [
			result.rom, result.patch, result.patch_bytes, result.package_bytes, result.package_capacity])
	return true

var _last_rom := ""


func _playtest() -> void:
	if App.settings.recomp_exe == "" or not FileAccess.file_exists(App.settings.recomp_exe):
		log_line("Set where ConkerRecomp.exe is in the project hub's Settings first.")
		return
	if not await _build():
		return
	var pid := OS.create_process(App.settings.recomp_exe, [_last_rom])
	log_line("Started the recomp (pid %d) with your built ROM." % pid)
	log_line("[color=#e8c07a]Note: until the obd_core runtime mod can load your levels into the game (milestone 3), the recomp plays Bad Fur Day from this ROM; it confirms the ROM builds and is accepted.[/color]")


func log_line(text: String) -> void:
	output.append_text(text + "\n")
