# The editor's Export game and Play as a game. Needs LIB and ROM. Usage: -- <out dir>
extends "res://scripts/main.gd"

func _ready() -> void:
	super._ready()
	var out: String = OS.get_cmdline_user_args()[0]
	App.settings.library_dir = OS.get_environment("LIB")
	App.settings.rom_path = OS.get_environment("ROM")
	App.settings.rom_kind = "us"
	Rom.reload()
	var proj := out.path_join("project")
	DirAccess.make_dir_recursive_absolute(out)
	print("new project: ", App.new_project(proj, "Export Test"), " dir ", App.project_dir, " title ", App.game.get("title"))
	show_editor()
	await get_tree().process_frame
	var ed = current
	print("player exe: '", ed.player_exe(), "'")
	ed._ask_export()
	await get_tree().process_frame
	var dialogs = ed.find_children("*", "FileDialog", true, false)
	print("dialog shown: ", dialogs.size() > 0 and dialogs[0].visible)
	ed._export_game(out.path_join("exported"))
	for f in ["game/game.json", "catalog/objects.json", "cmtools/cli.py", "README.txt"]:
		print(f, " ", FileAccess.file_exists(out.path_join("exported").path_join(f)))
	print("files: ", DirAccess.get_files_at(out.path_join("exported")))
	print(ed.output.get_parsed_text())
	ed._play_as_game()
	await get_tree().create_timer(1.0).timeout
	print(ed.output.get_parsed_text().split("\n").slice(-3))
	get_tree().quit()
