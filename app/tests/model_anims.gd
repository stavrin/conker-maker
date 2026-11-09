# Renders a model in each of its animations (rows), several frames each. Needs LIB.
# Args: <out.png> <model id> [frames]
extends Node3D

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var args := OS.get_cmdline_user_args()
	var id: String = args[1]
	var frames := int(args[2]) if args.size() > 2 else 5
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.55, 0.65)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	add_child(env)
	var probe := Rom.instance_model(id)
	var names := Array(Rom.animation_player(probe).get_animation_list()) if Rom.animation_player(probe) else [""]
	var box := Rom.aabb_of(probe)
	probe.free()
	var s := 1.6 / maxf(box.size.y, 1.0)
	for r in names.size():
		var label := Label3D.new()
		label.text = str(r) + " " + str(names[r]).right(14)
		label.font_size = 40
		label.position = Vector3(-3.6, -r * 2.2 + 0.6, 0)
		add_child(label)
		for c in frames:
			var m := Rom.instance_model(id)
			m.scale = Vector3.ONE * s
			m.rotation_degrees.y = 30 + c * 0
			m.position = Vector3(c * 2.4 - 1.5, -r * 2.2, 0)
			add_child(m)
			var p := Rom.animation_player(m)
			if p and names[r] != "":
				p.play(names[r])
				p.seek(p.current_animation_length * c / float(frames), true)
				p.pause()
				print(r, " ", names[r], " ", p.current_animation_length)
	var cam := Camera3D.new()
	var mid := -(names.size() - 1) * 1.1
	cam.position = Vector3(3.0, mid + 0.6, 5.0 + names.size() * 1.6)
	add_child(cam)
	cam.look_at(Vector3(3.0, mid + 0.6, 0))
	for i in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(args[0])
	get_tree().quit()
