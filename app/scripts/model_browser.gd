# Browse the models imported from your ROM, with a spinning preview, and pick one.
extends Window

signal chosen(id)

const Main := preload("res://scripts/main.gd")
const Visuals := preload("res://scripts/visuals.gd")

var list: ItemList
var search: LineEdit
var category: OptionButton
var named_only: CheckBox
var preview_root: Node3D
var holder: Node3D
var camera: Camera3D
var title_label: Label
var info_label: Label
var use_button: Button
var selected_id := ""
var only_category := ""   # set before showing to start on a category
var on_pick := Callable()  # who gets the choice this time
var levels_mode := false   # browsing whole levels instead of models


func _init() -> void:
	title = "Models from your ROM"
	visible = false
	size = Vector2i(1000, 640)
	transient = true
	exclusive = true
	close_requested.connect(hide)


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	panel.add_child(cols)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(420, 0)
	cols.add_child(left)
	var filters := HBoxContainer.new()
	left.add_child(filters)
	category = OptionButton.new()
	category.add_item("Everything")
	category.set_item_metadata(0, "")
	var cats: Dictionary = Rom.categories()
	for key in cats:
		category.add_item(cats[key])
		category.set_item_metadata(category.item_count - 1, key)
	category.item_selected.connect(func(_i): refresh())
	filters.add_child(category)
	named_only = CheckBox.new()
	named_only.text = "Named only"
	named_only.button_pressed = true
	named_only.tooltip_text = "About 600 level pieces have no name yet; untick to see them too."
	named_only.toggled.connect(func(_on): refresh())
	filters.add_child(named_only)
	search = LineEdit.new()
	search.placeholder_text = "Search: crate, barrel, Tediz, sign..."
	search.text_changed.connect(func(_t): refresh())
	left.add_child(search)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(func(i): _show(list.get_item_metadata(i)))
	list.item_activated.connect(func(_i): _use())
	left.add_child(list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(container)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	container.add_child(viewport)
	preview_root = Node3D.new()
	viewport.add_child(preview_root)
	Visuals.environment(preview_root)
	for child in preview_root.get_children():   # no fog in the preview: whole levels are far away
		if child is WorldEnvironment:
			(child as WorldEnvironment).environment.fog_enabled = false
	camera = Camera3D.new()
	camera.fov = 40
	preview_root.add_child(camera)
	title_label = Main.title_label("", 20)
	right.add_child(title_label)
	info_label = Main.note_label("")
	right.add_child(info_label)
	var buttons := HBoxContainer.new()
	right.add_child(buttons)
	use_button = Button.new()
	use_button.text = "Use this model"
	use_button.disabled = true
	use_button.pressed.connect(_use)
	buttons.add_child(use_button)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(hide)
	buttons.add_child(cancel)
	about_to_popup.connect(func():
		for i in category.item_count:
			if category.get_item_metadata(i) == only_category:
				category.select(i)
		refresh())


func _process(delta: float) -> void:
	if holder and visible:
		holder.rotation.y += delta * 0.6


func refresh() -> void:
	list.clear()
	var want: String = category.get_item_metadata(category.selected) if category.selected >= 0 else ""
	var words := search.text.to_lower().split(" ", false)
	category.visible = not levels_mode
	named_only.visible = not levels_mode
	if levels_mode:
		for lvl in Rom.catalog.get("scenes", []):
			var label := "%d: %s" % [lvl.index, lvl.name]
			var ok_level := true
			for w in words:
				if not w in label.to_lower():
					ok_level = false
			if ok_level:
				list.add_item(label)
				list.set_item_metadata(list.item_count - 1, lvl.id)
				list.set_item_tooltip(list.item_count - 1, "%s · %d faces%s" % [lvl.id, lvl.get("faces", 0),
						"" if lvl.get("reviewed", false) else " · complete, unreviewed: may include stray or untextured pieces"])
				if lvl.id == selected_id:
					list.select(list.item_count - 1)
		return
	for m in Rom.catalog.get("models", []):
		if want != "" and m.category != want:
			continue
		if named_only.button_pressed and not m.get("named", false):
			continue
		var name_lower: String = m.name.to_lower()
		var ok := true
		for w in words:
			if not w in name_lower:
				ok = false
		if not ok:
			continue
		list.add_item(m.name + ("   ▶" if m.get("animations", 0) > 0 else ""))
		list.set_item_metadata(list.item_count - 1, m.id)
		list.set_item_tooltip(list.item_count - 1, "%s · %d faces%s" % [m.id, m.faces,
				(" · %d animations" % m.animations) if m.get("animations", 0) > 0 else ""])
		if m.id == selected_id:
			list.select(list.item_count - 1)


func _show(id: String) -> void:
	selected_id = id
	use_button.disabled = false
	if levels_mode:
		_show_level(id)
		return
	var m: Dictionary = Rom.models.get(id, {})
	title_label.text = m.get("name", id)
	info_label.text = "%s · %s · %d faces%s" % [Rom.categories().get(m.get("category"), ""), id, m.get("faces", 0),
			(" · %d animations" % m.animations) if m.get("animations", 0) > 0 else ""]
	if holder:
		holder.queue_free()
		holder = null
	var model := Rom.instance_model(id)
	if model == null:
		info_label.text += "\n(Couldn't load this model.)"
		return
	holder = Node3D.new()
	preview_root.add_child(holder)
	var fitted := Visuals.fit_model(model, {"size": Vector3(0.9, 1.8, 0.9)})
	holder.add_child(fitted.node)
	var box := Rom.aabb_of(holder) if not Rom.is_skinned(model) else AABB(Vector3(-0.6, 0, -0.6), Vector3(1.2, 1.8, 1.2))
	var radius: float = max(box.size.length() * 0.6, 0.5)
	var center := box.get_center()
	camera.position = center + Vector3(0, radius * 0.45, radius * 2.6)
	camera.look_at(center)
	camera.near = radius * 0.01
	camera.far = radius * 50.0


func _show_level(id: String) -> void:
	var lvl: Dictionary = Rom.scenes.get(id, {})
	title_label.text = "%d: %s" % [lvl.get("index", 0), lvl.get("name", id)]
	info_label.text = "%d faces · %s" % [lvl.get("faces", 0), "reviewed selection" if lvl.get("reviewed", false)
			else "every piece the ROM places here (unreviewed)"]
	if holder:
		holder.queue_free()
		holder = null
	var scene := Rom.instance_scene(id)
	if scene == null:
		info_label.text += "\n(Couldn't load this level.)"
		return
	holder = Node3D.new()
	preview_root.add_child(holder)
	scene.scale = Vector3.ONE * Rom.world_scale
	holder.add_child(scene)
	var box := Rom.aabb_of(holder)
	var radius: float = max(box.size.length() * 0.5, 1.0)
	var center := box.get_center()
	camera.position = center + Vector3(0, radius * 1.1, radius * 1.3)
	camera.look_at(center)
	camera.near = radius * 0.005
	camera.far = radius * 20.0


# Opens the browser to pick a whole level.
func pick_level(callback: Callable) -> void:
	levels_mode = true
	title = "Bad Fur Day levels from your ROM"
	use_button.text = "Build on this level"
	on_pick = callback
	popup_centered()


func _use() -> void:
	if selected_id == "":
		return
	chosen.emit(selected_id)
	if on_pick.is_valid():
		on_pick.call(selected_id)
	hide()


# Opens the browser for one choice.
func pick(category_key: String, callback: Callable) -> void:
	levels_mode = false
	title = "Models from your ROM"
	use_button.text = "Use this model"
	only_category = category_key
	on_pick = callback
	popup_centered()
