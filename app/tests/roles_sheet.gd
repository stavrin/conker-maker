# Renders the animation roles anim_roles.gd picks for some characters (no reviewed names),
# one row per character: idle, walk, run, attack, hurt, die. Needs LIB; picture to the folder given.
extends Node3D

const AnimRoles := preload("res://scripts/anim_roles.gd")
const IDS := ["b01-0090-00", "b01-0088-00", "b01-0017-00", "b01-0091-00", "b01-0083-00", "b01-0016-00"]
const ROLES := ["idle", "walk", "run", "attack", "hurt", "die"]

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.4, 0.5, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)
	for r in IDS.size():
		var probe := Rom.instance_model(IDS[r])
		var ap := Rom.animation_player(probe)
		var roles := AnimRoles.classify(ap, probe.find_children("*", "Skeleton3D", true, false)[0])
		print(IDS[r], " ", Rom.model_name(IDS[r]), " ", roles)
		probe.free()
		for c in ROLES.size():
			var m := Rom.instance_model(IDS[r])
			m.scale = Vector3.ONE * 0.01
			m.rotation_degrees.y = 60
			m.position = Vector3(c * 2.6 - 6.5, -r * 3.4, 0)
			add_child(m)
			var p := Rom.animation_player(m)
			if roles[ROLES[c]] != "":
				p.play(roles[ROLES[c]])
				p.seek(p.current_animation_length * (0.99 if ROLES[c] == "die" else 0.5), true)
				p.pause()
	var cam := Camera3D.new()
	cam.position = Vector3(0, -7.5, 24)
	add_child(cam)
	cam.look_at(Vector3(0, -7.5, 0))
	for i in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0].path_join("roles.png"))
	get_tree().quit()
