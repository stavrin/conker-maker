# Stand-in visuals for each object type, built from the catalog's colour and shape.
# Once the ROM model importer lands, objects with a 'model' prop show the real model instead.
extends RefCounted

const PICK_LAYER := 2
const GroundFit := preload("res://scripts/ground_fit.gd")


static func material(color: Color, translucent := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.8
	if translucent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = 0.25
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func vec3(value, fallback := Vector3.ONE) -> Vector3:
	if value is Array and value.size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


# Returns {mesh: Mesh, offset: Vector3 (mesh centre above the object's position), size: Vector3}.
static func shape_for(obj: Dictionary, spec: Dictionary) -> Dictionary:
	var props: Dictionary = obj.get("props", {})
	match spec.get("shape", "box"):
		"capsule":
			var m := CapsuleMesh.new()
			m.radius = 0.45
			m.height = 1.8
			return {"mesh": m, "offset": Vector3(0, 0.9, 0), "size": Vector3(0.9, 1.8, 0.9)}
		"disc":
			var m := CylinderMesh.new()
			m.top_radius = 0.8
			m.bottom_radius = 0.8
			m.height = 0.1
			return {"mesh": m, "offset": Vector3(0, 0.05, 0), "size": Vector3(1.6, 0.3, 1.6)}
		"portal":
			var m := TorusMesh.new()
			m.inner_radius = 1.1
			m.outer_radius = 1.5
			return {"mesh": m, "offset": Vector3(0, 1.5, 0), "rotate_x": true, "size": Vector3(3, 3, 0.6)}
		"flag":
			var m := CylinderMesh.new()
			m.top_radius = 0.08
			m.bottom_radius = 0.08
			m.height = 2.5
			return {"mesh": m, "offset": Vector3(0, 1.25, 0), "size": Vector3(0.6, 2.5, 0.6)}
		"pad":
			var m := CylinderMesh.new()
			m.top_radius = 0.9
			m.bottom_radius = 1.0
			m.height = 0.15
			return {"mesh": m, "offset": Vector3(0, 0.075, 0), "size": Vector3(2, 0.3, 2)}
		"cash":
			var m := BoxMesh.new()
			m.size = Vector3(0.6, 0.25, 0.35)
			return {"mesh": m, "offset": Vector3(0, 0.6, 0), "size": Vector3(0.8, 0.8, 0.8), "spin": true}
		"block":
			var m := BoxMesh.new()
			m.size = Vector3(0.5, 0.15, 0.7)
			return {"mesh": m, "offset": Vector3(0, 0.6, 0), "size": Vector3(0.8, 0.8, 0.8), "spin": true}
		"tail":
			var m := CapsuleMesh.new()
			m.radius = 0.2
			m.height = 0.9
			return {"mesh": m, "offset": Vector3(0, 0.7, 0), "size": Vector3(0.6, 1, 0.6), "spin": true}
		"camera":
			var h := float(props.get("height", 1.6))
			var m := BoxMesh.new()
			m.size = Vector3(0.35, 0.3, 0.45)
			return {"mesh": m, "offset": Vector3(0, h, 0), "size": Vector3(0.6, h + 0.4, 0.6), "camera": true}
		"spot":
			var m := CylinderMesh.new()
			m.top_radius = 0.45
			m.bottom_radius = 0.45
			m.height = 0.06
			return {"mesh": m, "offset": Vector3(0, 0.03, 0), "size": Vector3(0.9, 0.3, 0.9)}
		"crate":
			var m := BoxMesh.new()
			m.size = Vector3(0.7, 0.7, 0.7)
			return {"mesh": m, "offset": Vector3(0, 0.35, 0), "size": Vector3(0.7, 0.7, 0.7)}
		"water":
			var size := vec3(props.get("size"), Vector3(8, 3, 8))
			var m := BoxMesh.new()
			m.size = size
			return {"mesh": m, "offset": Vector3(0, size.y / 2.0, 0), "size": size, "water": true}
		_:
			var size := vec3(props.get("size"), Vector3(2, 2, 2))
			var m := BoxMesh.new()
			m.size = size
			return {"mesh": m, "offset": Vector3(0, size.y / 2.0, 0), "size": size}


# A node for one object: the mesh, a name tag, and (for the editor) a pick body.
static func build(obj: Dictionary, spec: Dictionary, pickable := true) -> Node3D:
	var root := Node3D.new()
	root.name = "obj_" + str(obj.get("uid", ""))
	var info := shape_for(obj, spec)
	var model_id := model_id_for(obj, spec)
	var model: Node3D = Rom.instance_model(model_id) if model_id != "" else null
	if model:
		info = fit_model(model, info)
		root.add_child(info.node)
		root.set_meta("model", info.node)
		if info.get("spin", false):
			root.set_meta("spin", info.node)
	else:
		_build_primitive(root, obj, spec, info)
	_add_tag_and_pick(root, obj, spec, info, pickable)
	apply_transform(root, obj)
	return root


# Which ROM model an object shows: its own 'model' prop, else its type's default.
static func model_id_for(obj: Dictionary, spec: Dictionary) -> String:
	var chosen = obj.get("props", {}).get("model")
	if chosen is Dictionary and chosen.get("id", "") != "":
		return chosen.id
	return spec.get("rom_model", "") if Rom.is_ready() else ""


# Wraps a ROM model so it stands on the object's position at the right size.
static func fit_model(model: Node3D, info: Dictionary) -> Dictionary:
	var holder := Node3D.new()
	holder.name = "Model"
	model.scale = Vector3.ONE * Rom.world_scale
	holder.add_child(model)
	var size: Vector3 = info.size
	var lift := 0.0
	if Rom.is_skinned(model):
		# Characters face +Z in the ROM (animated or not, like Mrs. Bee): turn them to face -Z.
		model.rotation.y = PI
	if Rom.is_skinned(model) and Rom.animation_player(model) != null:
		var player := Rom.animation_player(model)
		if player:
			var anim: String = Rom.find_animation(player, info.anim) if info.get("anim", "") != "" \
					else Rom.roles(model).get("idle", "")
			if anim != "":
				player.get_animation(anim).loop_mode = Animation.LOOP_LINEAR
				player.play(anim)
		var fit := Node.new()
		fit.set_script(GroundFit)
		holder.add_child(fit)
		info.spin = false   # animated characters and pickups play their own animation instead
	else:
		# Static models (and skinned ones with nothing to play, like the cash wad): centre on
		# the position, resting on the ground.
		var box := Rom.aabb_of(model)
		box = AABB(box.position * Rom.world_scale, box.size * Rom.world_scale)
		model.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z)
		size = box.size
		if info.get("spin", false):
			lift = 0.3
	holder.position.y = lift
	return {"node": holder, "size": Vector3(max(size.x, 0.4), max(size.y, 0.4) + lift, max(size.z, 0.4)),
			"offset": Vector3(0, size.y / 2.0 + lift, 0), "spin": info.get("spin", false)}


static func _build_primitive(root: Node3D, obj: Dictionary, spec: Dictionary, info: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = info.mesh
	mi.position = info.offset
	if info.get("rotate_x", false):
		mi.rotation_degrees.x = 90
	mi.material_override = material(Color(spec.get("color", "#888888")), spec.get("translucent", false))
	root.add_child(mi)
	if info.get("water", false):
		_dress_water(root, mi, info.size)
	if info.get("camera", false):   # a lens pointing the way the camera looks, and a post to the ground
		var lens := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.02
		cone.bottom_radius = 0.16
		cone.height = 0.3
		lens.mesh = cone
		lens.rotation_degrees.x = 90
		lens.position = info.offset + Vector3(0, 0, -0.35)
		lens.material_override = material(Color("2a1d33"))
		root.add_child(lens)
		var post := MeshInstance3D.new()
		var stick := CylinderMesh.new()
		stick.top_radius = 0.03
		stick.bottom_radius = 0.03
		stick.height = maxf(info.offset.y - 0.15, 0.01)
		post.mesh = stick
		post.position = Vector3(0, stick.height / 2.0, 0)
		post.material_override = material(Color("6d5a78"), true)
		root.add_child(post)
	if info.get("spin", false):
		root.set_meta("spin", mi)
	if spec.get("shape") == "flag":
		var cloth := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(0.9, 0.55, 0.05)
		cloth.mesh = cm
		cloth.position = Vector3(0.5, 2.2, 0)
		cloth.material_override = material(Color(spec.get("color")))
		root.add_child(cloth)
	if obj.get("type") == "player_start" or spec.get("shape") == "capsule":
		var nose := MeshInstance3D.new()   # shows which way it faces
		var nm := BoxMesh.new()
		nm.size = Vector3(0.2, 0.2, 0.4)
		nose.mesh = nm
		nose.position = Vector3(0, 1.4, -0.5)
		nose.material_override = material(Color("1e1712"))
		root.add_child(nose)


# Water: a see-through blue body, and a rippling surface on top.
const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;
uniform vec4 tint : source_color = vec4(0.08, 0.32, 0.66, 0.6);
void fragment() {
	vec2 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	float t = TIME;
	float w = sin(p.x * 1.7 + t * 1.3) + sin(p.y * 2.1 - t * 1.1) + sin((p.x + p.y) * 1.1 + t * 0.7);
	vec3 n = normalize(vec3(cos(p.x * 1.7 + t * 1.3) * 0.12, 1.0, cos(p.y * 2.1 - t * 1.1) * 0.12));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ALBEDO = tint.rgb + vec3(0.04) * w;
	ALPHA = tint.a;
	ROUGHNESS = 0.08;
	SPECULAR = 0.7;
}
"""

static func _dress_water(root: Node3D, body: MeshInstance3D, size: Vector3) -> void:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.06, 0.26, 0.58, 0.4)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.2
	body.material_override = m
	var top := MeshInstance3D.new()
	top.name = "Surface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(size.x, size.z)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	top.mesh = plane
	top.position = Vector3(0, size.y - 0.01, 0)
	var shader := Shader.new()
	shader.code = WATER_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = shader
	top.material_override = sm
	root.add_child(top)


static func _add_tag_and_pick(root: Node3D, obj: Dictionary, spec: Dictionary, info: Dictionary, pickable: bool) -> void:
	var tag := Label3D.new()
	tag.name = "Tag"
	var props: Dictionary = obj.get("props", {})
	tag.text = str(props.get("name", spec.get("label", obj.get("type"))))
	if obj.get("type") == "cash":
		tag.text = "$%d" % int(props.get("amount", 0))
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0, info.size.y + 0.5, 0)
	tag.font_size = 64
	tag.pixel_size = 0.012
	tag.outline_size = 12
	tag.no_depth_test = true
	root.add_child(tag)

	if pickable:
		var body := StaticBody3D.new()
		body.name = "Pick"
		body.collision_layer = 1 << (PICK_LAYER - 1)
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var size: Vector3 = info.size
		box.size = Vector3(max(size.x, 0.5), max(size.y, 0.5), max(size.z, 0.5))
		shape.shape = box
		shape.position = Vector3(0, info.size.y / 2.0, 0)
		body.add_child(shape)
		body.set_meta("uid", obj.get("uid"))
		root.add_child(body)
		# A see-through box shown while the object is selected.
		var sel := MeshInstance3D.new()
		sel.name = "Selection"
		var sm := BoxMesh.new()
		sm.size = box.size * 1.05
		sel.mesh = sm
		sel.position = shape.position
		var m := material(Color("e8a33c"), true)
		m.albedo_color.a = 0.18
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sel.material_override = m
		sel.visible = false
		root.add_child(sel)


static func apply_transform(node: Node3D, obj: Dictionary) -> void:
	node.position = vec3(obj.get("position"), Vector3.ZERO)
	node.rotation_degrees = Vector3(float(obj.get("rotation_x", 0)), float(obj.get("rotation_y", 0)),
			float(obj.get("rotation_z", 0)))
	var s := float(obj.get("scale", 1.0))
	node.scale = Vector3(s, s, s)


static func set_highlight(node: Node3D, on: bool) -> void:
	var sel := node.get_node_or_null("Selection") as MeshInstance3D
	if sel:
		sel.visible = on
	var mesh := node.get_node_or_null("Mesh") as MeshInstance3D
	if mesh and mesh.material_override:
		var m := mesh.material_override as StandardMaterial3D
		m.emission_enabled = on
		m.emission = Color("e8a33c")
		m.emission_energy_multiplier = 0.6


# Collision shapes matching every mesh under `node`, positioned relative to `node`.
static func trimesh_shapes(node: Node3D) -> Array:
	var shapes := []
	var stack := [[node, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != node:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var shape := CollisionShape3D.new()
			shape.shape = (n as MeshInstance3D).mesh.create_trimesh_shape()
			shape.transform = xf
			shapes.append(shape)
		for child in n.get_children():
			stack.append([child, xf])
	return shapes


# What a level stands on: flat ground, or a scene from the ROM (with collision).
static func base(level: Dictionary) -> Node3D:
	var b: Dictionary = level.get("base", {})
	if b.get("kind") == "rom_scene":
		var scene := Rom.instance_scene(str(b.get("scene", "")))
		if scene:
			var root := Node3D.new()
			root.name = "Ground"
			scene.scale = Vector3.ONE * Rom.world_scale
			root.add_child(scene)
			var body := StaticBody3D.new()
			body.name = "GroundBody"
			root.add_child(body)
			for shape in trimesh_shapes(root):
				body.add_child(shape)
			return root
	return ground(level)


static func ground(level: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Ground"
	var g: Dictionary = level.get("base", {}).get("ground", {})
	var size: Array = g.get("size", [60, 60])
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(float(size[0]), float(size[1]))
	mi.mesh = pm
	mi.material_override = material(Color(g.get("color", "#5f8a3a")))
	root.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(float(size[0]), 1, float(size[1]))
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	body.add_child(shape)
	root.add_child(body)
	return root


static func environment(world: Node3D) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("6fa8dc")
	sm.sky_horizon_color = Color("f3d9a4")
	sm.ground_horizon_color = Color("f3d9a4")
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_light_color = Color("f3d9a4")
	e.fog_density = 0.0006
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.85
	world.add_child(sun)
