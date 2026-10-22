# Runs the app's ROM import end to end (slow: several minutes). ROM path in ROM env var.
extends Node

func _ready() -> void:
	App.settings.rom_path = OS.get_environment("ROM")
	App.settings.python = "python3" if OS.get_name() != "Windows" else "python"
	print("start: ", Rom.start_import())
	var last := ""
	while Rom.importing:
		await get_tree().create_timer(2.0).timeout
		var st := Rom.import_status()
		var line := "%s/%s %s" % [st.get("step"), st.get("steps"), st.get("message")]
		if line != last:
			print(line)
			last = line
	print("result: ", Rom.import_result)
	print("ready: ", Rom.is_ready(), " models ", Rom.models.size(), " scenes ", Rom.scenes.size(), " dir ", Rom.dir)
	get_tree().quit()
