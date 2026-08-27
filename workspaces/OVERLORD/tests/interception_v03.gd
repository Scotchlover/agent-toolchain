# v0.3 interception end-to-end state contracts.
# Run: Godot --headless -s res://tests/interception_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_pause_continue_and_persistence()
	test_abort_removes_expedition()
	test_load_recovers_transient_stage()
	print("---")
	print("INTERCEPTION_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func make_approaching_world() -> Dictionary:
	var w := WorldState.new(303)
	var d := DomainState.new()
	var recipe := Expedition.make_recipe(w, d, "HOLY_EXPEDITION")
	var e := w.launch_expedition(recipe)
	e["stage"] = "approach"
	e["approach_left"] = 30.0
	e["leg_index"] = e["route"].size() - 1
	return {"world": w, "expedition": e}

func test_pause_continue_and_persistence() -> void:
	var setup := make_approaching_world()
	var w: WorldState = setup["world"]
	var e: Dictionary = setup["expedition"]
	var id := str(e["id"])
	var started := w.begin_interception(id)
	ok(not started.is_empty() and str(started["stage"]) == "intercepting",
		"interception: approach becomes explicit transient stage")
	w.tick_expeditions(90.0)
	ok(str(w.get_expedition(id)["stage"]) == "intercepting",
		"interception: strategic journey pauses while physical battle runs")
	var survivors := [
		{"role":"paladin","quality":1.2,"hp_frac":0.41,
			"resources":{"holy_guard":0,"challenge":1}},
		{"role":"cleric","quality":1.1,"hp_frac":0.63,
			"resources":{"major_heal":1,"consecration":2}},
	]
	var result := w.resolve_interception(id, "continued", survivors)
	ok(not bool(result["cancelled"]), "interception: surviving force continues")
	var resumed := w.get_expedition(id)
	ok(str(resumed["stage"]) == "approach" and float(resumed["approach_left"]) == 13.0,
		"interception: survivors resume a short fortress approach")
	var roles: Array = resumed["recipe"]["roles"]
	ok(roles.size() == 2, "interception: casualties persist into fortress recipe")
	ok(absf(float(roles[0]["hp_frac"]) - 0.41) < 0.001,
		"interception: survivor HP persists")
	ok(int(roles[1]["resources"]["major_heal"]) == 1,
		"interception: spent hero resources persist")
	ok(w.begin_interception(id).is_empty(),
		"interception: same expedition cannot be farmed with repeated interceptions")
	var saw_arrival := false
	for ev in w.tick_expeditions(14.0):
		if ev["type"] == "arrived": saw_arrival = true
	ok(saw_arrival, "interception: same battered expedition later reaches fortress")

func test_abort_removes_expedition() -> void:
	var setup := make_approaching_world()
	var w: WorldState = setup["world"]
	var e: Dictionary = setup["expedition"]
	var id := str(e["id"])
	w.begin_interception(id)
	var before := w.expeditions_resolved
	var result := w.resolve_interception(id, "aborted", [
		{"role":"rogue","quality":1.0,"hp_frac":0.2,"resources":{"tools":0,"smoke":0}}
	])
	ok(bool(result["cancelled"]), "interception: broken expedition cancels raid")
	ok(w.get_expedition(id).is_empty(), "interception: cancelled force leaves strategic list")
	ok(w.expeditions_resolved == before + 1, "interception: strategic resolution counter advances")

func test_load_recovers_transient_stage() -> void:
	var setup := make_approaching_world()
	var w: WorldState = setup["world"]
	var e: Dictionary = setup["expedition"]
	w.begin_interception(str(e["id"]))
	var saved := w.to_dict()
	var restored := WorldState.new(1)
	restored.from_dict(saved)
	ok(restored.active_expeditions.size() == 1, "interception: save keeps expedition")
	ok(str(restored.active_expeditions[0]["stage"]) == "approach",
		"interception: load cannot softlock in transient tactical stage")
	ok(float(restored.active_expeditions[0]["approach_left"]) >= 13.0,
		"interception: recovered force gives player reaction time")
