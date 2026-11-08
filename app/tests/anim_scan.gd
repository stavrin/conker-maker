# Lists every Conker animation with how upright his body is through it (degrees from vertical,
# head over feet), whether it loops and how long it is, to find ones like swimming. Needs LIB.
extends Node

func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	var m := Rom.instance_model("b01-0000-00")
	add_child(m)
	var ap := Rom.animation_player(m)
	var sk: Skeleton3D = m.find_children("*", "Skeleton3D", true, false)[0]
	var n := sk.get_bone_count()
	var head := 0
	var feet := []
	var ys := []
	for b in n:
		ys.append([sk.get_bone_global_rest(b).origin.y, b])
	ys.sort()
	feet = [ys[0][1], ys[1][1]]
	head = ys[-1][1]
	var out := FileAccess.open(OS.get_cmdline_user_args()[0], FileAccess.WRITE)
	var names := Array(ap.get_animation_list())
	names.sort()
	for name in names:
		var anim := ap.get_animation(name)
		ap.play(name)
		var tilts := []
		var heights := []
		for i in 9:
			ap.seek(anim.length * i / 8.0, true)
			var h := sk.get_bone_global_pose(head).origin
			var f := (sk.get_bone_global_pose(feet[0]).origin + sk.get_bone_global_pose(feet[1]).origin) / 2.0
			var v := h - f
			tilts.append(rad_to_deg(v.angle_to(Vector3.UP)))
			heights.append(h.y)
		out.store_line("%s\t%.2f\t%d\t%.0f\t%.0f\t%.0f" % [name, anim.length, anim.loop_mode, tilts.min(), tilts.max(), (tilts[0]+tilts[4]+tilts[8])/3.0])
	out.close()
	get_tree().quit()
