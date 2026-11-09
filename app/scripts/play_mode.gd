# Quick playtest inside Conker Maker: walk around your levels with a stand-in Conker, collect
# things, talk to characters and run your events. It's for checking layouts and logic fast;
# "Playtest in recomp" runs the real game.
#
#   WASD move (Shift: walk)   Space jump (hold in the air to hover with the tail)
#   F or left click: frying pan (on the ground or in the air)   E / B interact   Esc back to the editor
#   In water: WASD swim, Space jumps out (underwater: swims up), C dives (underwater: swims down);
#   swim into a low bank to climb out. Conker holds his breath for a while underwater.
#   Walk into a Carried Item to pick it up; take it to where it's delivered. Tab skips a cutscene.
#   Camera: the mouse turns it (the pointer is hidden while you play), arrow keys too, the
#   wheel zooms; it pulls in near walls, like the recomp's camera
#   (CBFD-Recompiled host/src/mouse_camera.cpp).
#
# Enemies walk, run at Conker, attack him up close, flinch when hit and die with their own
# ROM animations (anim_roles.gd picks which is which), and bleed like they do in Bad Fur Day:
# a spray, a pool on the floor, and splats on the screen when it happens near the camera.
extends Node3D

signal finished
signal level_entered(id: String, spawn: String)   # (the exported player saves here)

const Visuals := preload("res://scripts/visuals.gd")
const SPEED := 7.0
const JUMP := 10.5          # about 2.3 m: Conker's jump clears a crate with room to spare
const GRAVITY := 24.0
const HOVER_FALL := 1.5
const HOVER_TIME := 2.0
const WALK_SPEED := 3.0
# The game's farthest follow-camera distance: 530 units back and 400 up (D_800A34B0,
# CBFD-Recompiled mouse_camera.cpp). One unit is a centimetre here. The wheel scales the
# distance by 1.12 a notch, down to about a third of that.
const CAM_FAR := Vector2(5.3, 4.0)
const CAM_NEAR_SHARE := 0.32
const CAM_ZOOM_STEP := 1.12
const CAM_LOOK_HEIGHT := 1.2
const CAM_WALL_MARGIN := 0.3

var level := {}
var level_id := ""
var player: CharacterBody3D
var camera: Camera3D
var cam_yaw := 0.0
var hover_left := HOVER_TIME
var cash := 0
var health := 6
var lives := 3
var flags := {}
var collected := {}         # "level/uid" -> true: pickups taken stay taken across levels
var hidden := {}            # uid -> true
var fired := {}             # event id -> true (zones fire once)
var objects := {}           # uid -> {obj, node}
var respawn := Vector3.ZERO
var busy := false           # running a dialogue
var hud: Label
var dialogue: PanelContainer
var dialogue_label: Label
var hint: Label
var _advance := false
var player_anim: AnimationPlayer
var _anim_now := ""
# Conker's animations in the ROM, by logical animation pair (bank 02 routes). Set in catalog/objects.json.
var PLAYER_ANIMS: Dictionary = App.catalog.get("player", {}).get("animations", {})
var _mouse_turn := false
var cam_pitch := 0.0          # extra tilt from the mouse, radians
var cam_zoom := 0.75          # share of the farthest distance
var cam_arm := 1.0            # how much of the wanted distance walls allow, eased
var attacking := false
var attack_t := 0.0
var attack_hit_done := false
var pan: Node3D               # the frying pan, shown during the attack
var idle_time := 0.0
var knock_t := 0.0
var PAN: Dictionary = App.catalog.get("player", {}).get("frying_pan", {})
var HOVER_SPEED := float(App.catalog.get("player", {}).get("hover_speed", 2.2))   # tail spin speed
var splat_layer: CanvasLayer
var flash: ColorRect
const Blood := preload("res://scripts/blood.gd")
var music: AudioStreamPlayer
var music_index := -1
# Swimming (Water objects). Settings in catalog/objects.json ("player" -> "swim").
var SWIM: Dictionary = App.catalog.get("player", {}).get("swim", {})
var swim_state := ""          # "", "surface" or "under"
var swim_top := 0.0           # the surface of the water Conker is in
var air := 0.0                # seconds of breath left underwater
var drown_t := 0.0
var underwater_tint: ColorRect
var _dive_held := false
# Cutscenes (events ticked "Cutscene"), carried items and quest rewards.
var cinematic := 0            # cutscenes running: Conker waits, black bars
var _skip := false            # Tab: finish the cutscene straight away
var cut_camera := false       # a cutscene camera has the view
var bars: Array = []          # the black bars at the top and bottom
var carrying := ""            # uid of the item Conker is carrying
var waiting := {}             # uid -> story flag a quest reward waits for
var _eye_swaps := []          # [MeshInstance3D, surface] given dollar-sign eyes
static var _dollar_eyes_textures := {}   # mirrored -> ImageTexture


func _ready() -> void:
	Visuals.environment(self)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(20, 16)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_outline_color", Color.BLACK)
	hint.add_theme_constant_override("outline_size", 6)
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint.position.y -= 160
	layer.add_child(hint)
	dialogue = PanelContainer.new()
	dialogue.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	dialogue.offset_top = -130
	dialogue.offset_left = 80
	dialogue.offset_right = -80
	dialogue.offset_bottom = -20
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.05, 0.03, 0.9)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(16)
	dialogue.add_theme_stylebox_override("panel", style)
	dialogue_label = Label.new()
	dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialogue_label.add_theme_font_size_override("font_size", 22)
	dialogue.add_child(dialogue_label)
	dialogue.visible = false
	layer.add_child(dialogue)
	underwater_tint = ColorRect.new()   # the view from under the water
	underwater_tint.color = Color(0.05, 0.25, 0.45, 0.45)
	underwater_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	underwater_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	underwater_tint.visible = false
	layer.add_child(underwater_tint)
	layer.move_child(underwater_tint, 0)
	for top in [true, false]:   # cutscene black bars
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE if top else Control.PRESET_BOTTOM_WIDE)
		bar.offset_top = 0.0
		bar.offset_bottom = 0.0
		layer.add_child(bar)
		bars.append(bar)
	flash = ColorRect.new()   # a red flash when Conker gets hurt
	flash.color = Color(0.7, 0.0, 0.0, 0.0)
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(flash)
	splat_layer = CanvasLayer.new()   # blood on the screen
	splat_layer.layer = 2
	add_child(splat_layer)
	music = AudioStreamPlayer.new()
	music.volume_db = -6.0
	add_child(music)
	camera = Camera3D.new()
	camera.fov = 65
	add_child(camera)
	camera.make_current()


func start(id: String, spawn := "") -> void:
	level_id = id
	level = App.levels[id]
	for child in get_children():
		if child.name == "Ground" or child.name.begins_with("obj_") or child.name.begins_with("plat_") or child == player:
			remove_child(child)
			child.queue_free()
	objects.clear()
	hidden.clear()
	fired.clear()
	waiting.clear()
	carrying = ""
	cinematic = 0
	cut_camera = false
	busy = false
	add_child(Visuals.base(level))
	var start_pos := Vector3.ZERO
	var start_turn := 0.0
	for obj in level.get("objects", []):
		var spec: Dictionary = App.object_types().get(obj.type, {})
		var node: Node3D
		if obj.type in ["platform", "prop"] and obj.props.get("solid", true):
			node = _solid(obj, spec)
		elif obj.type in ["npc", "context_pad", "enemy"]:
			node = _bodied(obj, spec)
		else:
			node = Visuals.build(obj, spec, false)
		if obj.type in ["trigger_zone", "camera", "spot"]:   # editing aids
			node.visible = false
		if obj.type in ["player_start", "spawn_point"]:
			node.visible = false
		for tag in node.find_children("Tag", "Label3D", true, false):   # name tags are for editing
			tag.visible = false
		add_child(node)
		objects[obj.uid] = {"obj": obj, "node": node, "home": node.position, "t": 0.0}
		if obj.type == "enemy":
			_setup_enemy(objects[obj.uid])
		var reward_flag := str(obj.get("props", {}).get("appears_when", ""))
		if obj.type == "cash" and reward_flag != "" and not flags.has(reward_flag):
			waiting[obj.uid] = reward_flag   # a quest's reward: hidden until the flag is set
			_hide(obj.uid)
		if collected.has(id + "/" + str(obj.uid)):
			_hide(obj.uid)
		if obj.type == "player_start" and spawn == "":
			start_pos = node.position
			start_turn = node.rotation.y
		if obj.type == "spawn_point" and spawn != "" and (obj.props.get("name") == spawn or obj.uid == spawn):
			start_pos = node.position
			start_turn = node.rotation.y
	_find_riders()
	_make_player(start_pos, start_turn)
	respawn = start_pos
	_play_music(int(level.get("music", {}).get("rom_track", 0)))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hud()
	level_entered.emit(id, spawn)
	_run_trigger("level_start", "")


# Progress, for saving and loading a game: where Conker is and what he's done.
func get_state(spawn := "") -> Dictionary:
	return {"level": level_id, "spawn": spawn, "cash": cash, "lives": lives, "health": health,
			"flags": flags.duplicate(), "collected": collected.duplicate()}


func set_state(state: Dictionary) -> void:
	cash = int(state.get("cash", 0))
	lives = int(state.get("lives", 3))
	health = int(state.get("health", 6))
	flags = (state.get("flags", {}) as Dictionary).duplicate()
	collected = (state.get("collected", {}) as Dictionary).duplicate()


# Things placed on top of a moving platform ride along with it.
func _find_riders() -> void:
	for uid in objects:
		var p: Dictionary = objects[uid]
		if p.obj.type != "platform" or Visuals.vec3(p.obj.props.get("move"), Vector3.ZERO) == Vector3.ZERO:
			continue
		var size := Visuals.vec3(p.obj.props.get("size"), Vector3(2, 2, 2)) * float(p.obj.get("scale", 1.0))
		var body := p.node as Node3D
		if body.get_child_count() > 0 and body.get_child(0).has_meta("model"):
			size = Rom.aabb_of(body.get_child(0)).size * float(p.obj.get("scale", 1.0))
		p.riders = []
		for other in objects:
			var o: Dictionary = objects[other]
			if o.obj.type in ["platform", "player_start", "spawn_point", "enemy", "npc", "trigger_zone", "water"]:
				continue
			var local: Vector3 = body.global_transform.affine_inverse() * (o.home as Vector3)
			var above: float = (o.home as Vector3).y - (p.home as Vector3).y - size.y
			if absf(local.x) <= size.x / 2.0 + 0.2 and absf(local.z) <= size.z / 2.0 + 0.2 and above > -0.6 and above < 2.5:
				p.riders.append(other)


func _solid(obj: Dictionary, spec: Dictionary) -> Node3D:
	var body := AnimatableBody3D.new()
	body.name = "plat_" + obj.uid
	var visual := Visuals.build(obj, spec, false)
	visual.position = Vector3.ZERO
	visual.rotation = Vector3.ZERO
	visual.scale = Vector3.ONE
	body.add_child(visual)
	if visual.has_meta("model"):
		for shape in Visuals.trimesh_shapes(visual):   # collide with the ROM model's real shape
			body.add_child(shape)
	else:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var size := Visuals.vec3(obj.props.get("size"), Vector3(2, 2, 2))
		box.size = size
		shape.shape = box
		shape.position = Vector3(0, size.y / 2.0, 0)
		body.add_child(shape)
	Visuals.apply_transform(body, obj)
	return body


# Characters, B pads and enemies are solid: Conker bumps into them and stands on pads.
func _bodied(obj: Dictionary, spec: Dictionary) -> Node3D:
	var body: CollisionObject3D = CharacterBody3D.new() if obj.type == "enemy" else StaticBody3D.new()
	body.name = "obj_" + obj.uid
	var visual := Visuals.build(obj, spec, false)
	visual.position = Vector3.ZERO
	visual.rotation = Vector3.ZERO
	visual.scale = Vector3.ONE   # the body carries the object's scale
	visual.name = "Look"
	body.add_child(visual)
	if obj.type == "context_pad" and visual.has_meta("model"):
		for pad_shape in Visuals.trimesh_shapes(visual):   # stand on the pad's real top
			body.add_child(pad_shape)
		Visuals.apply_transform(body, obj)
		return body
	var shape := CollisionShape3D.new()
	if obj.type == "context_pad":
		var box := BoxShape3D.new()
		box.size = Vector3(2.0, 0.2, 2.0)
		shape.shape = box
		shape.position.y = 0.1
	else:
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.45
		capsule.height = 1.7
		shape.shape = capsule
		shape.position.y = 0.85
	body.add_child(shape)
	Visuals.apply_transform(body, obj)
	return body


func _make_player(pos: Vector3, turn: float) -> void:
	player = CharacterBody3D.new()
	player.name = "Player"
	player.floor_max_angle = deg_to_rad(50.0)   # a bit steeper than Godot's 45: mounds and ramps
	player.floor_snap_length = 0.3
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.6
	shape.shape = capsule
	shape.position.y = 0.8
	player.add_child(shape)
	var spec: Dictionary = App.object_types().get("player_start", {})
	var look := Visuals.build({"uid": "conker", "type": "player_start", "props": {"name": "Conker"}}, spec, false)
	look.name = "Look"
	look.get_node("Tag").visible = false
	player.add_child(look)
	player_anim = Rom.animation_player(look) if look.has_meta("model") else null
	if player_anim:
		for key in ["idle", "bored", "walk", "run", "jump", "hover", "hang", "swim_idle", "swim", "dive", "dive_idle"]:
			var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get(key, ""))
			if anim != "":
				player_anim.get_animation(anim).loop_mode = Animation.LOOP_LINEAR
		for key in ["attack", "climb"]:
			var once := Rom.find_animation(player_anim, PLAYER_ANIMS.get(key, ""))
			if once != "":
				player_anim.get_animation(once).loop_mode = Animation.LOOP_NONE
		_play_anim("idle")
		_attach_pan(look)
		for child in look.get_children():   # the editor's facing marker isn't needed on the real model
			if child is MeshInstance3D and child.name != "Selection":
				child.visible = false
	player.position = pos + Vector3(0, 0.1, 0)
	swim_state = ""
	player.rotation.y = turn
	cam_yaw = turn
	cam_arm = 1.0
	add_child(player)
	camera.position = player.position + Basis(Vector3.UP, cam_yaw) * Vector3(0, 3, 6)


# Conker's frying pan, held in his hand (joint 11) and shown only while he swings it.
func _attach_pan(look: Node3D) -> void:
	pan = null
	var found := look.find_children("*", "Skeleton3D", true, false)
	var model := Rom.instance_model(str(PAN.get("model", "")))
	if found.is_empty() or model == null:
		return
	var skeleton: Skeleton3D = found[0]
	var hand := BoneAttachment3D.new()
	hand.bone_name = str(PAN.get("bone", "joint_11"))
	skeleton.add_child(hand)
	hand.add_child(model)
	model.visible = false
	pan = model


func _unhandled_input(event: InputEvent) -> void:
	_handle(event)


func handle_input(event: InputEvent) -> void:
	_handle(event)


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _handle(event: InputEvent) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseButton and event.pressed and not captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # clicking back in hides the pointer again
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_turn = event.pressed
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		cam_zoom = max(CAM_NEAR_SHARE, cam_zoom / CAM_ZOOM_STEP)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		cam_zoom = min(1.0, cam_zoom * CAM_ZOOM_STEP)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_attack()
	elif event is InputEventMouseMotion and (captured or _mouse_turn):
		cam_yaw -= event.relative.x * 0.006
		cam_pitch = clamp(cam_pitch + event.relative.y * 0.004, -0.6, 0.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB and cinematic > 0:
			_skip = true
			_advance = true
		elif event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			finished.emit()
		elif event.keycode == KEY_F:
			_attack()
		elif event.keycode in [KEY_E, KEY_B, KEY_ENTER]:
			if event.keycode == KEY_B and swim_state == "under" and not busy:
				return   # B swims underwater
			if busy:
				_advance = true
			else:
				_interact()


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if Input.is_key_pressed(KEY_LEFT):
		cam_yaw += delta * 2.5
	if Input.is_key_pressed(KEY_RIGHT):
		cam_yaw -= delta * 2.5
	_move_platforms(delta)
	knock_t -= delta
	regrab_t -= delta
	if ledge_state != "":
		_update_ledge(delta)
		_update_camera(delta)
		_check_touches(delta)
		_update_hud()
		return
	var input := Vector2.ZERO
	if not busy and knock_t <= 0.0:
		input.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
		input.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var dir := (Basis(Vector3.UP, cam_yaw) * Vector3(input.x, 0, input.y))
	if dir.length() > 1:
		dir = dir.normalized()
	var walking := Input.is_key_pressed(KEY_SHIFT)
	if _update_water():
		_swim(delta, dir, walking)
		return
	var speed := (WALK_SPEED if walking else SPEED) * (0.15 if attacking and player.is_on_floor() else 1.0)
	if knock_t <= 0.0:
		player.velocity.x = dir.x * speed
		player.velocity.z = dir.z * speed
	var jump := Input.is_key_pressed(KEY_SPACE) and not busy
	# Wedged on a slope too steep to stand on (a crease in a mound): count it as ground, so he
	# can jump out, and slide him off it.
	var wedged := not player.is_on_floor() and player.get_slide_collision_count() > 0 \
			and player.get_real_velocity().length() < 0.6
	wedge_t = wedge_t + delta if wedged else 0.0
	if wedge_t > 0.12:
		var push := Vector3.ZERO
		for i in player.get_slide_collision_count():
			push += player.get_slide_collision(i).get_normal()
		push.y = 0
		if push.length() > 0.01:
			player.velocity += push.normalized() * 3.0
	if player.is_on_floor() or wedge_t > 0.12:
		hover_left = HOVER_TIME
		if jump and not _jump_held:
			player.velocity.y = JUMP
			wedge_t = 0.0
	else:
		player.velocity.y -= GRAVITY * delta
		if jump and not _jump_held_from_floor and player.velocity.y < 0 and hover_left > 0 and carrying == "":
			player.velocity.y = max(player.velocity.y, -HOVER_FALL)   # the tail helicopter
			hover_left -= delta
	if player.is_on_floor():
		_jump_held_from_floor = jump
	elif not jump:
		_jump_held_from_floor = false
	_jump_held = jump
	player.move_and_slide()
	if not player.is_on_floor() and player.velocity.y < 2.0 and not attacking and regrab_t <= 0.0 and carrying == "":
		_try_ledge_grab(dir)
		if ledge_state != "":
			_update_camera(delta)
			return
	_update_attack(delta)
	if player_anim and not attacking and cinematic == 0:
		var state := "idle"
		if not player.is_on_floor():
			state = "hover" if player.velocity.y > -HOVER_FALL - 0.1 and player.velocity.y <= 0.0 and jump else "jump"
		elif dir.length() > 0.1:
			state = "walk" if walking else "run"
		idle_time = idle_time + delta if state == "idle" else 0.0
		if state == "idle" and idle_time > 8.0:
			state = "bored"
		_play_anim(state)
	if dir.length() > 0.1 and (not attacking or not player.is_on_floor()):
		player.get_node("Look").rotation.y = lerp_angle(player.get_node("Look").rotation.y, atan2(-dir.x, -dir.z) - player.rotation.y, 0.25)
	_update_camera(delta)
	if player.position.y < respawn.y - 60.0:   # fell out of the level
		_hurt(99)
	_check_touches(delta)
	_update_hud()

var _jump_held := false
var _jump_held_from_floor := false
var wedge_t := 0.0


# --- swimming --------------------------------------------------------------------------------
# Water objects are boxes Conker swims in: at the surface he floats with his head out, Space
# jumps out, C dives; underwater Space swims up and C down, and he runs out of breath after a
# while. Swimming into a bank that's low enough climbs out.

# The water at a point: {top, node} for the Water object it's inside, or {}.
func _water_at(point: Vector3) -> Dictionary:
	for uid in objects:
		var o: Dictionary = objects[uid]
		if o.obj.type != "water":
			continue
		var node: Node3D = o.node
		var size := Visuals.vec3(o.obj.props.get("size"), Vector3(8, 3, 8))
		var local := node.global_transform.affine_inverse() * point
		if absf(local.x) <= size.x / 2.0 and absf(local.z) <= size.z / 2.0 and local.y >= -0.05 and local.y <= size.y:
			return {"top": (node.global_transform * Vector3(0, size.y, 0)).y, "node": node}
	return {}


# Starts or stops swimming as Conker goes in and out of water. True while he's swimming.
func _update_water() -> bool:
	var sink := float(SWIM.get("surface_sink", 0.25))
	var probe := player.position + Vector3(0, 0.1 if swim_state != "" else 0.6, 0)   # his middle once in
	var water := _water_at(probe)
	if water.is_empty():
		if swim_state != "":
			swim_state = ""
		return false
	swim_top = float(water.top)
	if swim_state == "":
		swim_state = "surface"
		air = float(SWIM.get("air_time", 12.0))
		drown_t = 0.0
		_splash(Vector3(player.position.x, swim_top, player.position.z), clampf(-player.velocity.y / 12.0, 0.3, 1.0))
		# Falling in fast takes him under for a moment.
		if player.velocity.y < -9.0:
			swim_state = "under"
			player.position.y = minf(player.position.y, swim_top - sink - 0.6)
		player.velocity.y = maxf(player.velocity.y * 0.2, -2.0)
		hover_left = 0.0
		attacking = false
		if pan:
			pan.visible = false
	return true


func _swim(delta: float, dir: Vector3, walking: bool) -> void:
	var sink := float(SWIM.get("surface_sink", 0.25))
	var surface_y := swim_top - sink
	var jump := Input.is_key_pressed(KEY_SPACE) and not busy
	var dive := (Input.is_key_pressed(KEY_C) or Input.is_key_pressed(KEY_CTRL)) and not busy
	var speed := float(SWIM.get("surface_speed", 4.0)) if swim_state == "surface" else float(SWIM.get("dive_speed", 3.5))
	if walking:
		speed *= 0.5
	# B swims: underwater (as in the game) it strokes him along the way he faces.
	var stroke := swim_state == "under" and not busy and Input.is_key_pressed(KEY_B)
	if stroke and dir.length() < 0.1:
		dir = -(player.get_node("Look") as Node3D).global_transform.basis.z
		dir.y = 0
		dir = dir.normalized()
	player.velocity.x = dir.x * speed
	player.velocity.z = dir.z * speed
	if swim_state == "surface":
		if jump and not _jump_held:   # out of the water
			swim_state = ""
			player.velocity.y = float(SWIM.get("jump_out", 9.0))
			_jump_held = true
			_jump_held_from_floor = true   # no hover from the same press
			_splash(Vector3(player.position.x, swim_top, player.position.z), 0.4)
			player.move_and_slide()
			_play_anim("jump")
			_update_camera(delta)
			_check_touches(delta)
			_update_hud()
			return
		if dive and not _dive_held:
			swim_state = "under"
			player.velocity.y = -float(SWIM.get("dive_speed", 3.5))
		else:
			player.velocity.y = (surface_y - player.position.y) * 8.0   # bob at the surface
		air = minf(float(SWIM.get("air_time", 12.0)), air + delta * 6.0)
		drown_t = 0.0
	else:
		if jump:
			player.velocity.y = float(SWIM.get("rise_speed", 3.0))
		elif dive:
			player.velocity.y = -float(SWIM.get("dive_speed", 3.5))
		else:
			player.velocity.y = lerpf(player.velocity.y, 1.6, 1.0 - pow(0.02, delta))   # floats back up
		if player.position.y >= surface_y - 0.05 and not dive and player.velocity.y >= 0.0:
			swim_state = "surface"
			player.velocity.y = 0.0
		air -= delta
		if air <= 0.0:
			drown_t -= delta
			if drown_t <= 0.0:
				drown_t = float(SWIM.get("drown_every", 2.0))
				_hurt(1)
	_jump_held = jump
	_dive_held = dive
	player.move_and_slide()
	if swim_state == "under" and player.position.y > surface_y:
		player.position.y = surface_y
	if swim_state == "surface" and dir.length() > 0.1 and player.is_on_wall() and _try_climb_out(dir):
		_update_camera(delta)
		return
	if player_anim and cinematic == 0:
		var moving := dir.length() > 0.1
		var state := ("dive" if moving or absf(player.velocity.y) > 1.0 else "dive_idle") if swim_state == "under" \
				else ("swim" if moving else "swim_idle")
		_play_anim(state)
	idle_time = 0.0
	if dir.length() > 0.1:
		var look := player.get_node("Look") as Node3D
		look.rotation.y = lerp_angle(look.rotation.y, atan2(-dir.x, -dir.z) - player.rotation.y, 0.2)
	_update_camera(delta)
	_check_touches(delta)
	_update_hud()


# Swimming at a bank no higher than "climb_out" above the water: he climbs up onto it.
func _try_climb_out(dir: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var from := player.position + Vector3(0, 0.3, 0)
	var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * 0.9, 1, [player.get_rid()]))
	if wall.is_empty() or absf((wall.normal as Vector3).y) > 0.5:
		return false
	var n: Vector3 = wall.normal
	n.y = 0
	n = n.normalized()
	if n.dot(dir) > 0.0:   # a back-facing triangle: its normal points into the bank
		n = -n
	var over: Vector3 = (wall.position as Vector3) - n * 0.3
	var highest := swim_top + float(SWIM.get("climb_out", 1.3))
	var top := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(over.x, highest + 0.2, over.z), Vector3(over.x, swim_top - 0.4, over.z), 1, [player.get_rid()]))
	if top.is_empty() or (top.normal as Vector3).y < 0.75:
		return false
	var y: float = (top.position as Vector3).y
	var room := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(over.x, y + 0.1, over.z), Vector3(over.x, y + 1.5, over.z), 1, [player.get_rid()]))
	if not room.is_empty():
		return false
	swim_state = ""
	ledge_state = "climb"
	ledge_t = 0.0
	ledge_top = Vector3(over.x, y, over.z)
	ledge_normal = n
	ledge_from = player.position
	player.velocity = Vector3.ZERO
	var look := player.get_node("Look") as Node3D
	look.rotation.y = atan2(n.x, n.z) - player.rotation.y   # facing the bank
	ledge_body = null
	_play_anim("climb")
	return true


# A splash where Conker hits the water (strength 0..1).
func _splash(at: Vector3, strength: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = int(20 + 40 * strength)
	p.lifetime = 0.8
	p.explosiveness = 0.95
	p.direction = Vector3.UP
	p.spread = 35.0
	p.initial_velocity_min = 2.0 * strength + 1.0
	p.initial_velocity_max = 5.0 * strength + 2.0
	p.gravity = Vector3(0, -12, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.3
	var drop := SphereMesh.new()
	drop.radius = 0.05
	drop.height = 0.1
	drop.radial_segments = 6
	drop.rings = 3
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.93, 1.0, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.1
	drop.material = m
	p.mesh = drop
	add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)


# --- ledge grab ------------------------------------------------------------------------------
# Jump at a ledge a bit above head height and Conker catches it and hangs. Space or forward
# climbs up, back (S) lets go. Heights are in catalog/objects.json ("player" -> "ledge").

var ledge_state := ""        # "", "hang" or "climb"
var ledge_top := Vector3.ZERO
var ledge_normal := Vector3.ZERO
var ledge_t := 0.0
var regrab_t := 0.0
var _ledge_ready := false
var ledge_from := Vector3.INF  # where a climb starts, when it isn't from hanging (climbing out of water)
var ledge_body: Node3D = null   # what he's hanging from, so he moves with it (a moving platform)
var ledge_body_at := Vector3.ZERO
var LEDGE: Dictionary = App.catalog.get("player", {}).get("ledge", {})
var ANIM_TURNS: Dictionary = App.catalog.get("player", {}).get("animation_turns", {})


func _try_ledge_grab(dir: Vector3) -> void:
	var look := player.get_node("Look") as Node3D
	var facing := -look.global_transform.basis.z
	facing.y = 0
	if dir.length() > 0.1:
		facing = dir.normalized()   # grab what he's heading for
	var space := get_world_3d().direct_space_state
	var reach := float(LEDGE.get("reach", 2.1))   # highest a ledge can be above his feet
	var lowest := float(LEDGE.get("lowest", 1.1))  # lower than this he just lands on it
	var chest := player.position + Vector3(0, lowest, 0)
	var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(chest, chest + facing * 0.75, 1, [player.get_rid()]))
	if wall.is_empty() or absf((wall.normal as Vector3).y) > 0.5:
		return
	var n: Vector3 = wall.normal
	n.y = 0
	n = n.normalized()
	if n.dot(facing) > 0.0:   # a back-facing triangle (ROM scenes have some): its normal points into the wall
		n = -n
	var over: Vector3 = (wall.position as Vector3) - n * 0.25
	var top := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(over.x, player.position.y + reach + 0.4, over.z), Vector3(over.x, player.position.y + lowest - 0.1, over.z), 1, [player.get_rid()]))
	if top.is_empty() or (top.normal as Vector3).y < 0.75:
		return
	var y: float = (top.position as Vector3).y
	# Room to stand up there?
	var room := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(over.x, y + 0.1, over.z), Vector3(over.x, y + 1.5, over.z), 1, [player.get_rid()]))
	if not room.is_empty():
		return
	ledge_state = "hang"
	_ledge_ready = false
	ledge_body = _moving_root(top.collider as Node3D)
	ledge_body_at = ledge_body.global_position if ledge_body else Vector3.ZERO
	ledge_top = Vector3(over.x, y, over.z)
	ledge_normal = n
	player.velocity = Vector3.ZERO
	player.position = Vector3(wall.position.x, y - float(LEDGE.get("hang_drop", 1.62)), wall.position.z) + n * float(LEDGE.get("hang_out", 0.18))
	look.rotation.y = atan2(n.x, n.z) - player.rotation.y   # facing the wall (n points out of it)
	if pan:
		pan.visible = false
	_play_anim("hang")


# The placed object a collider belongs to (it's what _move_platforms moves), else the collider.
func _moving_root(n: Node3D) -> Node3D:
	var at: Node = n
	while at != null and at != self:
		for uid in objects:
			if objects[uid].node == at:
				return at as Node3D
		at = at.get_parent()
	return n


func _update_ledge(delta: float) -> void:
	player.velocity = Vector3.ZERO
	if is_instance_valid(ledge_body):   # carried along by what he's holding on to
		var moved := ledge_body.global_position - ledge_body_at
		ledge_body_at = ledge_body.global_position
		ledge_top += moved
		if ledge_state == "hang":   # held where he hangs (the block would otherwise nudge him)
			player.global_position = ledge_top + ledge_normal * float(LEDGE.get("hang_out", 0.18)) \
					- Vector3(0, float(LEDGE.get("hang_drop", 1.62)), 0) + ledge_normal * 0.25
		if ledge_from != Vector3.INF:
			ledge_from += moved
	if ledge_state == "hang":
		var up := Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_W)
		if not up:
			_ledge_ready = true   # a fresh press climbs, not the one that jumped him here
		if Input.is_key_pressed(KEY_S):
			ledge_state = ""
			ledge_body = null
			regrab_t = 0.5
			player.position += ledge_normal * 0.2
			return
		if up and _ledge_ready:
			ledge_state = "climb"
			ledge_t = 0.0
			_play_anim("climb")
		_jump_held = Input.is_key_pressed(KEY_SPACE)
		return
	# Climbing: up the wall, then onto the top.
	ledge_t += delta
	var length := float(LEDGE.get("climb_time", 0.9))
	var k := clampf(ledge_t / length, 0.0, 1.0)
	var start := ledge_top + ledge_normal * (0.25 + float(LEDGE.get("hang_out", 0.18))) - Vector3(0, float(LEDGE.get("hang_drop", 1.62)), 0)
	if ledge_from != Vector3.INF:
		start = ledge_from
	var lift := start.lerp(Vector3(start.x, ledge_top.y + 0.05, start.z), minf(1.0, k / 0.6))
	var onto := Vector3(ledge_top.x, ledge_top.y + 0.05, ledge_top.z) - ledge_normal * 0.35
	player.position = lift.lerp(onto, clampf((k - 0.6) / 0.4, 0.0, 1.0))
	if k >= 1.0:
		ledge_state = ""
		ledge_from = Vector3.INF
		ledge_body = null
		regrab_t = 0.4
		_jump_held = Input.is_key_pressed(KEY_SPACE)
		_jump_held_from_floor = _jump_held


# The follow camera: behind and above Conker at the wheel's distance. When a wall or the
# ground is between Conker and where the camera wants to be, it comes in quickly and goes
# back out slowly, as the recomp's own camera does.
func _update_camera(delta: float) -> void:
	if cut_camera:   # a cutscene has it
		underwater_tint.visible = not _water_at(camera.global_position).is_empty()
		return
	var look := player.position + Vector3(0, CAM_LOOK_HEIGHT, 0)
	var back := CAM_FAR * cam_zoom
	var offset := Basis(Vector3.UP, cam_yaw) * (Basis(Vector3.RIGHT, -cam_pitch) * Vector3(0, back.y, back.x))
	var wanted := 1.0
	var query := PhysicsRayQueryParameters3D.create(look, look + offset, 1, [player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		wanted = max(0.08, (look.distance_to(hit.position) - CAM_WALL_MARGIN) / offset.length())
	var rate := 0.5 if wanted < cam_arm else 0.05
	cam_arm = lerpf(cam_arm, wanted, 1.0 - pow(1.0 - rate, delta * 60.0))
	var eye := look + offset * cam_arm
	camera.position = camera.position.lerp(eye, 1.0 - pow(0.85, delta * 60.0))
	if camera.position.distance_to(look) > 0.05:
		camera.look_at(look)
	underwater_tint.visible = not _water_at(camera.position).is_empty()


# --- the frying pan --------------------------------------------------------------------------

func _attack() -> void:
	if attacking or busy or player == null or ledge_state != "" or swim_state != "" or carrying != "":
		return
	attacking = true
	attack_t = 0.0
	attack_hit_done = false
	idle_time = 0.0
	if player_anim:
		var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get("attack", ""))
		if anim != "":
			player_anim.play(anim, 0.08)
			player_anim.speed_scale = 1.0
			_anim_now = "attack"


func _update_attack(delta: float) -> void:
	if not attacking:
		return
	attack_t += delta
	var length := 0.8
	if player_anim and _anim_now == "attack" and player_anim.current_animation != "":
		length = player_anim.current_animation_length
	if pan:
		pan.visible = attack_t >= float(PAN.get("shown_from", 0.17)) and attack_t <= float(PAN.get("shown_until", 1.0))
	if not attack_hit_done and attack_t >= float(PAN.get("hit_at", 0.35)):
		attack_hit_done = true
		var facing: Vector3 = -(player.get_node("Look") as Node3D).global_transform.basis.z
		for uid in objects:
			var o: Dictionary = objects[uid]
			if o.obj.type != "enemy" or hidden.has(uid) or o.get("dead", false):
				continue
			var to: Vector3 = o.node.position - player.position
			var rise := absf(to.y)
			to.y = 0
			if rise < 1.6 and to.length() < 2.2 and (to.length() < 0.6 or facing.normalized().dot(to.normalized()) > 0.2):
				_hit_enemy(uid, o, to.normalized())
	if attack_t >= length:
		attacking = false
		if pan:
			pan.visible = false
		_anim_now = ""


func _hit_enemy(uid: String, o: Dictionary, away: Vector3) -> void:
	if o.get("dead", false):
		return
	o.hits = int(o.get("hits", 0)) + 1
	o.knock = away * 9.0
	o.attacking = false
	var chest: Vector3 = (o.node as Node3D).global_position + Vector3(0, 1.0, 0)
	var dying: bool = o.hits >= int(o.obj.props.get("health", 1))
	Blood.burst(self, chest, away, 90 if dying else 45)
	# Splats on the screen: always for a kill right by the camera, now and then for a hit.
	var near_camera := chest.distance_to(camera.global_position)
	if (dying and near_camera < 5.0) or (not dying and near_camera < 3.5 and randf() < 0.3):
		Blood.screen(splat_layer, 2 if dying else 1)
	if dying:
		_kill_enemy(uid, o)
		return
	var hurt_len := _enemy_anim(o, "hurt")
	o.stun = clampf(hurt_len, 0.35, 0.9) if hurt_len > 0.0 else 0.6


func _kill_enemy(uid: String, o: Dictionary) -> void:
	o.dead = true
	o.dead_t = 0.0
	o.stun = 0.4
	var body := o.node as CollisionObject3D
	body.collision_layer = 0          # Conker walks over the body; it still lies on the floor
	Blood.pool(self, (o.node as Node3D).global_position)
	if _enemy_anim(o, "die") <= 0.0:  # no death animation: topple over
		var look := o.node.get_node_or_null("Look") as Node3D
		if look:
			create_tween().tween_property(look, "rotation:x", -PI / 2.0, 0.45).set_trans(Tween.TRANS_QUAD)
	_run_trigger("defeat", uid)


func _play_music(index: int) -> void:
	if index == music_index and music.playing:
		return
	music_index = index
	music.stop()
	if index <= 0:
		return
	var stream := Rom.music_stream(index)
	if stream:
		music.stream = stream
		music.play()


func _play_anim(state: String) -> void:
	if state == _anim_now:
		return
	var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get(state, ""))
	if anim != "":
		player_anim.play(anim, 0.15)
		var holder := player.get_node("Look").get_meta("model") as Node3D if player.get_node("Look").has_meta("model") else null
		if holder and holder.get_child_count() > 0:   # some animations face the other way in the ROM
			(holder.get_child(0) as Node3D).rotation.y = PI + deg_to_rad(float(ANIM_TURNS.get(state, 0.0)))
		player_anim.speed_scale = HOVER_SPEED if state == "hover" else 1.0
		if state == "climb":   # fit the climb animation to the climb
			player_anim.speed_scale = player_anim.get_animation(anim).length / float(LEDGE.get("climb_time", 0.9))
		_anim_now = state


func _move_platforms(delta: float) -> void:
	for uid in objects:
		var o: Dictionary = objects[uid]
		if o.obj.type != "platform":
			continue
		var move := Visuals.vec3(o.obj.props.get("move"), Vector3.ZERO)
		if move == Vector3.ZERO:
			continue
		o.t += delta
		var period := maxf(0.5, float(o.obj.props.get("period", 4.0)))
		var k := (1.0 - cos(o.t / period * TAU)) / 2.0
		o.node.position = o.home + move * k
		for rider in o.get("riders", []):   # pickups and props placed on it move with it
			objects[rider].node.position = objects[rider].home + move * k


func _check_touches(delta: float) -> void:
	var p := player.position
	var near := ""
	for uid in objects.keys():
		var o: Dictionary = objects[uid]
		if hidden.has(uid) or uid == carrying:
			continue
		var node: Node3D = o.node
		if node.has_meta("spin"):
			node.get_meta("spin").rotation.y += delta * 2.0
		var d := p.distance_to(node.position)
		match o.obj.type:
			"cash", "chocolate", "squirrel_tail":
				if d < 1.2 and not busy:
					_collect(uid, o.obj)
			"checkpoint":
				if d < 1.5:
					respawn = node.position
			"level_exit":
				if d < 1.5 and not busy:
					var target: String = o.obj.props.get("target_level", "")
					if App.levels.has(target):
						start.call_deferred(target, o.obj.props.get("target_spawn", ""))
						return
			"trigger_zone":
				var half := Visuals.vec3(o.obj.props.get("size"), Vector3(4, 3, 4)) / 2.0
				var local := p - node.position
				if absf(local.x) <= half.x and absf(local.z) <= half.z and local.y >= -0.5 and local.y <= half.y * 2.0:
					if not fired.has(uid) or not o.obj.props.get("once", true):
						if not fired.has(uid):
							fired[uid] = true
							_run_trigger("enter_zone", uid)
				else:
					if not o.obj.props.get("once", true):
						fired.erase(uid)
			"carryable":
				if carrying == "" and d < 1.5 and not busy and ledge_state == "" and not o.get("delivered", false):
					_pick_up(uid, o)
			"enemy":
				if cinematic == 0 or o.get("dead", false):   # baddies wait while a cutscene plays
					_enemy_step(uid, o, delta)
				if bool(o.obj.props.get("flying", false)):   # wasps are at chest height
					d = (p + Vector3(0, 1.2, 0)).distance_to(node.position)
				if d < 1.25 and not o.get("dead", false) and not busy:
					if player.velocity.y < -1.0 and p.y > node.position.y + 0.9:
						player.velocity.y = JUMP * 0.7   # bounced on its head
						_hit_enemy(uid, o, (node.position - p).normalized())
					elif str(o.roles.get("attack", "")) == "" and float(o.get("cooldown", 0.0)) <= 0.0 \
							and float(o.get("stun", 0.0)) <= 0.0:
						o.cooldown = 1.2   # no attack animation: it hurts on contact instead
						_knock_player(node.position)
			"npc":
				if d < 2.5:
					near = "Press E to talk to " + str(o.obj.props.get("name", "them"))
			"context_pad":
				if d < 1.5:
					near = str(o.obj.props.get("hint", "Press B"))
	hint.text = near if not busy else ""
	if carrying != "":
		_check_delivery()


# Enemies wander near home (walking), run at Conker when he comes close (but not too far from
# home), stop and attack when he's in reach, flinch when hit and die where they fall.
func _setup_enemy(o: Dictionary) -> void:
	o.roles = {}
	o.anim = null
	var look := o.node.get_node_or_null("Look") as Node3D
	if look == null or not look.has_meta("model"):
		return
	var holder := look.get_meta("model") as Node3D
	var model := holder.get_child(0) if holder.get_child_count() > 0 else null
	if model == null:
		return
	o.anim = Rom.animation_player(model)
	if o.anim == null:
		return
	o.roles = Rom.roles(model)
	for role in ["idle", "walk", "run"]:
		if str(o.roles.get(role, "")) != "":
			(o.anim as AnimationPlayer).get_animation(o.roles[role]).loop_mode = Animation.LOOP_LINEAR
	for role in ["attack", "hurt", "die"]:
		if str(o.roles.get(role, "")) != "":
			(o.anim as AnimationPlayer).get_animation(o.roles[role]).loop_mode = Animation.LOOP_NONE
	_enemy_anim(o, "idle")


# Plays one of the enemy's animations; returns its length (0 if it has none for that).
func _enemy_anim(o: Dictionary, role: String, speed := 1.0) -> float:
	var player_node := o.get("anim") as AnimationPlayer
	if player_node == null:
		return 0.0
	var name := str(o.roles.get(role, ""))
	if name == "" and role == "run":
		name = str(o.roles.get("walk", ""))
		speed *= 1.6
	elif name == "" and role == "walk":
		name = str(o.roles.get("run", ""))
		speed *= 0.6
	if name == "":
		return 0.0
	player_node.speed_scale = speed
	if o.get("anim_now", "") != role or role in ["attack", "hurt"]:
		player_node.play(name, 0.12)
		if role in ["attack", "hurt"]:
			player_node.seek(0.0, true)   # start over even if it was already playing
		o.anim_now = role
	return player_node.get_animation(name).length / speed


func _knock_player(from: Vector3) -> void:
	var away := player.position - from
	away.y = 0
	player.velocity = away.normalized() * 8.0 + Vector3(0, 5, 0)
	knock_t = 0.35
	_hurt(1)


func _enemy_step(uid: String, o: Dictionary, delta: float) -> void:
	var body := o.node as CharacterBody3D
	if body == null:
		return
	var look := body.get_node_or_null("Look") as Node3D
	o.stun = float(o.get("stun", 0.0)) - delta
	o.cooldown = float(o.get("cooldown", 0.0)) - delta
	var v := Vector3.ZERO
	var to_player := player.position - body.position
	to_player.y = 0
	if o.get("dead", false):
		o.dead_t = float(o.dead_t) + delta
		if o.stun > 0.0:
			v = o.get("knock", Vector3.ZERO) * 0.5
		if o.dead_t > 4.0:   # the body stays a while, then it's gone
			_hide(uid)
			return
	elif o.get("attacking", false):
		o.attack_t = float(o.attack_t) + delta
		if look and to_player.length() > 0.1:
			look.rotation.y = lerp_angle(look.rotation.y, atan2(-to_player.x, -to_player.z) - body.rotation.y, 0.2)
		if not o.get("attack_hit", false) and o.attack_t >= float(o.attack_len) * 0.45:
			o.attack_hit = true
			var facing := -look.global_transform.basis.z if look else to_player
			if to_player.length() < 2.0 and absf(player.position.y - body.position.y) < 1.5 \
					and facing.normalized().dot(to_player.normalized()) > 0.3 and not busy:
				_knock_player(body.position)
		if o.attack_t >= float(o.attack_len):
			o.attacking = false
			o.cooldown = 0.9
	elif o.stun > 0.0:
		v = o.get("knock", Vector3.ZERO)
		o.knock = (o.knock as Vector3).lerp(Vector3.ZERO, 0.15)
	else:
		var radius := float(o.obj.props.get("patrol_radius", 4.0))
		var home: Vector3 = o.home
		var target: Vector3 = o.get("wander", home)
		var speed := 1.6
		var wake := str(o.obj.props.get("wakes_when", ""))
		var chasing := to_player.length() < 9.0 and (player.position - home).length() < radius + 12.0 and health > 0
		if wake != "":   # waits for its story flag, then chases Conker anywhere
			chasing = flags.has(wake) and health > 0
			if not flags.has(wake):
				radius = 0.0
		if chasing:
			target = player.position
			speed = 4.2 if not bool(o.obj.props.get("flying", false)) else 4.8
			if to_player.length() < 1.6 and o.cooldown <= 0.0 and str(o.roles.get("attack", "")) != "":
				o.attacking = true
				o.attack_t = 0.0
				o.attack_hit = false
				o.attack_len = maxf(0.3, _enemy_anim(o, "attack"))
		elif body.position.distance_to(target) < 0.5 or float(o.get("wander_t", 0.0)) <= 0.0:
			var angle := randf() * TAU
			o.wander = home + Vector3(cos(angle), 0, sin(angle)) * randf() * max(radius, 0.1)
			o.wander_t = randf_range(2.0, 5.0)
		o.wander_t = float(o.get("wander_t", 0.0)) - delta
		var flat := target - body.position
		flat.y = 0
		if not o.get("attacking", false) and flat.length() > (1.2 if chasing else 0.4) and (radius > 0.0 or chasing):
			v = flat.normalized() * speed
			if look:
				look.rotation.y = lerp_angle(look.rotation.y, atan2(-v.x, -v.z) - body.rotation.y, 0.15)
			_enemy_anim(o, "run" if chasing else "walk")
		elif not o.get("attacking", false):
			_enemy_anim(o, "idle")
	body.velocity.x = v.x
	body.velocity.z = v.z
	if bool(o.obj.props.get("flying", false)) and not o.get("dead", false):
		# Flies: at Conker's chest height while chasing him, otherwise bobbing over home.
		o.t = float(o.get("t", 0.0)) + delta
		var height: float = (o.home as Vector3).y + 1.3 + sin(o.t * 3.0) * 0.15
		var wake_flag := str(o.obj.props.get("wakes_when", ""))
		if (wake_flag == "" or flags.has(wake_flag)) and to_player.length() < 14.0:
			height = player.position.y + 1.3 + sin(o.t * 4.0) * 0.12
		body.velocity.y = (height - body.position.y) * 3.0
	else:
		body.velocity.y = 0.0 if body.is_on_floor() else body.velocity.y - GRAVITY * delta
	body.move_and_slide()


func _interact() -> void:
	var p := player.position
	for uid in objects:
		if hidden.has(uid):
			continue
		var o: Dictionary = objects[uid]
		var d := p.distance_to(o.node.position)
		if o.obj.type == "npc" and d < 2.5:
			_talk(uid, o.obj)
			return
		if o.obj.type == "context_pad" and d < 1.5:
			_run_trigger("press_pad", uid)
			return


# Talking to someone: their own lines, then the "After Conker talks to" events. An event
# with conditions that are met ("only if Conker has 30 cash") takes over the conversation
# instead of their usual lines.
func _talk(uid: String, obj: Dictionary) -> void:
	var takes_over := false
	for event in _events_for("talk_to", uid):
		if not event.get("only_if", []).is_empty():
			takes_over = true
	if not takes_over:
		var lines: Array = obj.props.get("dialogue", [])
		var speaker := str(obj.props.get("name", ""))
		await _run_actions(lines.map(func(l): return {"type": "say", "speaker": speaker, "text": l}))
	_run_trigger("talk_to", uid)


func _collect(uid: String, obj: Dictionary) -> void:
	_hide(uid)
	collected[level_id + "/" + uid] = true
	match obj.type:
		"cash":
			if bool(obj.props.get("grab_cutscene", false)):
				await _cash_grab(int(obj.props.get("amount", 10)))
			else:
				cash += int(obj.props.get("amount", 10))
			var left := false
			for other in objects:
				if objects[other].obj.type == "cash" and (not hidden.has(other) or waiting.has(other)):
					left = true
			if not left:
				_run_trigger("all_cash", "")
		"chocolate":
			health = min(6, health + 2)
		"squirrel_tail":
			lives += 1


func _hide(uid: String) -> void:
	hidden[uid] = true
	objects[uid].node.visible = false
	if objects[uid].node is CollisionObject3D:
		objects[uid].node.process_mode = Node.PROCESS_MODE_DISABLED


func _hurt(amount: int) -> void:
	health -= amount
	flash.color.a = 0.35
	create_tween().tween_property(flash, "color:a", 0.0, 0.4)
	if health <= 0:
		lives -= 1
		health = 6
		if carrying != "":   # what he was carrying goes back where it was
			_drop_carried(objects[carrying].home)
		player.position = respawn + Vector3(0, 0.5, 0)
		player.velocity = Vector3.ZERO
		if lives < 0:
			lives = 3
			cash = 0
			start.call_deferred(App.game.get("start_level", level_id))


func _update_hud() -> void:
	hud.text = "%s    Chocolate %d/6    Tails x%d    $%d" % [level.get("title", ""), max(0, health), max(0, lives), cash]
	if swim_state == "under":
		var full := float(SWIM.get("air_time", 12.0))
		var bars := int(ceil(clampf(air / full, 0.0, 1.0) * 10.0))
		hud.text += "\nAir " + "|".repeat(bars) + ("   (drowning!)" if air <= 0.0 else "")


# --- events ---------------------------------------------------------------------------------

func _run_trigger(type: String, uid: String) -> void:
	for event in _events_for(type, uid):   # conditions are checked before any of them runs
		if event.get("cutscene", false):
			await _play_cutscene(event.get("do", []))
		else:
			await _run_actions(event.get("do", []))


# The events for this trigger whose conditions ("only if") are all met right now.
func _events_for(type: String, uid: String) -> Array:
	var found := []
	for event in level.get("events", []):
		var when: Dictionary = event.get("when", {})
		if when.get("type") == type and (uid == "" or when.get("object") == uid) and _conditions_met(event):
			found.append(event)
	return found


func _conditions_met(event: Dictionary) -> bool:
	for c in event.get("only_if", []):
		match c.get("type"):
			"cash_at_least":
				if cash < int(c.get("amount", 0)):
					return false
			"flag_set":
				if not flags.has(str(c.get("flag", ""))):
					return false
			"flag_not_set":
				if flags.has(str(c.get("flag", ""))):
					return false
	return true


func _run_actions(actions: Array) -> void:
	for action in actions:
		match action.get("type"):
			"say":
				if _skip:
					continue
				busy = true
				var speaker := str(action.get("speaker", ""))
				dialogue_label.text = (speaker + ":  " if speaker != "" else "") + str(action.get("text", ""))
				dialogue.visible = true
				_advance = false
				var waited := 0.0
				while not _advance and waited < 10.0:   # E / B / Enter moves on sooner
					await get_tree().process_frame
					waited += get_process_delta_time()
				dialogue.visible = false
				busy = cinematic > 0
			"give_cash":
				cash += int(action.get("amount", 0))
			"take_cash":
				cash = max(0, cash - int(action.get("amount", 0)))
			"show":
				var uid := str(action.get("object", ""))
				if objects.has(uid):
					hidden.erase(uid)
					waiting.erase(uid)
					objects[uid].node.visible = objects[uid].obj.type not in ["trigger_zone", "player_start", "spawn_point", "camera", "spot"]
					objects[uid].node.process_mode = Node.PROCESS_MODE_INHERIT
			"hide":
				var uid := str(action.get("object", ""))
				if objects.has(uid):
					_hide(uid)
			"set_flag":
				flags[str(action.get("flag", ""))] = true
				_reveal_rewards()
			"goto_level":
				var target := str(action.get("level", ""))
				if App.levels.has(target):
					start.call_deferred(target, str(action.get("spawn", "")))
					return
			"wait":
				await _cine_wait(float(action.get("seconds", 1.0)))
			"camera":
				await _cut_to(str(action.get("camera", "")), float(action.get("seconds", 0.0)))
			"camera_back":
				cut_camera = false
			"move":
				await _move_to(str(action.get("object", "")), str(action.get("to", "")), float(action.get("seconds", 1.5)))
			"face":
				_face(str(action.get("object", "")), _where(str(action.get("target", ""))))
			"animate":
				_animate(str(action.get("object", "")), str(action.get("animation", "idle")))
			"shoot":
				await _shoot(str(action.get("object", "")), str(action.get("target", "")))
			"defeat":
				var uid := str(action.get("object", ""))
				if objects.has(uid) and objects[uid].obj.type == "enemy" and not objects[uid].get("dead", false):
					var chest: Vector3 = (objects[uid].node as Node3D).global_position + Vector3(0, 0.6, 0)
					Blood.burst(self, chest, Vector3.UP, 60)
					_kill_enemy(uid, objects[uid])
			"play_music":
				_play_music(int(action.get("track", 0)))


# --- cutscenes ------------------------------------------------------------------------------
# An event ticked "Cutscene" plays with black bars while Conker waits. Its camera actions cut
# (or glide) to Camera objects; at the end the follow camera comes back. Tab skips the rest:
# waits and lines are passed over and moves jump to where they end.

func _play_cutscene(actions: Array) -> void:
	_begin_cinematic()
	await _run_actions(actions)
	_end_cinematic()


func _begin_cinematic() -> void:
	if cinematic == 0:
		_skip = false
		_bars(true)
	cinematic += 1
	busy = true
	attacking = false
	if pan:
		pan.visible = false
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	if player_anim:
		_animate("conker", "idle")


func _end_cinematic() -> void:
	cinematic = max(0, cinematic - 1)
	if cinematic == 0:
		cut_camera = false
		camera.fov = 65.0
		busy = false
		_skip = false
		_bars(false)
		_anim_now = ""


func _bars(on: bool) -> void:
	var h := get_viewport().get_visible_rect().size.y * 0.11 if on else 0.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(bars[0], "offset_bottom", h, 0.35)
	tween.tween_property(bars[1], "offset_top", -h, 0.35)
	tween.tween_property(dialogue, "offset_top", -130.0 - h, 0.35)   # lines stay above the bar
	tween.tween_property(dialogue, "offset_bottom", -20.0 - h, 0.35)
	hud.visible = not on


# A stinger (or whatever it is) flies from someone to an enemy and finishes it.
func _shoot(from: String, target: String) -> void:
	if not objects.has(target):
		return
	var o: Dictionary = objects[target]
	var start := _where(from) + Vector3(0, 1.0, 0)
	var goal := (o.node as Node3D).global_position + Vector3(0, 0.5, 0)
	var dart := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.05
	cone.height = 0.35
	dart.mesh = cone
	dart.material_override = Visuals.material(Color("2b1d0e"))
	add_child(dart)
	dart.global_position = start
	if start.distance_to(goal) > 0.01:
		dart.look_at(goal, Vector3.UP if absf((goal - start).normalized().y) < 0.99 else Vector3.RIGHT)
		dart.rotate_object_local(Vector3.RIGHT, -PI / 2.0)   # the cone's tip points along -Z
	var time := clampf(start.distance_to(goal) / 30.0, 0.12, 0.8)
	if not _skip:
		var tween := create_tween()
		tween.tween_property(dart, "global_position", goal, time)
		await tween.finished
	dart.queue_free()
	if o.obj.type == "enemy" and not o.get("dead", false):
		Blood.burst(self, goal, (goal - start).normalized(), 60)
		_kill_enemy(target, o)


# Waits, unless the cutscene is being skipped.
func _cine_wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds and not _skip:
		await get_tree().process_frame
		t += get_process_delta_time()


# Where someone is ("conker" or an object's uid).
func _where(uid: String) -> Vector3:
	if uid == "conker":
		return player.global_position
	if objects.has(uid):
		return (objects[uid].node as Node3D).global_position
	return player.global_position


func _who(uid: String) -> Node3D:
	if uid == "conker":
		return player
	return objects[uid].node if objects.has(uid) else null


# A Camera object's view: from its position plus its height, looking the way it's turned and tilted.
func _cut_to(uid: String, seconds: float) -> void:
	if not objects.has(uid):
		return
	var o: Dictionary = objects[uid]
	var node: Node3D = o.node
	var view := Transform3D(node.global_basis.orthonormalized(),
			node.global_position + Vector3(0, float(o.obj.props.get("height", 1.6)), 0))
	var fov := float(o.obj.props.get("fov", 55.0))
	cut_camera = true
	if seconds <= 0.0 or _skip:
		camera.global_transform = view
		camera.fov = fov
		return
	var tween := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(camera, "global_transform", view, seconds)
	tween.tween_property(camera, "fov", fov, seconds)
	while tween.is_running():
		if _skip:
			tween.kill()
			camera.global_transform = view
			camera.fov = fov
			return
		await get_tree().process_frame


# Walks someone over to a spot (or another object, or Conker) in the given time.
func _move_to(uid: String, to: String, seconds: float) -> void:
	var node := _who(uid)
	if node == null or (to != "conker" and not objects.has(to)):
		return
	var goal := _where(to)
	_face(uid, goal)
	var pace := node.global_position.distance_to(goal) / maxf(seconds, 0.01)
	_animate(uid, "walk" if pace < 4.0 else "run")
	if seconds > 0.0 and not _skip:
		var tween := create_tween()
		tween.tween_property(node, "global_position", goal, seconds)
		while tween.is_running():
			if _skip:
				tween.kill()
				break
			await get_tree().process_frame
	node.global_position = goal
	if uid != "conker" and objects.has(uid):
		objects[uid].home = goal   # it stays (and wanders) where it was taken
	_animate(uid, "idle")


# Turns someone to face a point.
func _face(uid: String, point: Vector3) -> void:
	var node := _who(uid)
	if node == null:
		return
	var look := node.get_node_or_null("Look") as Node3D
	if look == null:
		look = node
	var to := point - node.global_position
	to.y = 0
	if to.length() > 0.01:
		look.rotation.y = atan2(-to.x, -to.z) - (node.rotation.y if look != node else 0.0)


# Plays an animation on someone: a role (idle, walk, run, attack, hurt, die), or for Conker any
# name in player.animations or a ROM pair like "pair_0037_".
func _animate(uid: String, animation: String) -> void:
	if uid == "conker":
		if player_anim == null:
			return
		var key := animation
		if key in ["walk", "run"] and swim_state != "":
			key = "swim"
		elif key == "idle" and swim_state != "":
			key = "swim_idle"
		var found := Rom.find_animation(player_anim, str(PLAYER_ANIMS.get(key, key)))
		if found != "":
			player_anim.play(found, 0.15)
			player_anim.speed_scale = 1.0
			_anim_now = key
		return
	if not objects.has(uid):
		return
	var o: Dictionary = objects[uid]
	if not o.has("roles"):
		_setup_enemy(o)
	if _enemy_anim(o, animation) <= 0.0 and o.get("anim") != null:
		var found := Rom.find_animation(o.anim, animation)   # not a role: a name or pair
		if found != "":
			(o.anim as AnimationPlayer).play(found, 0.12)
			o.anim_now = animation


# --- carried items ------------------------------------------------------------------------------

func _pick_up(uid: String, o: Dictionary) -> void:
	carrying = uid
	var node: Node3D = o.node
	node.get_parent().remove_child(node)
	player.add_child(node)
	node.position = Vector3(0, 1.75, 0)
	node.rotation = Vector3.ZERO
	attacking = false
	if pan:
		pan.visible = false
	_run_trigger("pick_up", uid)


func _drop_carried(at: Vector3) -> void:
	var node: Node3D = objects[carrying].node
	player.remove_child(node)
	add_child(node)
	node.global_position = at
	node.rotation = Vector3.ZERO
	carrying = ""


# Taking a carried item close to where it's delivered.
func _check_delivery() -> void:
	var o: Dictionary = objects[carrying]
	var target := str(o.obj.props.get("deliver_to", ""))
	if target == "" or not objects.has(target) or hidden.has(target) or busy:
		return
	var there: Vector3 = (objects[target].node as Node3D).global_position
	var flat := there - player.global_position
	flat.y = 0
	if flat.length() > 2.6:
		return
	var uid := carrying
	_drop_carried(there - flat.normalized() * 1.0 if flat.length() > 0.01 else there)
	o.delivered = true
	o.home = (o.node as Node3D).global_position
	_run_trigger("deliver", uid)


# --- quest rewards ----------------------------------------------------------------------------

# Cash waiting for a story flag appears (with a sparkle) once it's set.
func _reveal_rewards() -> void:
	for uid in waiting.keys():
		if not flags.has(waiting[uid]):
			continue
		waiting.erase(uid)
		hidden.erase(uid)
		var node: Node3D = objects[uid].node
		node.visible = true
		node.process_mode = Node.PROCESS_MODE_INHERIT
		_sparkle(node.global_position + Vector3(0, 0.6, 0))


func _sparkle(at: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 40
	p.lifetime = 1.0
	p.explosiveness = 0.8
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 3.0
	p.gravity = Vector3(0, -2, 0)
	var star := SphereMesh.new()
	star.radius = 0.04
	star.height = 0.08
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.9, 0.3)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.2)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	star.material = m
	p.mesh = star
	add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(2.0).timeout.connect(p.queue_free)


# A wad grabbed in a short cutscene: the camera comes round to Conker's face, his eyes turn to
# dollar signs, and the amount floats up.
func _cash_grab(amount: int) -> void:
	cash += amount
	if cinematic > 0 or player == null:
		return
	_begin_cinematic()
	var look := player.get_node("Look") as Node3D
	var face := -look.global_transform.basis.z
	face.y = 0
	face = face.normalized() if face.length() > 0.01 else Vector3.FORWARD
	var head := player.global_position + Vector3(0, 1.15, 0)
	cut_camera = true
	camera.fov = 45.0
	camera.global_position = head + face * 1.8 + Vector3(0, 0.1, 0)
	camera.look_at(head)
	_animate("conker", "cash_grab" if PLAYER_ANIMS.has("cash_grab") else "idle")
	_dollar_eyes(true)
	var tag := Label3D.new()
	tag.text = "$%d" % amount
	tag.font_size = 96
	tag.pixel_size = 0.0028
	tag.outline_size = 16
	tag.modulate = Color(0.55, 1.0, 0.45)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	add_child(tag)
	tag.global_position = head + Vector3(0, 0.5, 0)
	create_tween().tween_property(tag, "global_position", head + Vector3(0, 0.75, 0), 1.6)
	await _cine_wait(1.8)
	tag.queue_free()
	_dollar_eyes(false)
	_end_cinematic()


# Swaps Conker's pupils (the textures the game streams into segments 10 and 11) for dollar signs.
func _dollar_eyes(on: bool) -> void:
	for swap in _eye_swaps:
		if is_instance_valid(swap[0]):
			(swap[0] as MeshInstance3D).set_surface_override_material(swap[1], null)
	_eye_swaps.clear()
	if not on or player == null:
		return
	# Which way each eye's pupil texture is laid on decides whether its dollar is drawn mirrored:
	# the eye laid on the other way round from segment 10's (his left eye) gets a mirrored one.
	var eyes := []   # [mesh instance, surface, material, handedness]
	for mi in player.get_node("Look").find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var mat := (mi as MeshInstance3D).get_active_material(i) as BaseMaterial3D
			if mat == null or mat.albedo_texture == null:
				continue
			if not (mat.resource_name.begins_with("segment_10_000000") or mat.resource_name.begins_with("segment_11_000000")):
				continue
			eyes.append([mi, i, mat, _uv_handedness(mi, i, mat)])
	var reference := 0.0
	for e in eyes:
		if (e[2] as BaseMaterial3D).resource_name.begins_with("segment_10") and e[3] != 0.0:
			reference = e[3]
	for e in eyes:
		var mat: BaseMaterial3D = e[2]
		var mirrored: bool = e[3] != reference if reference != 0.0 and e[3] != 0.0 \
				else mat.resource_name.begins_with("segment_11")
		var dollar := mat.duplicate() as BaseMaterial3D
		dollar.albedo_texture = _dollar_texture(mirrored)
		(e[0] as MeshInstance3D).set_surface_override_material(e[1], dollar)
		_eye_swaps.append([e[0], e[1]])


# +1 or -1: whether a surface's texture is laid on as drawn or mirrored, as seen from outside
# (its UVs' winding against its triangles', with the node's and material's own flips). 0 unknown.
static func _uv_handedness(mi: MeshInstance3D, surface: int, mat: BaseMaterial3D) -> float:
	var arrays := mi.mesh.surface_get_arrays(surface)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var index = arrays[Mesh.ARRAY_INDEX]
	if uvs == null or verts.is_empty():
		return 0.0
	var order: PackedInt32Array = index if index != null and index.size() > 0 else PackedInt32Array(range(verts.size()))
	var total := 0.0
	for t in range(0, order.size() - 2, 3):
		var a := order[t]
		var b := order[t + 1]
		var c := order[t + 2]
		var n := (verts[b] - verts[a]).cross(verts[c] - verts[a])
		if normals != null and normals.size() == verts.size():
			n = n * signf(n.dot(normals[a] + normals[b] + normals[c]))   # facing out
		var area := n.length()
		var du1: Vector2 = uvs[b] - uvs[a]
		var du2: Vector2 = uvs[c] - uvs[a]
		var uv_area := du1.x * du2.y - du1.y * du2.x
		total += signf(uv_area) * area
	if is_zero_approx(total):
		return 0.0
	var flip := signf(mi.global_basis.determinant()) * signf(mat.uv1_scale.x * mat.uv1_scale.y)
	return signf(total) * flip


# A dollar sign drawn over the white of the eye, the size of the game's pupil texture.
static func _dollar_texture(mirrored: bool) -> ImageTexture:
	if _dollar_eyes_textures.has(mirrored):
		return _dollar_eyes_textures[mirrored]
	var glyph := [
		"...##...",
		".######.",
		"##.##.##",
		"##.##...",
		".#####..",
		"..#####.",
		"...##.##",
		"##.##.##",
		".######.",
		"...##...",
	]
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var ink := Color(0.05, 0.45, 0.12)
	for y in glyph.size():
		for x in glyph[y].length():
			if glyph[y][x] != "#":
				continue
			for dy in 2:   # 2 x 2 pixels a cell: 16 x 20, centred
				for dx in 2:
					var px: int = 8 + x * 2 + dx
					img.set_pixel(31 - px if mirrored else px, 6 + y * 2 + dy, ink)
	_dollar_eyes_textures[mirrored] = ImageTexture.create_from_image(img)
	return _dollar_eyes_textures[mirrored]
