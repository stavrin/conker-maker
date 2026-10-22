# Screenshots with a real ROM asset library (set LIB to the library folder).
extends "res://scripts/main.gd"

func snap(name: String) -> void:
	for i in 12:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0].path_join(name))

func _ready() -> void:
	super._ready()
	var out: String = OS.get_cmdline_user_args()[0]
	App.settings.rom_kind = "us"
	App.settings.rom_description = "US v1.0 (original)"
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	print("library models: ", Rom.models.size(), " scenes: ", Rom.scenes.size())
	show_hub()
	await snap("hub.png")
	App.new_project(out.path_join("project"), "Conker's Other Bad Day")
	show_editor()
	var ed = current
	ed.view.select("barkeep")
	await snap("editor_rom.png")
	# Give the barkeep a real character, and place some props from the ROM.
	var bk = ed.view.find("barkeep")
	bk.props.model = Rom.model_ref("b01-0075-00")
	ed.view.refresh_object("barkeep")
	ed._arm_model("b03-0000-00")
	ed._on_placed("prop", Vector3(-6, 0, -10))
	ed._arm_model("b03-0039-00")
	ed._on_placed("prop", Vector3(-3, 0, -10))
	ed._arm("")
	ed.view.select("")
	await snap("editor_props.png")
	ed.browser.pick("characters", func(id): print("picked ", id))
	await snap("browser_open.png")
	ed.browser.search.text = "tediz"
	ed.browser.refresh()
	ed.browser.list.select(0)
	ed.browser._show(ed.browser.list.get_item_metadata(0))
	await snap("browser.png")
	ed.browser.hide()
	ed._play()
	await snap("play_rom.png")
	p_walk(ed.play)
	await snap("play_run.png")
	ed._stop_play()
	# A level built on a real Bad Fur Day scene.
	var lvl = ed.level()
	lvl.base.kind = "rom_scene"
	lvl.base.scene = "scene-06"
	ed._reload_view("")
	ed.view.distance = 120
	ed.view._update_camera()
	await snap("editor_scene.png")
	# Drop Conker Start onto the scene's floor, as clicking would, and play there.
	var space = ed.view.get_world_3d().direct_space_state
	var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0, 200, 0), Vector3(0, -200, 0), 1))
	print("floor hit: ", hit.get("position"))
	if hit:
		var st = ed.view.find("start")
		st.position = [hit.position.x, hit.position.y, hit.position.z]
		ed._reload_view("")
	await snap("editor_scene_start.png")
	ed._play()
	await snap("play_scene.png")
	for i in 30:
		await get_tree().physics_frame
	print("player on scene floor: ", ed.play.player.position, " on_floor ", ed.play.player.is_on_floor())
	ed._stop_play()
	ed._save()
	print("validate: ", App.run_cmtools(["validate", App.project_dir]))
	get_tree().quit()

func p_walk(p) -> void:
	Input.action_press("ui_up")
	p.player.velocity = Vector3(0, 0, -7)
	p._play_anim("run")
