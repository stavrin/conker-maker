# Plays the template's Mrs. Bee quest: the opening cutscene, grabbing the hive (the wasps wake),
# giving it back (the wasps die, the reward appears) and the cash grab with dollar-sign eyes.
# Needs LIB for the models. Usage: -- <out dir for pictures>
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

func tap(code: int) -> void:
	key(code, true)
	await get_tree().process_frame
	key(code, false)
	await get_tree().process_frame

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
	for id in ["mrs_bee", "test_level"]:
		App.levels[id] = JSON.parse_string(FileAccess.get_file_as_string("res://../templates/new_game/levels/%s.json" % id))
	p = PlayMode.new()
	add_child(p)
	p.start("mrs_bee")
	await frames(60)
	check("the opening cutscene plays", p.cinematic > 0 and p.cut_camera, "cinematic=%d" % p.cinematic)
	await frames(90)
	await shot("1_intro")
	for i in 12:   # through the lines
		await tap(KEY_E)
		await frames(20)
	await shot("1b_intro_line")
	await tap(KEY_TAB)
	await frames(30)
	check("Tab skips to the end of it", p.cinematic == 0 and not p.busy, "cinematic=%d busy=%s" % [p.cinematic, p.busy])
	check("Conker walked over to Mrs. Bee", p.player.global_position.distance_to(Vector3(3.5, 0, -6.5)) < 0.6, str(p.player.global_position))
	check("the reward is hidden", p.hidden.has("reward"))
	# Up the hill to the hive.
	p.player.global_position = Vector3(-18, 4.1, -20.9)
	await frames(40)
	check("picks the hive up", p.carrying == "hive", "carrying='%s'" % p.carrying)
	await frames(30)
	await shot("2_grab")
	await tap(KEY_TAB)
	await frames(10)
	check("grabbing it wakes the wasps", p.flags.has("hive_taken") and p.cinematic == 0)
	var w0: Vector3 = p.objects["wasp_2"].node.global_position
	p.player.global_position = Vector3(-6, 0.1, -12)
	await frames(90)
	var w1: Vector3 = p.objects["wasp_2"].node.global_position
	check("the wasps chase him, flying", w1.distance_to(p.player.global_position) < w0.distance_to(p.player.global_position) - 2.0 and w1.y > 0.8,
			"wasp %s -> %s" % [w0, w1])
	await shot("3_chased")
	# Back to Mrs. Bee.
	p.health = 6
	p.player.global_position = Vector3(5, 0.1, -8)
	await frames(30)
	check("gives the hive back", p.carrying == "" and p.objects["hive"].get("delivered", false))
	await frames(60)
	await shot("4_return")
	await tap(KEY_TAB)
	await frames(30)
	check("the wasps are defeated", p.objects["wasp_1"].get("dead", false) and p.objects["wasp_3"].get("dead", false))
	check("the reward appears", not p.hidden.has("reward") and p.flags.has("hive_returned"))
	check("Mrs. Bee has gone into her armed hive", p.hidden.has("mrs_bee") and not p.hidden.has("armed_hive"))
	# The cash grab.
	var cash0: int = p.cash
	p.player.global_position = (p.objects["reward"].node as Node3D).global_position + Vector3(0, 0.1, 0.3)
	await frames(15)
	check("the grab is a cutscene", p.cinematic > 0, "cinematic=%d" % p.cinematic)
	check("with dollar-sign eyes", p._eye_swaps.size() > 0, "%d pupils swapped" % p._eye_swaps.size())
	await frames(25)
	await shot("5_cash_grab")
	await frames(120)
	check("gets the $100", p.cash == cash0 + 100 and p.cinematic == 0, "cash %d -> %d" % [cash0, p.cash])
	check("eyes back to normal", p._eye_swaps.is_empty())
	get_tree().quit()
