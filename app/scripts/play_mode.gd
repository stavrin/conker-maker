# Quick playtest inside Conker Maker: walk around your levels with a stand-in Conker, collect
# things, talk to characters and run your events. It's for checking layouts and logic fast;
# "Playtest in recomp" runs the real game.
#
#   WASD move (Shift: walk)   Space jump (hold in the air to hover with the tail)
#   F or left click: frying pan (on the ground or in the air)   E / B interact   Esc back to the editor
#   Camera: the mouse turns it (the pointer is hidden while you play), arrow keys too, the
#   wheel zooms; it pulls in near walls, like the recomp's camera
#   (CBFD-Recompiled host/src/mouse_camera.cpp).
#
# Enemies walk, run at Conker, attack him up close, flinch when hit and die with their own
# ROM animations (anim_roles.gd picks which is which), and bleed like they do in Bad Fur Day:
# a spray, a pool on the floor, and splats on the screen when it happens near the camera.
extends Node3D

signal finished

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
		if obj.type == "trigger_zone":
			node.visible = false
		if obj.type in ["player_start", "spawn_point"]:
			node.visible = false
		for tag in node.find_children("Tag", "Label3D", true, false):   # name tags are for editing
			tag.visible = false
		add_child(node)
		objects[obj.uid] = {"obj": obj, "node": node, "home": node.position, "t": 0.0}
		if obj.type == "enemy":
			_setup_enemy(objects[obj.uid])
		if obj.type == "player_start" and spawn == "":
			start_pos = node.position
			start_turn = node.rotation.y
		if obj.type == "spawn_point" and spawn != "" and (obj.props.get("name") == spawn or obj.uid == spawn):
			start_pos = node.position
			start_turn = node.rotation.y
	_make_player(start_pos, start_turn)
	respawn = start_pos
	_play_music(int(level.get("music", {}).get("rom_track", 0)))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hud()
	_run_trigger("level_start", "")


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
		for key in ["idle", "bored", "walk", "run", "jump", "hover"]:
			var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get(key, ""))
			if anim != "":
				player_anim.get_animation(anim).loop_mode = Animation.LOOP_LINEAR
		var attack := Rom.find_animation(player_anim, PLAYER_ANIMS.get("attack", ""))
		if attack != "":
			player_anim.get_animation(attack).loop_mode = Animation.LOOP_NONE
		_play_anim("idle")
		_attach_pan(look)
		for child in look.get_children():   # the editor's facing marker isn't needed on the real model
			if child is MeshInstance3D and child.name != "Selection":
				child.visible = false
	player.position = pos + Vector3(0, 0.1, 0)
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
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			finished.emit()
		elif event.keycode == KEY_F:
			_attack()
		elif event.keycode in [KEY_E, KEY_B, KEY_ENTER]:
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
	var input := Vector2.ZERO
	if not busy and knock_t <= 0.0:
		input.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
		input.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var dir := (Basis(Vector3.UP, cam_yaw) * Vector3(input.x, 0, input.y))
	if dir.length() > 1:
		dir = dir.normalized()
	var walking := Input.is_key_pressed(KEY_SHIFT)
	var speed := (WALK_SPEED if walking else SPEED) * (0.15 if attacking and player.is_on_floor() else 1.0)
	if knock_t <= 0.0:
		player.velocity.x = dir.x * speed
		player.velocity.z = dir.z * speed
	var jump := Input.is_key_pressed(KEY_SPACE) and not busy
	if player.is_on_floor():
		hover_left = HOVER_TIME
		if jump and not _jump_held:
			player.velocity.y = JUMP
	else:
		player.velocity.y -= GRAVITY * delta
		if jump and not _jump_held_from_floor and player.velocity.y < 0 and hover_left > 0:
			player.velocity.y = max(player.velocity.y, -HOVER_FALL)   # the tail helicopter
			hover_left -= delta
	if player.is_on_floor():
		_jump_held_from_floor = jump
	elif not jump:
		_jump_held_from_floor = false
	_jump_held = jump
	player.move_and_slide()
	_update_attack(delta)
	if player_anim and not attacking:
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


# The follow camera: behind and above Conker at the wheel's distance. When a wall or the
# ground is between Conker and where the camera wants to be, it comes in quickly and goes
# back out slowly, as the recomp's own camera does.
func _update_camera(delta: float) -> void:
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


# --- the frying pan --------------------------------------------------------------------------

func _attack() -> void:
	if attacking or busy or player == null:
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
	if chest.distance_to(camera.global_position) < 7.0:
		Blood.screen(splat_layer, 3 if dying else 1)
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
		player_anim.speed_scale = HOVER_SPEED if state == "hover" else 1.0
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


func _check_touches(delta: float) -> void:
	var p := player.position
	var near := ""
	for uid in objects.keys():
		var o: Dictionary = objects[uid]
		if hidden.has(uid):
			continue
		var node: Node3D = o.node
		if node.has_meta("spin"):
			node.get_meta("spin").rotation.y += delta * 2.0
		var d := p.distance_to(node.position)
		match o.obj.type:
			"cash", "chocolate", "squirrel_tail":
				if d < 1.2:
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
			"enemy":
				_enemy_step(uid, o, delta)
				if d < 1.25 and not o.get("dead", false):
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
		var chasing := to_player.length() < 9.0 and (player.position - home).length() < radius + 12.0 and health > 0
		if chasing:
			target = player.position
			speed = 4.2
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
		if not o.get("attacking", false) and flat.length() > (1.2 if chasing else 0.4) and radius > 0.0:
			v = flat.normalized() * speed
			if look:
				look.rotation.y = lerp_angle(look.rotation.y, atan2(-v.x, -v.z) - body.rotation.y, 0.15)
			_enemy_anim(o, "run" if chasing else "walk")
		elif not o.get("attacking", false):
			_enemy_anim(o, "idle")
	body.velocity.x = v.x
	body.velocity.z = v.z
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


func _talk(uid: String, obj: Dictionary) -> void:
	var lines: Array = obj.props.get("dialogue", [])
	var speaker := str(obj.props.get("name", ""))
	await _run_actions(lines.map(func(l): return {"type": "say", "speaker": speaker, "text": l}))
	_run_trigger("talk_to", uid)


func _collect(uid: String, obj: Dictionary) -> void:
	_hide(uid)
	match obj.type:
		"cash":
			cash += int(obj.props.get("amount", 10))
			var left := false
			for other in objects:
				if objects[other].obj.type == "cash" and not hidden.has(other):
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
		player.position = respawn + Vector3(0, 0.5, 0)
		player.velocity = Vector3.ZERO
		if lives < 0:
			lives = 3
			cash = 0
			start.call_deferred(App.game.get("start_level", level_id))


func _update_hud() -> void:
	hud.text = "%s    Chocolate %d/6    Tails x%d    $%d" % [level.get("title", ""), max(0, health), max(0, lives), cash]


# --- events ---------------------------------------------------------------------------------

func _run_trigger(type: String, uid: String) -> void:
	for event in level.get("events", []):
		var when: Dictionary = event.get("when", {})
		if when.get("type") == type and (uid == "" or when.get("object") == uid):
			await _run_actions(event.get("do", []))


func _run_actions(actions: Array) -> void:
	for action in actions:
		match action.get("type"):
			"say":
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
				busy = false
			"give_cash":
				cash += int(action.get("amount", 0))
			"show":
				var uid := str(action.get("object", ""))
				if objects.has(uid):
					hidden.erase(uid)
					objects[uid].node.visible = objects[uid].obj.type not in ["trigger_zone", "player_start", "spawn_point"]
			"hide":
				var uid := str(action.get("object", ""))
				if objects.has(uid):
					_hide(uid)
			"set_flag":
				flags[str(action.get("flag", ""))] = true
			"goto_level":
				var target := str(action.get("level", ""))
				if App.levels.has(target):
					start.call_deferred(target, str(action.get("spawn", "")))
					return
			"wait":
				await get_tree().create_timer(float(action.get("seconds", 1.0))).timeout
			"play_music":
				_play_music(int(action.get("track", 0)))
