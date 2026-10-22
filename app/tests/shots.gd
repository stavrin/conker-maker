# Takes screenshots of the editor and play mode (needs a display; used for docs and checks).
extends "res://scripts/main.gd"

func _ready() -> void:
	super._ready()
	var out: String = OS.get_cmdline_user_args()[0]
	var dir := out.path_join("project")
	App.settings.rom_kind = "us"
	App.settings.rom_description = "US v1.0 (original)"
	App.new_project(dir, "Conker's Other Bad Day")
	show_editor()
	var ed = current
	for i in 20:
		await get_tree().process_frame
	ed.view.select("barkeep")
	for i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out.path_join("editor.png"))
	ed.view.select("")
	for i in 5:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out.path_join("editor_level.png"))
	ed._play()
	for i in 90:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out.path_join("play.png"))
	print("dialogue ", ed.play.dialogue.visible, " ", ed.play.dialogue.get_global_rect(), " ", ed.play.dialogue_label.text)
	ed._stop_play()
	App.settings.rom_path = ""
	App.settings.rom_kind = ""
	show_rom_gate()
	for i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out.path_join("rom_gate.png"))
	get_tree().quit()
