extends Node3D
const Visuals := preload("res://scripts/visuals.gd")
func _ready() -> void:
	App.settings.library_dir = OS.get_environment("LIB")
	Rom.reload()
	Visuals.environment(self)
	var spec: Dictionary = App.object_types().get("cash", {})
	for i in 4:
		var n := Visuals.build({"uid": "c%d" % i, "type": "cash", "position": [i * 1.2 - 1.8, 0, 0], "props": {}}, spec, false)
		n.get_meta("spin").rotation.y = i * PI / 2
		n.get_node("Tag").visible = false
		add_child(n)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.0, 4)
	add_child(cam)
	cam.look_at(Vector3(0, 0.6, 0))
	for i in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[0].path_join("cash.png"))
	get_tree().quit()
