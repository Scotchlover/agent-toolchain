# Runtime compile gate for production scripts.
#
# Important: do NOT ResourceLoader.load every test script in one Godot process.
# Several tests are SceneTree/scene entrypoints; Godot 4.7.2 can crash in the
# resource loader when many such scripts are force-loaded with CACHE_MODE_IGNORE.
# CI checks test scripts in isolated --check-only processes instead.
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	var scripts: Array[String] = []
	_collect_scripts("res://game", scripts)
	scripts.sort()
	for path in scripts:
		checks += 1
		var resource := ResourceLoader.load(path)
		if resource == null:
			fails += 1
			print("FAIL  compile: " + path)
		else:
			print("PASS  compile: " + path)
	print("---")
	print("COMPILE_GAME CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func _collect_scripts(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		fails += 1
		print("FAIL  compile: cannot open " + path)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := path.path_join(name)
			if dir.current_is_dir():
				_collect_scripts(full, out)
			elif name.ends_with(".gd"):
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
