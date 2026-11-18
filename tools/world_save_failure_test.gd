extends SceneTree
const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var isolated := OS.get_environment("XDG_DATA_HOME")
	if OS.get_environment("MINING_QA_ISOLATED") != "1" or isolated.is_empty() or not OS.get_user_data_dir().begins_with(isolated + "/"):
		printerr("Requires a dedicated XDG_DATA_HOME and MINING_QA_ISOLATED=1; no files touched")
		quit(1)
		return
	if FileAccess.file_exists(Save.SAVE_PATH):
		printerr("Refusing to overwrite an existing test save")
		quit(1)
		return
	var g = Workshop.new()
	g.persistence_enabled = false
	root.add_child(g)
	g.set_process(false)
	g.state.gold = 123.0
	var original: String = g.export_save()
	var original_world = g.world
	var replacement: Dictionary = JSON.parse_string(original)
	replacement.state.gold = 999
	var protected_text := '{"version":99,"state":{"gold":1}}'
	var file := FileAccess.open(Save.SAVE_PATH, FileAccess.WRITE)
	if file == null:
		printerr("Cannot prepare isolated save")
		quit(1)
		return
	file.store_string(protected_text)
	file.close()
	g.persistence_enabled = true
	var rejected: bool = not g.import_save(JSON.stringify(replacement))
	var intact: bool = g.export_save() == original and g.world == original_world and g.World.current() == original_world
	var disk_intact: bool = FileAccess.get_file_as_string(Save.SAVE_PATH) == protected_text
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Save.SAVE_PATH))
	g.free()
	if rejected and intact and disk_intact:
		print("WORLD SAVE FAILURE PASS")
		quit(0)
	else:
		printerr("WORLD SAVE FAILURE FAIL ", [rejected, intact, disk_intact])
		quit(1)
