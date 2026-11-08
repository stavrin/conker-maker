# Checks swimming in the template's pond: falling in, floating, diving, breath, swimming up,
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
	level.events = []   # no opening dialogue holding Conker still
	App.levels["test_level"] = level
	p = PlayMode.new()
	add_child(p)
	p.start("test_level")
	await frames(2)
	var top := 2.2
	# 1. Drop in from above the middle of the pond.
	p.player.position = Vector3(-16, 4.0, 12)
	p.player.velocity = Vector3.ZERO
	p.cam_yaw = 0.0
	await frames(90)
	check("falls in and swims at the surface", p.swim_state == "surface", "state=%s y=%.2f" % [p.swim_state, p.player.position.y])
	check("floats with his middle just under the top", absf(p.player.position.y - (top - 0.25)) < 0.08, "y=%.2f" % p.player.position.y)
	await shot("swim_surface")
	# 2. Swim around at the surface.
	var x0: float = p.player.position.x
	key(KEY_D, true)
	await frames(30)
	key(KEY_D, false)
	check("swims at the surface", p.player.position.x - x0 > 1.0 and p.swim_state == "surface", "moved %.2f" % (p.player.position.x - x0))
	# 3. Dive to the bottom and collect the cash there.
	p.player.position = Vector3(-16, top - 0.25, 12)
	key(KEY_C, true)
	await frames(70)
	check("dives", p.swim_state == "under" and p.player.position.y < 0.8, "state=%s y=%.2f" % [p.swim_state, p.player.position.y])
	await shot("swim_under")
	key(KEY_C, false)
	await frames(10)
	check("collects the cash at the bottom", p.hidden.has("cash_pond"))
	# 4. Running out of breath hurts.
	var health0: int = p.health
	p.air = 0.05
	await frames(20)
	check("hurts when out of breath", p.health < health0, "health %d -> %d" % [health0, p.health])
	# 5. Swim up to the surface.
	key(KEY_SPACE, true)
	await frames(80)
	key(KEY_SPACE, false)
	await frames(10)
	check("swims up to the surface", p.swim_state == "surface", "state=%s y=%.2f" % [p.swim_state, p.player.position.y])
	# 6. Swim at the east wall (0.4 above the water): climbs out onto it.
	p.player.position = Vector3(-13, top - 0.25, 12)
	p.cam_yaw = 0.0
	key(KEY_D, true)
	for i in 120:
		await frames(1)
		if p.ledge_state == "climb":
			break
	key(KEY_D, false)
	await frames(70)
	check("climbs out over a low wall", p.swim_state == "" and p.player.position.y > 2.5, "state=%s ledge=%s pos=%s" % [p.swim_state, p.ledge_state, p.player.position])
	# 7. Jump out of the water.
	p.player.position = Vector3(-16, top - 0.25, 12)
	p.player.velocity = Vector3.ZERO
	await frames(20)
	key(KEY_SPACE, true)
	await frames(8)
	key(KEY_SPACE, false)
	check("jumps out", p.swim_state == "" and p.player.position.y > top, "state=%s y=%.2f" % [p.swim_state, p.player.position.y])
	await frames(60)
	check("falls back in", p.swim_state != "", "state=%s y=%.2f" % [p.swim_state, p.player.position.y])
	get_tree().quit()
