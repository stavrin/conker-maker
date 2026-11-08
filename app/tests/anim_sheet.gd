# Renders Conker in the given animations (by pair number), several frames each, labelled.
# Needs LIB. Args: <out.png> <pair> <pair> ...
extends Node3D

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var args := OS.get_cmdline_user_args()
	var pairs := args.slice(1)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.55, 0.65)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)
	var frames := int(OS.get_environment("FRAMES")) if OS.get_environment("FRAMES") != "" else 4
	for r in pairs.size():
		var probe := Rom.instance_model("b01-0000-00")
		var name := Rom.find_animation(Rom.animation_player(probe), "pair_%04d_" % int(pairs[r]))
		probe.free()
		var label := Label3D.new()
		label.text = pairs[r]
		label.font_size = 64
		label.position = Vector3(-3.4, -r * 2.4 + 0.6, 0)
		add_child(label)
		for c in frames:
			var m := Rom.instance_model("b01-0000-00")
			m.scale = Vector3.ONE * 0.01
			m.rotation_degrees.y = 60
			m.position = Vector3(c * 3.2 - 1.5, -r * 2.4, 0)
			add_child(m)
			var p := Rom.animation_player(m)
			p.play(name)
			p.seek(p.current_animation_length * c / float(frames), true)
			p.pause()
	var cam := Camera3D.new()
	var mid := -(pairs.size() - 1) * 1.2
	cam.position = Vector3(3.3, mid + 0.6, 6.0 + pairs.size() * 1.7)
	add_child(cam)
	cam.look_at(Vector3(3.3, mid + 0.6, 0))
	for i in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(args[0])
	get_tree().quit()
