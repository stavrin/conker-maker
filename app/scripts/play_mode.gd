# Quick playtest inside Conker Maker: walk around your levels with a stand-in Conker, collect
# things, talk to characters and run your events. It's for checking layouts and logic fast;
# "Playtest in recomp" runs the real game.
#
#   WASD move   Space jump (hold in the air to hover with the tail)   E / B interact
#   Right mouse or arrow keys turn the camera                         Esc back to the editor
extends Node3D

signal finished

const Visuals := preload("res://scripts/visuals.gd")
const SPEED := 7.0
const JUMP := 9.0
const GRAVITY := 24.0
const HOVER_FALL := 1.5
const HOVER_TIME := 2.0

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
		else:
			node = Visuals.build(obj, spec, false)
		if obj.type == "trigger_zone":
			node.visible = false
		if obj.type in ["player_start", "spawn_point"]:
			node.visible = false
		add_child(node)
		objects[obj.uid] = {"obj": obj, "node": node, "home": node.position, "t": 0.0}
		if obj.type == "player_start" and spawn == "":
			start_pos = node.position
			start_turn = node.rotation.y
		if obj.type == "spawn_point" and spawn != "" and (obj.props.get("name") == spawn or obj.uid == spawn):
			start_pos = node.position
			start_turn = node.rotation.y
	_make_player(start_pos, start_turn)
	respawn = start_pos
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
		for key in ["idle", "run", "jump", "hover"]:
			var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get(key, ""))
			if anim != "":
				player_anim.get_animation(anim).loop_mode = Animation.LOOP_LINEAR
		for child in look.get_children():   # the editor's facing marker isn't needed on the real model
			if child is MeshInstance3D and child.name != "Selection":
				child.visible = false
	player.position = pos + Vector3(0, 0.1, 0)
	player.rotation.y = turn
	cam_yaw = turn
	add_child(player)


func _unhandled_input(event: InputEvent) -> void:
	_handle(event)


func handle_input(event: InputEvent) -> void:
	_handle(event)


func _handle(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_turn = event.pressed
	elif event is InputEventMouseMotion and _mouse_turn:
		cam_yaw -= event.relative.x * 0.006
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			finished.emit()
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
	var input := Vector2.ZERO
	if not busy:
		input.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
		input.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var dir := (Basis(Vector3.UP, cam_yaw) * Vector3(input.x, 0, input.y))
	if dir.length() > 1:
		dir = dir.normalized()
	player.velocity.x = dir.x * SPEED
	player.velocity.z = dir.z * SPEED
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
	if player_anim:
		var state := "idle"
		if not player.is_on_floor():
			state = "hover" if player.velocity.y > -HOVER_FALL - 0.1 and player.velocity.y <= 0.0 and jump else "jump"
		elif dir.length() > 0.1:
			state = "run"
		_play_anim(state)
	if dir.length() > 0.1:
		player.get_node("Look").rotation.y = lerp_angle(player.get_node("Look").rotation.y, atan2(-dir.x, -dir.z) - player.rotation.y, 0.25)
	var target := player.position + Basis(Vector3.UP, cam_yaw) * Vector3(0, 4.5, 9)
	camera.position = camera.position.lerp(target, 0.12)
	camera.look_at(player.position + Vector3(0, 1.4, 0))
	if player.position.y < respawn.y - 60.0:   # fell out of the level
		_hurt(99)
	_check_touches(delta)
	_update_hud()

var _jump_held := false
var _jump_held_from_floor := false


func _play_anim(state: String) -> void:
	if state == _anim_now:
		return
	var anim := Rom.find_animation(player_anim, PLAYER_ANIMS.get(state, ""))
	if anim != "":
		player_anim.play(anim, 0.15)
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
				if d < 1.1:
					if player.velocity.y < -1.0 and p.y > node.position.y + 0.6:
						player.velocity.y = JUMP * 0.7
						o.hits = int(o.get("hits", 0)) + 1
						if o.hits >= int(o.obj.props.get("health", 1)):
							_hide(uid)
							_run_trigger("defeat", uid)
					elif float(o.get("cooldown", 0.0)) <= 0.0:
						o.cooldown = 1.0
						_hurt(1)
				o.cooldown = float(o.get("cooldown", 0.0)) - delta
			"npc":
				if d < 2.5:
					near = "Press E to talk to " + str(o.obj.props.get("name", "them"))
			"context_pad":
				if d < 1.5:
					near = str(o.obj.props.get("hint", "Press B"))
	hint.text = near if not busy else ""


func _enemy_step(uid: String, o: Dictionary, delta: float) -> void:
	var radius := float(o.obj.props.get("patrol_radius", 4.0))
	if radius <= 0:
		return
	o.t += delta
	var home: Vector3 = o.home
	o.node.position = home + Vector3(cos(o.t * 0.8) * radius, 0, sin(o.t * 0.8) * radius)


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
				pass   # ROM music arrives with the audio importer
