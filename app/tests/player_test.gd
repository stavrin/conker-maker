# The exported game's flow: title screen, new game, pause, save, back to the title, continue.
# Needs LIB and ROM (your ROM's path). Usage: -- <out dir for pictures>
extends Node

const Player := preload("res://scripts/player.gd")
var out := ""

func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await frames(2)
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))

func check(what: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("  " + detail if detail != "" else ""))

func press(root: Node, text: String) -> bool:
	for b in root.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with(text):
			(b as Button).pressed.emit()
			return true
	return false

func esc() -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	Input.parse_input_event(e)
	await frames(1)
	e = InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = false
	Input.parse_input_event(e)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	App.settings.library_dir = OS.get_environment("LIB")
	App.settings.rom_path = OS.get_environment("ROM")
	App.settings.rom_kind = "us"
	App.settings.rom_description = "US v1.0 (original)"
	Rom.reload()
	App.player_dir = ProjectSettings.globalize_path("res://../templates/new_game")
	for f in DirAccess.get_files_at("user://saves"):   # start with no saves (the title screen is built at once)
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves".path_join(f)))
	var p := Player.new()
	p.save_path = "user://saves/player_test.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(p.save_path))
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(p)
	p.save_path = "user://saves/player_test.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(p.save_path))
	await frames(5)
	await shot("p1_title")
	check("title screen with New game", p.find_children("*", "Button", true, false).any(func(b): return b.text == "New game"))
	check("no Continue without a save", not p.find_children("*", "Button", true, false).any(func(b): return b.text.begins_with("Continue")))
	press(p, "New game")
	await frames(60)
	check("the game starts at the start level", p.play != null and p.play.level_id == App.game.start_level, str(p.play.level_id if p.play else ""))
	await shot("p2_playing")
	p.play.cash = 42
	p.play.collected["x/y"] = true
	await esc()
	await frames(5)
	check("Esc pauses", p.pause_menu != null and p.play.process_mode == Node.PROCESS_MODE_DISABLED)
	await shot("p3_paused")
	await esc()
	await frames(5)
	check("Esc again carries on", p.pause_menu == null and p.play.process_mode == Node.PROCESS_MODE_INHERIT)
	await esc()
	await frames(5)
	press(p.pause_menu, "Save and quit")
	await frames(5)
	check("back at the title", p.play == null and p.pause_menu == null)
	var saved: Dictionary = p._read_save()
	check("saved", int(saved.get("cash", -1)) == 42 and saved.get("collected", {}).has("x/y"), str(saved))
	check("Continue offered", p.find_children("*", "Button", true, false).any(func(b): return b.text.begins_with("Continue")))
	press(p, "Continue")
	await frames(60)
	check("continues with the saved cash", p.play != null and p.play.cash == 42, str(p.play.cash if p.play else -1))
	await shot("p4_continued")
	get_tree().quit()
