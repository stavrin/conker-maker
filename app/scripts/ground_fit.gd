# Lifts a skinned ROM character so its feet rest on its position, in the pose it's playing.
# (The ROM's character origins aren't at the soles, so without this they sink into the floor.)
extends Node


func _ready() -> void:
	await get_tree().process_frame   # let the animation apply its first pose
	var holder := get_parent() as Node3D
	if holder == null or holder.get_child_count() == 0:
		return
	var model := holder.get_child(0) as Node3D
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	var skeleton: Skeleton3D = found[0]
	var lowest := INF
	var lowest_rest := INF
	for i in skeleton.get_bone_count():
		var pose := model.to_local(skeleton.to_global(skeleton.get_bone_global_pose(i).origin))
		lowest = min(lowest, pose.y)
		lowest_rest = min(lowest_rest, skeleton.get_bone_global_rest(i).origin.y)
	# How far the soles sit below the lowest joint, from the mesh in its bind pose.
	var mesh_min := INF
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh:
			mesh_min = min(mesh_min, (mi as MeshInstance3D).mesh.get_aabb().position.y)
	var sole: float = min(0.0, mesh_min - lowest_rest) if mesh_min < INF else 0.0
	if lowest < INF:
		model.position.y = -(lowest + sole) * model.scale.y
	queue_free()
