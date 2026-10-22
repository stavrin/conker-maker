# The app's screens: ROM gate -> project hub -> editor. Nothing works without a ROM.
extends Control

const RomGate := preload("res://scripts/rom_gate.gd")
const Hub := preload("res://scripts/hub.gd")
const Editor := preload("res://scripts/editor.gd")

var current: Control


func _ready() -> void:
	theme = make_theme()
	var bg := ColorRect.new()
	bg.color = Color("1e1712")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	if App.has_valid_rom():
		show_hub()
	else:
		show_rom_gate()


func switch_to(screen: Control) -> void:
	if current:
		current.queue_free()
	current = screen
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(screen)


func show_rom_gate() -> void:
	var gate := RomGate.new()
	gate.accepted.connect(show_hub)
	switch_to(gate)


func show_hub() -> void:
	var hub := Hub.new()
	hub.project_opened.connect(show_editor)
	hub.change_rom.connect(show_rom_gate)
	switch_to(hub)


func show_editor() -> void:
	var editor := Editor.new()
	editor.closed.connect(show_hub)
	switch_to(editor)


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 15
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("2b211a")
	panel.set_corner_radius_all(6)
	panel.set_content_margin_all(10)
	t.set_stylebox("panel", "PanelContainer", panel)
	var button := StyleBoxFlat.new()
	button.bg_color = Color("4a3526")
	button.set_corner_radius_all(5)
	button.set_content_margin_all(8)
	var hover := button.duplicate()
	hover.bg_color = Color("6b4a30")
	var pressed := button.duplicate()
	pressed.bg_color = Color("e8a33c")
	t.set_stylebox("normal", "Button", button)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color("f3e6d3"))
	t.set_color("font_pressed_color", "Button", Color("1e1712"))
	t.set_color("font_color", "Label", Color("f3e6d3"))
	return t


# Small helpers the screens share.
static func title_label(text: String, size := 28) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color("e8a33c"))
	return label


static func note_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color("c9b8a0"))
	return label
