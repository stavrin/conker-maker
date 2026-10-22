# "Plug in your ROM": Conker Maker does nothing until it has the player's own copy of the game.
extends Control

signal accepted

const Main := preload("res://scripts/main.gd")

var status: Label
var dialog: FileDialog


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	box.add_child(Main.title_label("Conker Maker", 40))
	box.add_child(Main.note_label(
		"Conker Maker builds games on top of Conker's Bad Fur Day, so it needs your own copy of the game.\n\n"
		+ "Pick your US ROM (.z64, .v64 or .n64). The uncensored hack works too. It stays on your computer; "
		+ "Conker Maker reads models, textures and sounds from it and never shares it."))
	var pick := Button.new()
	pick.text = "Choose my ROM..."
	pick.pressed.connect(func(): dialog.popup_centered_ratio(0.7))
	box.add_child(pick)
	status = Main.note_label("")
	box.add_child(status)
	if App.settings.rom_path != "":
		status.text = "The ROM you used last time is missing: " + App.settings.rom_path

	dialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.z64, *.v64, *.n64 ; N64 ROMs"])
	dialog.title = "Choose your Conker's Bad Fur Day ROM"
	dialog.file_selected.connect(_on_file)
	add_child(dialog)


func _on_file(path: String) -> void:
	status.text = "Checking..."
	await get_tree().process_frame
	var result := App.check_rom(path)
	if not result.ok:
		status.text = "Not that one: " + result.error
		return
	App.settings.rom_path = path
	App.settings.rom_kind = result.kind
	App.settings.rom_description = result.description
	App.save_settings()
	status.text = "Got it: %s (%s)." % [result.description, result.order]
	await get_tree().create_timer(0.6).timeout
	accepted.emit()
