# Drops Conker at random spots in ROM levels and runs him in random directions for a second;
# reports where he barely moves (stuck). Needs LIB. Usage: -- <out dir> [scene ids...]
extends Node

const PlayMode := preload("res://scripts/play_mode.gd")

func key(code: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var args := OS.get_cmdline_user_args()
	var ids: Array = args.slice(1) if args.size() > 1 else ["scene-06", "scene-43", "scene-57", "scene-41", "scene-61"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var total := 0
	var stuck := 0
	for id in ids:
		App.levels["stuck"] = {"id": "stuck", "title": id, "base": {"kind": "rom_scene", "scene": id},
				"objects": [{"uid": "s", "type": "player_start", "position": [0, 0, 0], "props": {}}], "events": []}
		var p := PlayMode.new()
		add_child(p)
		p.start("stuck")
		await get_tree().physics_frame
		var box := Rom.aabb_of(p.get_node("Ground"))
		var space := p.get_world_3d().direct_space_state
		var probe := OS.get_environment("PROBE")
		if probe != "":
			var v := probe.split(",")
			var at := Vector3(float(v[0]), float(v[1]), float(v[2]))
			for d in 8:
				p.player.position = at + Vector3(0, 0.3, 0)
				p.player.velocity = Vector3.ZERO
				p.cam_yaw = d * TAU / 8
				for i in 20:
					await get_tree().physics_frame
				var s0: Vector3 = p.player.position
				key(KEY_W, true)
				for i in 40:
					await get_tree().physics_frame
				key(KEY_W, false)
				print("dir %d moved %.2f floor %s wall %s wallnormal %s colls %d" % [d, Vector2(p.player.position.x - s0.x, p.player.position.z - s0.z).length(),
						p.player.is_on_floor(), p.player.is_on_wall(), p.player.get_wall_normal() if p.player.is_on_wall() else Vector3.ZERO, p.player.get_slide_collision_count()])
			get_tree().quit()
			return
		var tries := 0
		while tries < 12:
			var x := rng.randf_range(box.position.x, box.end.x)
			var z := rng.randf_range(box.position.z, box.end.z)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, box.end.y + 5, z), Vector3(x, box.position.y - 5, z)))
			if hit.is_empty() or hit.normal.y < 0.7:
				continue
			tries += 1
			p.player.position = hit.position + Vector3(0, 0.5, 0)
			p.player.velocity = Vector3.ZERO
			p.cam_yaw = rng.randf() * TAU
			for i in 20:
				await get_tree().physics_frame
			var start: Vector3 = p.player.position
			key(KEY_W, true)
			if rng.randf() < 0.5:
				key(KEY_SPACE, true)
			for i in 60:
				await get_tree().physics_frame
				if i == 10:
					key(KEY_SPACE, false)
			key(KEY_W, false)
			key(KEY_SPACE, false)
			var moved: float = Vector2(p.player.position.x - start.x, p.player.position.z - start.z).length()
			total += 1
			if moved < 0.8:
				stuck += 1
				print("STUCK %s at %s moved %.2f floor %s wall %s normal %s" % [id, start, moved, p.player.is_on_floor(), p.player.is_on_wall(),
						p.player.get_floor_normal() if p.player.is_on_floor() else Vector3.ZERO])
		p.queue_free()
		await get_tree().process_frame
	print("stuck %d of %d" % [stuck, total])
	get_tree().quit()
