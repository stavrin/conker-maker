# Works out which of a ROM character's animations is its idle, walk, run, attack, hurt and
# death, by looking at the poses: the ROM only numbers them. catalog/objects.json can name
# them outright for characters we've checked by eye ("character_animations"); this fills in
# the rest. Each result is the animation's name in the model's AnimationPlayer ("" if none fits).
#
#   idle    loops, stands, feet barely move
#   walk    loops, stands, longest stride (and not too quick)
#   run     loops, stands, long stride over a short cycle
#   die     starts standing, ends lying down
#   hurt    starts and ends standing, dips or staggers in between, short
#   attack  starts and ends standing, reaches furthest forward
extends RefCounted

const SAMPLES := 16


static func classify(player: AnimationPlayer, skeleton: Skeleton3D) -> Dictionary:
	var names := Array(player.get_animation_list())
	names.sort()
	var roles := {"idle": "", "walk": "", "run": "", "attack": "", "hurt": "", "die": ""}
	if names.is_empty() or skeleton == null or skeleton.get_bone_count() < 3:
		return roles
	var order := _parent_first(skeleton)
	var rest := _globals(skeleton, order, {}, 0.0, null)
	var feet := _lowest_two(rest)
	var rest_h := _height(rest)
	var rest_reach := _reach(rest)
	if rest_h <= 0.0:
		return roles
	var stats := []
	for name in names:
		stats.append(_measure(player.get_animation(name), name, skeleton, order, feet, rest_h, rest_reach))

	var taken := {}
	var pick := func(role: String, ok: Callable, score: Callable) -> void:
		var best = null
		for s in stats:
			if taken.has(s.name) or not ok.call(s):
				continue
			if best == null or score.call(s) > score.call(best):
				best = s
		if best != null:
			roles[role] = best.name
			taken[best.name] = true
	var first := func(s): return -names.find(s.name)   # earliest in the ROM's order wins
	pick.call("idle", func(s): return s.loop < 0.25 and s.min_h > 0.85 and s.stride < 0.12, first)
	pick.call("walk", func(s): return s.loop < 0.25 and s.min_h > 0.7 and s.stride >= 0.2 and s.length >= 0.85,
			func(s): return s.stride)
	pick.call("run", func(s): return s.loop < 0.25 and s.min_h > 0.65 and s.stride >= 0.25 and s.length < 0.85,
			func(s): return s.stride / s.length)
	pick.call("die", func(s): return s.start_h > 0.8 and s.end_h < 0.65 and s.loop > 0.25, first)
	pick.call("hurt", func(s): return _hurt_like(s), first)
	pick.call("attack", func(s): return _attack_like(s), func(s): return s.reach)
	if roles.idle == "":
		roles.idle = names[0]
	return roles


static func _hurt_like(s: Dictionary) -> bool:
	return s.start_h > 0.85 and s.end_h > 0.85 and s.loop > 0.25 and s.min_h < 0.95 \
			and s.length >= 0.3 and s.length <= 1.3


static func _attack_like(s: Dictionary) -> bool:
	return s.start_h > 0.85 and s.end_h > 0.85 and s.reach > 0.2 and s.length >= 0.4 and s.length <= 1.6


static func _measure(anim: Animation, name: String, skeleton: Skeleton3D, order: Array, feet: Array,
		rest_h: float, rest_reach: float) -> Dictionary:
	var tracks := {}   # bone -> {pos, rot, scale} track indices
	for t in anim.get_track_count():
		var bone := skeleton.find_bone(String(anim.track_get_path(t).get_concatenated_subnames()))
		if bone < 0:
			continue
		var entry: Dictionary = tracks.get(bone, {})
		match anim.track_get_type(t):
			Animation.TYPE_POSITION_3D: entry.pos = t
			Animation.TYPE_ROTATION_3D: entry.rot = t
			Animation.TYPE_SCALE_3D: entry.scale = t
		tracks[bone] = entry
	var length := maxf(anim.length, 0.001)
	var heights := []
	var gaps := []
	var reach := 0.0
	for i in SAMPLES + 1:
		var g := _globals(skeleton, order, tracks, length * i / SAMPLES, anim)
		heights.append(_height(g) / rest_h)
		gaps.append((g[feet[0]].z - g[feet[1]].z) / rest_h)
		reach = maxf(reach, (_reach(g) - rest_reach) / rest_h)
	var loop := 0.0
	for bone in tracks:
		if tracks[bone].has("rot"):
			var a: Quaternion = anim.rotation_track_interpolate(tracks[bone].rot, 0.0)
			var b: Quaternion = anim.rotation_track_interpolate(tracks[bone].rot, length)
			loop = maxf(loop, a.angle_to(b))
	return {"name": name, "length": length, "loop": loop, "stride": gaps.max() - gaps.min(),
			"min_h": heights.min(), "start_h": heights[0], "end_h": heights[-1], "reach": reach}


# Bones ordered so each comes after its parent.
static func _parent_first(skeleton: Skeleton3D) -> Array:
	var order := []
	var seen := {}
	for b in skeleton.get_bone_count():
		var chain := []
		var c := b
		while c >= 0 and not seen.has(c):
			chain.push_front(c)
			c = skeleton.get_bone_parent(c)
		for x in chain:
			seen[x] = true
			order.append(x)
	return order


# Every bone's position in the model's space at time t (rest pose where a track is missing).
static func _globals(skeleton: Skeleton3D, order: Array, tracks: Dictionary, t: float, anim: Animation) -> Array:
	var xf := []
	xf.resize(skeleton.get_bone_count())
	for b in order:
		var rest := skeleton.get_bone_rest(b)
		var pos := rest.origin
		var rot := rest.basis.get_rotation_quaternion()
		var scl := rest.basis.get_scale()
		var tr: Dictionary = tracks.get(b, {})
		if anim:
			if tr.has("pos"): pos = anim.position_track_interpolate(tr.pos, t)
			if tr.has("rot"): rot = anim.rotation_track_interpolate(tr.rot, t)
			if tr.has("scale"): scl = anim.scale_track_interpolate(tr.scale, t)
		var local := Transform3D(Basis(rot) * Basis.from_scale(scl), pos)
		var parent := skeleton.get_bone_parent(b)
		xf[b] = (xf[parent] * local) if parent >= 0 else local
	var points := []
	for x in xf:
		points.append((x as Transform3D).origin)
	return points


static func _height(points: Array) -> float:
	var lo := INF
	var hi := -INF
	for p in points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	return hi - lo


# How far forward (+Z: ROM characters face +Z) any bone gets, from the body's middle.
static func _reach(points: Array) -> float:
	var mid := 0.0
	for p in points:
		mid += p.z
	mid /= points.size()
	var most := -INF
	for p in points:
		most = maxf(most, p.z - mid)
	return most


# The two feet: the lowest joint on each side of the body (left and right of the middle).
static func _lowest_two(points: Array) -> Array:
	var mid := 0.0
	for p in points:
		mid += p.x
	mid /= points.size()
	var left := -1
	var right := -1
	for i in points.size():
		if points[i].x < mid and (left < 0 or points[i].y < points[left].y):
			left = i
		elif points[i].x >= mid and (right < 0 or points[i].y < points[right].y):
			right = i
	if left < 0 or right < 0:
		var idx := range(points.size())
		idx.sort_custom(func(a, b): return points[a].y < points[b].y)
		return [idx[0], idx[1]]
	return [left, right]
