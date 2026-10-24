# Play-mode checks with a real ROM library (LIB env var): idle pose, feet on the ground,
# frying pan, solid characters, enemies that chase. Screenshots go to the folder given.
extends "res://scripts/main.gd"

func snap(name: String, frames := 10) -> void:
	for i in frames:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0].path_join(name))

func _ready() -> void:
	super._ready()
	var out: String = OS.get_cmdline_user_args()[0]
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	App.new_project(out.path_join("project"), "Play test")
	show_editor()
	var ed = current
	var lvl = ed.level()
	for o in lvl.objects:
		if o.uid == "barkeep":
			o.props.model = Rom.model_ref("b01-0075-00")
	lvl.events.clear()   # no intro dialogue in the way
	lvl.objects.append({"uid": "teddy", "type": "enemy", "position": [10, 0, -10], "rotation_y": 0, "scale": 1.0,
			"props": {"model": Rom.model_ref("b01-0090-00"), "health": 2, "patrol_radius": 3.0}})
	ed._reload_view("")
	await snap("edit.png")
	ed._play()
	var p = ed.play
	await snap("idle.png", 40)
	print("music playing ", p.music.playing, " track ", p.music_index, " ", p.music.stream)
	print("idle anim: ", p.player_anim.current_animation if p.player_anim else "none", " look y ", p.player.get_node("Look").get_meta("model").get_child(0).position.y)
	# Enemy chases: distance shrinks.
	var teddy = p.objects["teddy"].node
	var d0 = teddy.position.distance_to(p.player.position)
	print("floor ", p.player.is_on_floor(), " busy ", p.busy, " teddy floor ", teddy.is_on_floor(), " home ", p.objects["teddy"].home, " player ", p.player.position)
	for i in 60:
		await get_tree().physics_frame
	var d1 = teddy.position.distance_to(p.player.position)
	print("enemy distance %.2f -> %.2f" % [d0, d1], " vel ", teddy.velocity, " pos ", teddy.position, " wander ", p.objects["teddy"].get("wander"))
	# Frying pan: put Teddy in front of Conker and swing.
	p.knock_t = 0
	for i in 30:
		await get_tree().physics_frame
	var look_dir = -(p.player.get_node("Look") as Node3D).global_transform.basis.z
	teddy.position = p.player.position + look_dir * 1.4
	p.objects["teddy"].cooldown = 5.0
	print("floor before attack ", p.player.is_on_floor())
	p._attack()
	await snap("attack.png", 4)
	print("attacking ", p.attacking, " pan visible ", p.pan.visible if p.pan else "no pan", " anim ", p.player_anim.current_animation)
	for i in 80:
		await get_tree().physics_frame
	print("teddy hits ", p.objects["teddy"].get("hits", 0), " hidden ", p.hidden.has("teddy"))
	# Walk into the barkeep: he's solid.
	var bk = p.objects["barkeep"].node
	p.player.position = bk.position + Vector3(0, 0.1, 3)
	for i in 90:
		p.player.velocity = (bk.position - p.player.position).normalized() * 7.0
		p.player.move_and_slide()
		await get_tree().physics_frame
	print("closest to barkeep: %.2f" % Vector2(p.player.position.x - bk.position.x, p.player.position.z - bk.position.z).length())
	p.cam_zoom = 0.4
	await snap("zoomed.png", 30)
	get_tree().quit()
