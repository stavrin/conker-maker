# Events: "When <something happens>, do <these things>". The no-code scripting of Conker Maker.
extends VBoxContainer

signal before_change

var level := {}
var list: VBoxContainer


func _ready() -> void:
	var bar := HBoxContainer.new()
	add_child(bar)
	var title := Label.new()
	title.text = "Events: when something happens in this level, do things."
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	var add := Button.new()
	add.text = "+ New event"
	add.pressed.connect(_add_event)
	bar.add_child(add)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)


func show_level(new_level: Dictionary) -> void:
	level = new_level
	if not level.has("events"):
		level.events = []
	rebuild()


func rebuild() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	for event in level.events:
		list.add_child(_event_row(event))


func _add_event() -> void:
	before_change.emit()
	var n: int = level.events.size() + 1
	level.events.append({"id": "e%d_%d" % [n, Time.get_ticks_msec() % 10000], "name": "Event %d" % n,
			"when": {"type": "level_start"}, "do": [{"type": "say", "speaker": "Conker", "text": "..."}]})
	rebuild()


func _event_row(event: Dictionary) -> Control:
	var triggers: Dictionary = App.catalog.events.triggers
	var actions: Dictionary = App.catalog.events.actions
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	panel.add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var name_edit := LineEdit.new()
	name_edit.text = event.get("name", "")
	name_edit.custom_minimum_size = Vector2(160, 0)
	name_edit.text_changed.connect(func(t): event.name = t)
	head.add_child(name_edit)
	var when := OptionButton.new()
	for key in triggers:
		when.add_item(triggers[key].label)
		when.set_item_metadata(when.item_count - 1, key)
		if key == event.when.type:
			when.select(when.item_count - 1)
	when.item_selected.connect(func(i):
		before_change.emit()
		event.when = {"type": when.get_item_metadata(i)}
		rebuild())
	head.add_child(when)
	var needs = triggers.get(event.when.type, {}).get("object", false)
	if needs:
		head.add_child(_object_picker(event.when.get("object", ""), needs, func(uid): event.when.object = uid))
	var cine := CheckBox.new()
	cine.text = "Cutscene"
	cine.tooltip_text = "Play this event as a cutscene: black bars, Conker waits, cameras can take over\n(\"Cutscene: cut to a camera\"), and Tab skips it."
	cine.button_pressed = bool(event.get("cutscene", false))
	cine.toggled.connect(func(on): before_change.emit(); event.cutscene = on)
	head.add_child(cine)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var remove := Button.new()
	remove.text = "Delete event"
	remove.pressed.connect(func(): before_change.emit(); level.events.erase(event); rebuild())
	head.add_child(remove)

	var conditions: Dictionary = App.catalog.events.get("conditions", {})
	for condition in event.get("only_if", []):
		var crow := HBoxContainer.new()
		box.add_child(crow)
		var only := Label.new()
		only.text = "    only if"
		crow.add_child(only)
		var ckind := OptionButton.new()
		for key in conditions:
			ckind.add_item(conditions[key].label)
			ckind.set_item_metadata(ckind.item_count - 1, key)
			if key == condition.get("type"):
				ckind.select(ckind.item_count - 1)
		ckind.item_selected.connect(func(i):
			before_change.emit()
			condition.clear()
			condition.type = ckind.get_item_metadata(i)
			rebuild())
		crow.add_child(ckind)
		var cfields: Dictionary = conditions.get(condition.get("type"), {}).get("fields", {})
		for field in cfields:
			crow.add_child(_field(condition, field, cfields[field]))
		var cx := Button.new()
		cx.text = "✕"
		cx.pressed.connect(func(): before_change.emit(); event.only_if.erase(condition); rebuild())
		crow.add_child(cx)

	for action in event.get("do", []):
		var row := HBoxContainer.new()
		box.add_child(row)
		var arrow := Label.new()
		arrow.text = "    then"
		row.add_child(arrow)
		var kind := OptionButton.new()
		for key in actions:
			kind.add_item(actions[key].label)
			kind.set_item_metadata(kind.item_count - 1, key)
			if key == action.type:
				kind.select(kind.item_count - 1)
		kind.item_selected.connect(func(i):
			before_change.emit()
			action.clear()
			action.type = kind.get_item_metadata(i)
			rebuild())
		row.add_child(kind)
		var fields: Dictionary = actions.get(action.type, {}).get("fields", {})
		for field in fields:
			row.add_child(_field(action, field, fields[field]))
		var up := Button.new()
		up.text = "↑"
		up.pressed.connect(func():
			var i: int = event.do.find(action)
			if i > 0:
				before_change.emit()
				event.do.remove_at(i)
				event.do.insert(i - 1, action)
				rebuild())
		row.add_child(up)
		var x := Button.new()
		x.text = "✕"
		x.pressed.connect(func(): before_change.emit(); event.do.erase(action); rebuild())
		row.add_child(x)
	var add_action := Button.new()
	add_action.text = "+ then do something else"
	add_action.pressed.connect(func():
		before_change.emit()
		event.do.append({"type": "say", "speaker": "Conker", "text": ""})
		rebuild())
	var adds := HBoxContainer.new()
	box.add_child(adds)
	adds.add_child(add_action)
	var add_condition := Button.new()
	add_condition.text = "+ only if..."
	add_condition.tooltip_text = "Only run this event when something's true, e.g. Conker has 30 cash.\nOn \"After Conker talks to\", an event whose conditions are met replaces their usual lines."
	add_condition.pressed.connect(func():
		before_change.emit()
		if not event.has("only_if"):
			event.only_if = []
		event.only_if.append({"type": "cash_at_least", "amount": 10})
		rebuild())
	adds.add_child(add_condition)
	return panel


func _field(action: Dictionary, field: String, kind: String) -> Control:
	match kind:
		"music":
			return Rom.music_picker(int(action.get(field, 0)), func(index): action[field] = index)
		"object":
			return _object_picker(action.get(field, ""), "", func(uid): action[field] = uid)
		"who":   # an object, or Conker himself
			return _object_picker(action.get(field, ""), "", func(uid): action[field] = uid, true)
		"camera":
			return _object_picker(action.get(field, ""), "camera", func(uid): action[field] = uid)
		"level":
			var option := OptionButton.new()
			option.add_item("(level)")
			option.set_item_metadata(0, "")
			for id in App.level_ids():
				option.add_item(App.levels[id].get("title", id))
				option.set_item_metadata(option.item_count - 1, id)
				if id == action.get(field):
					option.select(option.item_count - 1)
			option.item_selected.connect(func(i): action[field] = option.get_item_metadata(i))
			return option
		"int", "float":
			var spin := SpinBox.new()
			spin.min_value = 0
			spin.max_value = 9999
			spin.step = 1 if kind == "int" else 0.1
			spin.value = float(action.get(field, 0))
			spin.prefix = field
			spin.value_changed.connect(func(v): action[field] = int(v) if kind == "int" else v)
			return spin
		_:
			var line := LineEdit.new()
			line.placeholder_text = field
			line.text = str(action.get(field, ""))
			line.custom_minimum_size = Vector2(120 if field != "text" else 360, 0)
			line.text_changed.connect(func(t): action[field] = t)
			return line


# A dropdown of this level's objects, optionally only of one type.
func _object_picker(current: String, only_type, on_pick: Callable, with_conker := false) -> OptionButton:
	var option := OptionButton.new()
	option.add_item("(choose)")
	option.set_item_metadata(0, "")
	if with_conker:
		option.add_item("Conker")
		option.set_item_metadata(option.item_count - 1, "conker")
		if current == "conker":
			option.select(option.item_count - 1)
	for obj in level.get("objects", []):
		if only_type and obj.type != only_type:
			continue
		option.add_item(obj.uid)
		option.set_item_metadata(option.item_count - 1, obj.uid)
		if obj.uid == current:
			option.select(option.item_count - 1)
	option.item_selected.connect(func(i): on_pick.call(option.get_item_metadata(i)))
	return option
