# Project hub: start a new game, open one, and the app's settings.
extends Control

signal project_opened
signal change_rom

const Main := preload("res://scripts/main.gd")

var status: Label
var title_edit: LineEdit
var folder_dialog: FileDialog
var exe_dialog: FileDialog
var python_edit: LineEdit
var recomp_label: Label
var pending := ""   # "new" or "open"
var asset_status: Label
var asset_button: Button
var asset_progress: ProgressBar
var _poll := 0.0


func _ready() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	add_child(margin)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 30)
	margin.add_child(cols)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	cols.add_child(left)
	left.add_child(Main.title_label("Conker Maker", 40))
	left.add_child(Main.note_label("ROM: " + App.settings.rom_description))

	var new_panel := PanelContainer.new()
	left.add_child(new_panel)
	var new_box := VBoxContainer.new()
	new_panel.add_child(new_box)
	new_box.add_child(Main.title_label("New game", 22))
	title_edit = LineEdit.new()
	title_edit.text = "Conker's Other Bad Day"
	title_edit.placeholder_text = "Your game's title"
	new_box.add_child(title_edit)
	var new_button := Button.new()
	new_button.text = "Create in a folder..."
	new_button.pressed.connect(func(): pending = "new"; folder_dialog.title = "Choose an empty folder for the new game"; folder_dialog.popup_centered_ratio(0.7))
	new_box.add_child(new_button)

	var open_panel := PanelContainer.new()
	left.add_child(open_panel)
	var open_box := VBoxContainer.new()
	open_panel.add_child(open_box)
	open_box.add_child(Main.title_label("Open a game", 22))
	var open_button := Button.new()
	open_button.text = "Open a project folder..."
	open_button.pressed.connect(func(): pending = "open"; folder_dialog.title = "Open a Conker Maker project"; folder_dialog.popup_centered_ratio(0.7))
	open_box.add_child(open_button)
	for dir in App.settings.recent_projects:
		if FileAccess.file_exists(dir.path_join("game.json")):
			var recent := Button.new()
			recent.text = dir
			recent.alignment = HORIZONTAL_ALIGNMENT_LEFT
			recent.pressed.connect(_open.bind(dir))
			open_box.add_child(recent)
	status = Main.note_label("")
	left.add_child(status)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(420, 0)
	right.add_theme_constant_override("separation", 12)
	cols.add_child(right)
	var settings_panel := PanelContainer.new()
	right.add_child(settings_panel)
	var s := VBoxContainer.new()
	settings_panel.add_child(s)
	s.add_child(Main.title_label("Settings", 22))
	s.add_child(Main.note_label("Conker's Bad Fur Day: Recompiled (for playtesting your game in the real engine):"))
	recomp_label = Main.note_label(App.settings.recomp_exe if App.settings.recomp_exe != "" else "(not set)")
	s.add_child(recomp_label)
	var exe_button := Button.new()
	exe_button.text = "Find ConkerRecomp.exe..."
	exe_button.pressed.connect(func(): exe_dialog.popup_centered_ratio(0.7))
	s.add_child(exe_button)
	s.add_child(Main.note_label("Python (runs the build tools until they ship as cmtools.exe):"))
	python_edit = LineEdit.new()
	python_edit.text = App.settings.python
	python_edit.text_changed.connect(func(t): App.settings.python = t; App.save_settings())
	s.add_child(python_edit)
	var rom_button := Button.new()
	rom_button.text = "Use a different ROM..."
	rom_button.pressed.connect(func(): change_rom.emit())
	s.add_child(rom_button)

	var assets_panel := PanelContainer.new()
	right.add_child(assets_panel)
	var a := VBoxContainer.new()
	assets_panel.add_child(a)
	a.add_child(Main.title_label("Assets from your ROM", 22))
	asset_status = Main.note_label("")
	a.add_child(asset_status)
	asset_progress = ProgressBar.new()
	asset_progress.visible = false
	a.add_child(asset_progress)
	asset_button = Button.new()
	asset_button.pressed.connect(_start_import)
	a.add_child(asset_button)
	_update_assets()

	folder_dialog = FileDialog.new()
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	folder_dialog.dir_selected.connect(_on_folder)
	add_child(folder_dialog)
	exe_dialog = FileDialog.new()
	exe_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	exe_dialog.access = FileDialog.ACCESS_FILESYSTEM
	exe_dialog.filters = PackedStringArray(["*.exe ; Programs", "* ; All files"])
	exe_dialog.file_selected.connect(func(p): App.settings.recomp_exe = p; App.save_settings(); recomp_label.text = p)
	add_child(exe_dialog)


func _on_folder(dir: String) -> void:
	if pending == "new":
		status.text = "Creating..."
		await get_tree().process_frame
		var title := title_edit.text.strip_edges()
		var error := App.new_project(dir, title if title != "" else "Conker's Other Bad Day")
		if error != "":
			status.text = error
			return
		project_opened.emit()
	else:
		_open(dir)


func _open(dir: String) -> void:
	var error := App.open_project(dir)
	if error != "":
		status.text = error
		return
	project_opened.emit()


# --- ROM assets ---------------------------------------------------------------------------------

func _update_assets() -> void:
	if Rom.importing:
		asset_button.disabled = true
		asset_button.text = "Importing..."
		asset_progress.visible = true
		return
	asset_button.disabled = false
	asset_progress.visible = false
	if Rom.is_ready():
		asset_status.text = "Ready: %d models and %d level scenes from your ROM. Choose them in the editor's palette and inspector." % [
				Rom.models.size(), Rom.scenes.size()]
		asset_button.text = "Import again"
	else:
		asset_status.text = "Not imported yet. Conker Maker reads Bad Fur Day's models, textures and level scenes " \
				+ "out of your ROM into a private library on this computer (about 300 MB, once per ROM). " \
				+ "It takes 5 to 15 minutes and needs Python 3.12 or newer, plus Git or an internet connection the first time."
		asset_button.text = "Import assets from my ROM"
	if Rom.import_result.has("ok") and not Rom.import_result.ok:
		asset_status.text = "The import didn't finish: " + str(Rom.import_result.get("error", "")) \
				+ "\n(Details: import.log in " + Rom.dir + ")\n\n" + asset_status.text
	elif not Rom.import_result.get("warnings", []).is_empty():
		asset_status.text += "\n\nSome parts couldn't be read from this ROM and were skipped:\n• " \
				+ "\n• ".join(Rom.import_result.warnings)


func _start_import() -> void:
	asset_status.text = "Starting..."
	var error := Rom.start_import()
	if error != "":
		asset_status.text = error
		return
	if not Rom.library_changed.is_connected(_update_assets):
		Rom.library_changed.connect(_update_assets)
	_update_assets()


func _process(delta: float) -> void:
	if not Rom.importing:
		return
	_poll -= delta
	if _poll > 0:
		return
	_poll = 0.5
	var st := Rom.import_status()
	if st.has("steps"):
		asset_progress.max_value = float(st.steps)
		asset_progress.value = float(st.step)
		var elapsed := int(Time.get_unix_time_from_system() - float(st.get("started", 0)))
		asset_status.text = "Step %d of %d: %s  (%d:%02d)" % [st.step, st.steps, st.message, elapsed / 60, elapsed % 60]
