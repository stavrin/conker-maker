# Smoke test: drives the app's screens without a person. Run headless:
#   godot --headless --path app res://tests/smoke.tscn -- <empty folder for a test project>
extends "res://scripts/main.gd"

func _ready() -> void:
	super._ready()
	var args := OS.get_cmdline_user_args()
	var dir: String = args[0] if args.size() > 0 else OS.get_user_data_dir().path_join("smoke_project")
	App.settings.rom_kind = "us"
	App.settings.rom_description = "smoke test"
	print("catalog types: ", App.object_types().size())
	show_hub()
	await get_tree().process_frame
	var err := App.new_project(dir, "Smoke Test Game")
	assert(err == "", err)
	print("levels: ", App.level_ids())
	show_editor()
	await get_tree().process_frame
	await get_tree().process_frame
	var ed = current
	# Place one of each type at different spots.
	var x := -20.0
	for type in App.object_types():
		ed._on_placed(type, Vector3(x, 0, 15))
		x += 3.0
	print("objects now: ", ed.level().objects.size())
	# Select, rename, change props, undo.
	ed.view.select("cash_1")
	ed.inspector._rename("big_wad")
	print("renamed ok: ", not ed.view.find("big_wad").is_empty())
	ed._push_undo()
	ed.level().objects.pop_back()
	ed.undo()
	print("after undo: ", ed.level().objects.size())
	ed.events._add_event()
	ed._save()
	# Every level, in play mode, for a few frames.
	for id in App.level_ids():
		ed.open_level(id)
		ed._play()
		for i in 30:
			await get_tree().physics_frame
		print("played ", id, ": player at ", ed.play.player.position, " cash ", ed.play.cash)
		ed._stop_play()
	ed.open_level("test_level")
	ed._play()
	# Walk Conker onto the cash and exit to check collecting and level change.
	var p = ed.play
	p.player.position = Vector3(-4, 0.1, -4)
	for i in 5:
		await get_tree().physics_frame
	print("cash after walking onto it: ", p.cash)
	for i in 10:   # click through the intro lines
		p._advance = true
		await get_tree().process_frame
	p.player.position = Vector3(0, 0.1, -22)
	for i in 10:
		await get_tree().physics_frame
	print("level after exit: ", p.level_id, " busy ", p.busy, " pos ", p.player.position, " dlg ", p.dialogue_label.text)
	ed._stop_play()
	App.settings.python = "python3" if OS.get_name() != "Windows" else "python"
	print("cmtools validate: ", App.run_cmtools(["validate", dir]))
	print("SMOKE OK")
	get_tree().quit()
