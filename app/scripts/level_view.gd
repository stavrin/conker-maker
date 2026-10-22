# The 3D view of a level in the editor: camera, picking, placing and dragging objects.
#
#   Left click        select / place the palette's object
#   Left drag         move the selected object across the ground (hold Shift: up and down)
#   Right drag        orbit the camera          Middle drag   pan
#   Wheel             zoom                      Alt           turn snapping off
extends Node3D

signal selected(uid)            # uid or "" for nothing
signal placed(type, position)   # the editor creates the object
signal moved(uid)               # an object finished moving
signal before_change            # about to change something (for undo)

const Visuals := preload("res://scripts/visuals.gd")
const SNAP := 0.5

var level := {}
var nodes := {}                 # uid -> Node3D
var selected_uid := ""
var placing_type := ""          # set from the palette
var camera: Camera3D
var focus := Vector3.ZERO
var yaw := -35.0
var pitch := -40.0
var distance := 28.0
var _dragging := false
var _drag_plane_y := 0.0
var _orbiting := false
var _panning := false
var _press_pos := Vector2.ZERO
var _changed_in_drag := false


func _ready() -> void:
	Visuals.environment(self)
	camera = Camera3D.new()
	camera.fov = 55
	add_child(camera)
	_update_camera()


func _process(delta: float) -> void:
	for node in nodes.values():
		if node.has_meta("spin"):
			node.get_meta("spin").rotation.y += delta * 1.5


func load_level(new_level: Dictionary) -> void:
	level = new_level
	for child in get_children():
		if child.name == "Ground" or child.name.begins_with("obj_") or child.name == "Grid":
			_drop(child)
	nodes.clear()
	add_child(Visuals.base(level))
	if level.get("base", {}).get("kind", "blank") == "blank":
		add_child(_grid())
	for obj in level.get("objects", []):
		_add_node(obj)
		if obj.type == "player_start":   # start the camera on Conker
			focus = Visuals.vec3(obj.position, Vector3.ZERO)
	_update_camera()
	select("")


func _add_node(obj: Dictionary) -> void:
	var spec: Dictionary = App.object_types().get(obj.type, {})
	var node := Visuals.build(obj, spec)
	nodes[obj.uid] = node
	add_child(node)


func refresh_object(uid: String) -> void:
	var obj := find(uid)
	if nodes.has(uid):
		_drop(nodes[uid])
		nodes.erase(uid)
	if not obj.is_empty():
		_add_node(obj)
		if uid == selected_uid:
			Visuals.set_highlight(nodes[uid], true)


func rename_node(old_uid: String, new_uid: String) -> void:
	if nodes.has(old_uid):
		_drop(nodes[old_uid])
		nodes.erase(old_uid)
	selected_uid = new_uid
	refresh_object(new_uid)


func remove_node(uid: String) -> void:
	if nodes.has(uid):
		_drop(nodes[uid])
		nodes.erase(uid)
	if uid == selected_uid:
		select("")


# Removes a node now (so a replacement can take its name) and frees it later.
func _drop(node: Node) -> void:
	remove_child(node)
	node.queue_free()


func find(uid: String) -> Dictionary:
	for obj in level.get("objects", []):
		if obj.uid == uid:
			return obj
	return {}


func select(uid: String) -> void:
	if nodes.has(selected_uid):
		Visuals.set_highlight(nodes[selected_uid], false)
	selected_uid = uid
	if nodes.has(uid):
		Visuals.set_highlight(nodes[uid], true)
	selected.emit(uid)


func frame_selected() -> void:
	if nodes.has(selected_uid):
		focus = nodes[selected_uid].position
		_update_camera()


# --- input (forwarded from the SubViewportContainer) -----------------------------------------

func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance = max(4.0, distance * 0.9)
				_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				distance = min(200.0, distance * 1.1)
				_update_camera()
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_press_pos = mb.position
					_on_left_press(mb.position)
				else:
					if _dragging and _changed_in_drag:
						moved.emit(selected_uid)
					_dragging = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			yaw -= mm.relative.x * 0.3
			pitch = clamp(pitch - mm.relative.y * 0.3, -89.0, -5.0)
			_update_camera()
		elif _panning:
			var right := camera.global_transform.basis.x
			var forward := -camera.global_transform.basis.z
			forward.y = 0
			focus += (-right * mm.relative.x + forward.normalized() * mm.relative.y) * distance * 0.0015
			_update_camera()
		elif _dragging and nodes.has(selected_uid):
			_drag_to(mm)


func _on_left_press(pos: Vector2) -> void:
	var hit = _raycast(pos, 1 << (Visuals.PICK_LAYER - 1))
	if placing_type != "":
		var ground_hit = _raycast(pos, 0xFFFFFFFF ^ (1 << (Visuals.PICK_LAYER - 1)))
		var point: Vector3 = ground_hit.position if ground_hit else _plane_point(pos, 0.0)
		placed.emit(placing_type, _snap(point, Input.is_key_pressed(KEY_ALT)))
		return
	if hit and hit.collider.has_meta("uid"):
		select(hit.collider.get_meta("uid"))
		_dragging = true
		_changed_in_drag = false
		_drag_plane_y = nodes[selected_uid].position.y
	else:
		select("")


func _drag_to(mm: InputEventMouseMotion) -> void:
	var obj := find(selected_uid)
	if obj.is_empty():
		return
	if not _changed_in_drag:
		before_change.emit()
		_changed_in_drag = true
	var no_snap := Input.is_key_pressed(KEY_ALT)
	var p := Visuals.vec3(obj.position, Vector3.ZERO)
	if Input.is_key_pressed(KEY_SHIFT):
		p.y = max(-50.0, p.y - mm.relative.y * distance * 0.002)
		if not no_snap:
			p.y = snappedf(p.y, SNAP / 2.0)
	else:
		var point := _plane_point(mm.position, _drag_plane_y)
		p = Vector3(point.x, p.y, point.z)
		if not no_snap:
			p = Vector3(snappedf(p.x, SNAP), p.y, snappedf(p.z, SNAP))
	obj.position = [p.x, p.y, p.z]
	Visuals.apply_transform(nodes[selected_uid], obj)


func _snap(p: Vector3, off: bool) -> Vector3:
	if off:
		return p
	return Vector3(snappedf(p.x, SNAP), snappedf(p.y, SNAP / 2.0), snappedf(p.z, SNAP))


func _raycast(pos: Vector2, mask: int):
	var from := camera.project_ray_origin(pos)
	var to := from + camera.project_ray_normal(pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	return result if not result.is_empty() else null


func _plane_point(pos: Vector2, y: float) -> Vector3:
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var hit = Plane(Vector3.UP, y).intersects_ray(origin, dir)
	return hit if hit != null else Vector3(focus.x, y, focus.z)


func _update_camera() -> void:
	var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
	camera.position = focus + basis * Vector3(0, 0, distance)
	camera.look_at(focus)


func _grid() -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	var g: Dictionary = level.get("base", {}).get("ground", {})
	var size: Array = g.get("size", [60, 60])
	var hx := float(size[0]) / 2.0
	var hz := float(size[1]) / 2.0
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var x := -hx
	while x <= hx:
		mesh.surface_add_vertex(Vector3(x, 0.02, -hz))
		mesh.surface_add_vertex(Vector3(x, 0.02, hz))
		x += 2.0
	var z := -hz
	while z <= hz:
		mesh.surface_add_vertex(Vector3(-hx, 0.02, z))
		mesh.surface_add_vertex(Vector3(hx, 0.02, z))
		z += 2.0
	mesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.name = "Grid"
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0, 0, 0, 0.18)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	return mi
