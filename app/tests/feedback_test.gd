# Checks feedback fixes (ledge facing/moving ledges, B swimming). Was: checks swimming in the template's pond: falling in, floating, diving, breath, swimming up,
# climbing out over the wall and jumping out. Needs LIB for Conker's model (works without).
# Usage: -- <out dir for pictures>
extends Node

const PlayMode := preload("res://scripts/play_mode.gd")
var p
var out := ""

func key(code: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)

func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))

func check(what: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("  " + detail if detail != "" else ""))

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	var level = JSON.parse_string(FileAccess.get_file_as_string("res://../templates/new_game/levels/test_level.json"))
	level.events = []
	# A tall block that slides along x, to hang from.
	level.objects.append({"uid": "slider", "type": "platform", "position": [0, 0, -30], "rotation_y": 0, "scale": 1.0,
			"props": {"size": [4, 3, 4], "move": [6, 0, 0], "period": 6.0, "solid": true}})
	App.levels["test_level"] = level
	p = PlayMode.new()
	add_child(p)
	p.start("test_level")
	await frames(2)
	# 1. Hang from the moving block: jump at its south face (z = -28) holding W.
	p.cam_yaw = 0.0
	var slider: Node3D = p.objects["slider"].node
	p.player.position = Vector3(slider.global_position.x, 1.5, -27.3)
	p.player.velocity = Vector3(0, 2, 0)
	key(KEY_W, true)
	for i in 60:
		await frames(1)
		if p.ledge_state == "hang":
			break
	key(KEY_W, false)
	check("catches the ledge", p.ledge_state == "hang", "state=%s pos=%s" % [p.ledge_state, p.player.position])
	var face := -(p.player.get_node("Look") as Node3D).global_transform.basis.z
	check("faces the wall while hanging", face.z < -0.9, "facing %s" % face)
	var off0: Vector3 = p.player.global_position - slider.global_position
	await frames(40)
	var off1: Vector3 = p.player.global_position - slider.global_position   # (within a frame of its motion)
	check("moves with the moving block", off0.distance_to(off1) < 0.1 and p.ledge_state == "hang", "offset %s -> %s" % [off0, off1])
	p.cut_camera = true   # a close side view (the wall is on the right)
	p.camera.global_position = p.player.global_position + Vector3(-3.5, 1.2, 0.0)
	p.camera.look_at(p.player.global_position + Vector3(0, 1.0, 0))
	await frames(20)
	await shot("hang_side")
	key(KEY_W, true)   # climb up
	await frames(12)
	await shot("climb_1")
	await frames(12)
	await shot("climb_2")
	key(KEY_W, false)
	await frames(40)
	p.cut_camera = false
	p.ledge_state = ""
	p.ledge_body = null
	# 2. Underwater, B swims forward and the swimming keeps going.
	p.cam_yaw = 0.0
	p.player.position = Vector3(-16, 1.0, 12)
	p.swim_state = "under"
	(p.player.get_node("Look") as Node3D).rotation.y = 0.0
	await frames(5)
	var z0: float = p.player.position.z
	key(KEY_B, true)
	key(KEY_C, true)   # and hold him down
	await frames(40)
	check("B swims underwater", p.player.position.z < z0 - 1.0 and p.swim_state == "under", "z %.2f -> %.2f" % [z0, p.player.position.z])
	var a = p.player_anim
	check("the swim animation keeps playing", a == null or (a.is_playing() and a.speed_scale >= 0.99), "anim=%s playing=%s speed=%.2f" % [a.current_animation if a else "", a.is_playing() if a else false, a.speed_scale if a else 0.0])
	await shot("swim_b")
	p.cut_camera = true   # side view of the stroke
	p.camera.global_position = p.player.global_position + Vector3(3.0, 0.5, 0)
	p.camera.look_at(p.player.global_position + Vector3(0, 0.3, 0))
	for k in 3:
		await frames(6)
		await shot("stroke_%d" % k)
	p.cut_camera = false
	key(KEY_B, false)
	key(KEY_C, false)
	await frames(10)
	check("treads water when stopped", a == null or (a.is_playing() and p._anim_now == "dive_idle"), p._anim_now)
	get_tree().quit()
