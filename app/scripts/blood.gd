# Bad Fur Day's blood: a spray of drops when something's hit, a pool where it falls, and
# splats on the screen when it happens close to the camera, which slide down and fade.
# The splat pictures are drawn here at startup (no image files needed).
extends RefCounted

const RED := Color(0.62, 0.0, 0.03)
const SPLATS := 5
static var _textures: Array = []


# A one-shot spray of drops from `at`, mostly along `toward`.
static func burst(parent: Node3D, at: Vector3, toward: Vector3, amount := 45) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = amount
	p.lifetime = 1.0
	p.explosiveness = 0.9
	p.direction = (toward.normalized() + Vector3(0, 0.9, 0)).normalized()
	p.spread = 55.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 6.5
	p.gravity = Vector3(0, -15, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.5
	var drop := SphereMesh.new()
	drop.radius = 0.045
	drop.height = 0.09
	drop.radial_segments = 6
	drop.rings = 3
	var m := StandardMaterial3D.new()
	m.albedo_color = RED
	m.roughness = 0.25
	drop.material = m
	p.mesh = drop
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(2.5).timeout.connect(p.queue_free)


# A pool of blood on whatever's under `at`, which soaks away after a while.
static func pool(parent: Node3D, at: Vector3, size := 1.8) -> void:
	var space := parent.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3(0, 0.5, 0), at + Vector3(0, -3, 0), 1))
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	mesh.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_texture = texture(randi() % SPLATS)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.2
	m.albedo_color = Color(0.6, 0.5, 0.5, 0.95)   # darker than the screen splats: lit by the sun
	mesh.material_override = m
	parent.add_child(mesh)
	mesh.global_position = (hit.position if not hit.is_empty() else at) + Vector3(0, 0.02, 0)
	if not hit.is_empty():
		var n: Vector3 = hit.normal
		if absf(n.dot(Vector3.UP)) < 0.999:
			mesh.global_basis = Basis(Quaternion(Vector3.UP, n))
	mesh.rotate_object_local(Vector3.UP, randf() * TAU)
	mesh.scale = Vector3(0.2, 1, 0.2)
	var tween := mesh.create_tween()
	tween.tween_property(mesh, "scale", Vector3.ONE, 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_interval(20.0)
	tween.tween_property(m, "albedo_color:a", 0.0, 4.0)
	tween.tween_callback(mesh.queue_free)


# Splats on the screen (`count` of them), like when something's killed right by the camera.
static func screen(layer: CanvasLayer, count := 1) -> void:
	var view := layer.get_viewport().get_visible_rect().size
	for i in count:
		var splat := TextureRect.new()
		splat.texture = texture(randi() % SPLATS)
		splat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		splat.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		splat.stretch_mode = TextureRect.STRETCH_SCALE
		var side := randf_range(0.22, 0.45) * minf(view.x, view.y)
		splat.size = Vector2(side, side)
		splat.pivot_offset = splat.size / 2.0
		splat.position = Vector2(randf_range(0.0, view.x - side), randf_range(0.0, view.y * 0.75 - side * 0.5))
		splat.rotation = randf() * TAU
		splat.scale = Vector2(0.4, 0.4)
		layer.add_child(splat)
		var tween := splat.create_tween()
		tween.tween_property(splat, "scale", Vector2.ONE, 0.07)
		tween.tween_interval(randf_range(0.9, 1.5))
		tween.set_parallel(true)
		tween.tween_property(splat, "position:y", splat.position.y + side * 0.35, 2.0).set_ease(Tween.EASE_IN)
		tween.tween_property(splat, "modulate:a", 0.0, 2.0).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(splat.queue_free)


static func texture(i: int) -> Texture2D:
	if _textures.is_empty():
		for n in SPLATS:
			_textures.append(_draw_splat(1000 + n * 77))
	return _textures[i % _textures.size()]


# A splat: a big blob, smaller blobs around it, streaks thrown outward and loose droplets.
static func _draw_splat(seed_value: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var size := 160
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(RED.r, RED.g, RED.b, 0.0))
	var c := Vector2(size, size) / 2.0
	_blob(img, c, size * rng.randf_range(0.17, 0.22), rng)
	for i in rng.randi_range(6, 10):
		var a := rng.randf() * TAU
		_blob(img, c + Vector2.from_angle(a) * size * rng.randf_range(0.1, 0.24), size * rng.randf_range(0.05, 0.11), rng)
	for i in rng.randi_range(3, 6):   # streaks
		var a := rng.randf() * TAU
		var r := size * rng.randf_range(0.05, 0.07)
		var d := size * 0.18
		while r > 1.2 and d < size * 0.47:
			_blob(img, c + Vector2.from_angle(a) * d, r, rng)
			d += r * 1.1
			r *= 0.86
	for i in rng.randi_range(10, 18):   # droplets
		var a := rng.randf() * TAU
		_blob(img, c + Vector2.from_angle(a) * size * rng.randf_range(0.28, 0.46), size * rng.randf_range(0.008, 0.025), rng)
	return ImageTexture.create_from_image(img)


static func _blob(img: Image, at: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	var size := img.get_width()
	var shade := rng.randf_range(0.8, 1.15)
	for y in range(maxi(0, int(at.y - r - 1)), mini(size, int(at.y + r + 2))):
		for x in range(maxi(0, int(at.x - r - 1)), mini(size, int(at.x + r + 2))):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(at)
			var alpha := clampf(r - d + 0.5, 0.0, 1.0) * 0.97
			if alpha <= 0.0:
				continue
			var old := img.get_pixel(x, y)
			if alpha > old.a:
				img.set_pixel(x, y, Color(RED.r * shade, RED.g, RED.b, alpha))
