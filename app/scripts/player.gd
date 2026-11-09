# The exported game: what someone who's been given a Conker Maker game sees. No editor: it asks
# for their own ROM, reads the game's models and sounds from it once (the same import the editor
# uses), then a title screen, the game itself, a pause menu and saving.
#
# A game folder made by "Export game" holds the player executable, game/ (the project), catalog/
# and cmtools/. None of Bad Fur Day's data is in it: everything comes from the player's ROM.
extends Control

const RomGate := preload("res://scripts/rom_gate.gd")
const PlayMode := preload("res://scripts/play_mode.gd")
const Main := preload("res://scripts/main.gd")

var current: Control
var play: PlayMode
var pause_menu: CanvasLayer
var save_path := ""
var _poll := 0.0
var _import_label: Label
var _import_bar: ProgressBar


func _ready() -> void:
	var error := App.open_project(App.player_dir, false)
	var title := str(App.game.get("title", "Conker Maker game"))
	DisplayServer.window_set_title(title)
	save_path = "user://saves".path_join(_slug(title) + ".json")
	if error != "":
		_screen(_message("This game is damaged", error))
		return
	_next()


# Whatever comes next: the ROM, then the game's models, then the title screen.
func _next() -> void:
	if not App.has_valid_rom():
		var gate := RomGate.new()
		gate.heading = str(App.game.get("title", ""))
		gate.intro = ("This game was made with Conker Maker, on top of Conker's Bad Fur Day. To play it you need "
				+ "your own copy of the game.\n\nPick your US ROM (.z64, .v64 or .n64). It stays on your computer: "
				+ "the game reads its models, textures and sounds from it.")
		gate.accepted.connect(_next)
		_screen(gate)
	elif not Rom.is_ready():
		_screen(_import_screen())
	elif "--new-game" in OS.get_cmdline_user_args() + OS.get_cmdline_args():   # straight in (for testing)
		_start_game({})
	else:
		_screen(_title_screen())


func _screen(screen: Control) -> void:
	if current:
		current.queue_free()
	current = screen
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(screen)


func _panel(width := 620) -> Array:
	var center := CenterContainer.new()
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	return [center, box]


func _message(heading: String, text: String) -> Control:
	var p := _panel()
	p[1].add_child(Main.title_label(heading, 30))
	p[1].add_child(Main.note_label(text))
	return p[0]


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(action)
	return b


# --- first launch: reading the ROM ----------------------------------------------------------------

func _import_screen() -> Control:
	var p := _panel()
	p[1].add_child(Main.title_label(str(App.game.get("title", "")), 30))
	p[1].add_child(Main.note_label("Before the first game, the models, textures and sounds are read from your ROM "
			+ "(%s). It takes a few minutes, once. It needs Python, and the internet the first time, to fetch "
			+ "the tools that read them." % App.settings.get("rom_description", "")))
	_import_bar = ProgressBar.new()
	_import_bar.visible = false
	p[1].add_child(_import_bar)
	_import_label = Main.note_label("")
	p[1].add_child(_import_label)
	p[1].add_child(_button("Read my ROM", _start_import))
	p[1].add_child(_button("Use a different ROM", func():
		App.settings.rom_kind = ""
		_next()))
	return p[0]


func _start_import() -> void:
	var error := Rom.start_import()
	if error != "":
		_import_label.text = error
		return
	_import_bar.visible = true
	_import_label.text = "Starting..."
	if not Rom.library_changed.is_connected(_import_done):
		Rom.library_changed.connect(_import_done)


func _import_done() -> void:
	if Rom.importing:
		return
	Rom.library_changed.disconnect(_import_done)
	if Rom.is_ready():
		_next()
	else:
		_import_label.text = "That didn't work: " + str(Rom.import_result.get("error", "the import stopped.")) \
				+ "\n\nIs Python 3.12 or newer installed (python.org, tick 'Add to PATH')?"
		_import_bar.visible = false


func _process(delta: float) -> void:
	if not Rom.importing or _import_label == null or not is_instance_valid(_import_label):
		return
	_poll -= delta
	if _poll > 0:
		return
	_poll = 0.5
	var st := Rom.import_status()
	if st.has("steps"):
		_import_bar.max_value = float(st.steps)
		_import_bar.value = float(st.step)
		_import_label.text = "Step %d of %d: %s" % [st.step, st.steps, st.message]


# --- title screen -----------------------------------------------------------------------------

func _title_screen() -> Control:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var p := _panel(520)
	p[1].add_child(Main.title_label(str(App.game.get("title", "")), 40))
	var by := str(App.game.get("author", ""))
	if by != "":
		p[1].add_child(Main.note_label("by " + by))
	var saved := _read_save()
	if not saved.is_empty() and App.levels.has(str(saved.get("level", ""))):
		var where := str(App.levels[saved.level].get("title", saved.level))
		p[1].add_child(_button("Continue  (%s, $%d)" % [where, int(saved.get("cash", 0))], func(): _start_game(saved)))
	p[1].add_child(_button("New game", func(): _start_game({})))
	p[1].add_child(_button("Controls", func(): _screen(_controls_screen())))
	p[1].add_child(_button("Quit", func(): get_tree().quit()))
	p[1].add_child(Main.note_label("Made with Conker Maker. Conker's Bad Fur Day is © Rare Ltd; this is an unofficial fan game."))
	return p[0]


func _controls_screen() -> Control:
	var p := _panel(620)
	p[1].add_child(Main.title_label("Controls", 30))
	p[1].add_child(Main.note_label(
		"WASD  move   (Shift: walk)\n"
		+ "Space  jump; hold it in the air to hover with your tail\n"
		+ "Mouse  turn the camera   (wheel: zoom; arrow keys turn it too)\n"
		+ "F or left click  frying pan\n"
		+ "E, B or Enter  talk / use a B pad / next line\n"
		+ "In water: C dives, Space swims up, B swims underwater\n"
		+ "Tab  skip a cutscene\n"
		+ "Esc  pause"))
	p[1].add_child(_button("Back", func(): _screen(_title_screen())))
	return p[0]


# --- playing ---------------------------------------------------------------------------------

func _start_game(saved: Dictionary) -> void:
	var level_id := str(saved.get("level", App.game.get("start_level", "")))
	if not App.levels.has(level_id):
		_screen(_message("Can't start", "The game's first level ('%s') is missing." % level_id))
		return
	# The game is drawn in its own viewport, like the editor's preview: the app's background and
	# screens are 2D and would otherwise cover the 3D world.
	var holder := SubViewportContainer.new()
	holder.stretch = true
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.focus_mode = Control.FOCUS_ALL
	var viewport := SubViewport.new()
	viewport.handle_input_locally = false
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.audio_listener_enable_3d = true
	holder.add_child(viewport)
	_screen(holder)
	play = PlayMode.new()
	if not saved.is_empty():
		play.set_state(saved)
	play.finished.connect(_pause, CONNECT_DEFERRED)   # Esc (after this key press is done with)
	play.level_entered.connect(func(id, spawn): _write_save(play.get_state(spawn)))
	viewport.add_child(play)
	holder.grab_focus()
	play.start(level_id, str(saved.get("spawn", "")))


func _pause() -> void:
	if play == null or pause_menu:
		return
	play.process_mode = Node.PROCESS_MODE_DISABLED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var layer := CanvasLayer.new()
	layer.layer = 50
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(shade)
	var p := _panel(420)
	p[0].set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(p[0])
	p[1].add_child(Main.title_label("Paused", 30))
	p[1].add_child(_button("Carry on", _resume))
	p[1].add_child(_button("Save", func():
		_write_save(play.get_state())
		(p[1].get_child(2) as Button).text = "Saved"))
	p[1].add_child(_button("Save and quit to the title screen", func():
		_write_save(play.get_state())
		_end_game()))
	p[1].add_child(_button("Quit the game", func():
		_write_save(play.get_state())
		get_tree().quit()))
	add_child(layer)
	pause_menu = layer


func _resume() -> void:
	if pause_menu:
		pause_menu.queue_free()
		pause_menu = null
	if play:
		play.process_mode = Node.PROCESS_MODE_INHERIT
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if current:
			current.grab_focus()


func _end_game() -> void:
	if pause_menu:
		pause_menu.queue_free()
		pause_menu = null
	play = null   # it goes with its viewport, when the title screen replaces it
	_screen(_title_screen())


func _unhandled_input(event: InputEvent) -> void:
	if pause_menu and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_resume()
		get_viewport().set_input_as_handled()


# --- saves -----------------------------------------------------------------------------------

func _read_save() -> Dictionary:
	if not FileAccess.file_exists(save_path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	return data if data is Dictionary else {}


func _write_save(state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(save_path.get_base_dir())
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(state, "  "))


static func _slug(text: String) -> String:
	var out := ""
	for c in text.to_lower():
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	return out.strip_edges() if out.strip_edges() != "" else "game"
