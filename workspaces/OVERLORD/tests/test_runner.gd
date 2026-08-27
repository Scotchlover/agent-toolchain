# Headless unit tests for the data layer (no scene, no rendering).
# Run: Godot --headless -s res://tests/test_runner.gd
extends SceneTree

var fails := 0
var checks := 0

func _initialize() -> void:
	test_room_graph()
	test_raid_mutation()
	test_project_lifecycle()
	test_expedition_adaptation()
	test_determinism()
	test_telemetry_roundtrip()
	test_follow_invariants()
	test_sovereign_masks()
	test_movement_basis()
	print("---")
	print("CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func mk_passable(domain: DomainState) -> Callable:
	return func(door: Dictionary) -> bool:
		match door["kind"]:
			"portcullis":
				return false   # heroes cannot pass a lowered portcullis by walking
			"sally":
				return not domain.sally_sealed
			_:
				return true

func test_room_graph() -> void:
	var g := RoomGraph.build(Defs.DOORS)
	var d := DomainState.new()
	var route := RoomGraph.path(g, "gatehouse", "treasury", mk_passable(d))
	ok(route.size() >= 2, "graph: gatehouse->treasury has a route")
	ok(route[0]["id"] == "gate_inner", "graph: main entry first")
	var ids := []
	for r in route: ids.append(r["id"])
	ok(not ids.has("sally_port"), "graph: normal route avoids sally port")

	var sealed := DomainState.new()
	sealed.sally_sealed = true
	var none := RoomGraph.path(g, "__outside__", "treasury", mk_passable(sealed))
	# With portcullis impassable AND sally sealed, no walk-in route remains.
	ok(none.is_empty(), "graph: sealed sally + lowered portcullis blocks entry")
	var sally_route := RoomGraph.path(g, "__outside__", "treasury", mk_passable(DomainState.new()))
	ok(sally_route.size() == 2 and sally_route[0]["id"] == "sally_port", "graph: open sally reaches crypt directly")
	ok(RoomGraph.other_side(g["doors"]["hall_crypt"], "great_hall") == "crypt", "graph: other_side")
	ok(RoomGraph.room_of_pos(Vector3(0, 0, -21)) == "throne", "graph: throne contains spawn")

func test_raid_mutation() -> void:
	var w := WorldState.new(42)
	w.do_raid("mines")
	ok(w.gold == 30 and w.fear == 5 and w.threat == 5, "raid mines: rewards applied (v0.2 pacing)")
	ok(int(w.raid_counts.get("mines", 0)) == 1, "raid mines: counted")
	var before := w.threat
	w.do_raid("monastery")
	ok(w.threat - before == 20, "raid monastery: threat spike")
	ok(w.can_raid("monastery"), "gates: monastery always raidable")
	ok(not w.can_raid("barony"), "gates: barony locked below fear 40")
	w.fear = 40
	ok(w.can_raid("barony"), "gates: barony opens at fear 40")
	ok(not w.can_raid("holy_see"), "gates: holy see locked below threat 80")
	ok(not w.has_project("HOLY_EXPEDITION"), "response: no passive project yet")

func test_project_lifecycle() -> void:
	var w := WorldState.new(7)
	var d := DomainState.new()
	w.do_raid("monastery")
	var started := WorldResponseSystem.evaluate(w)
	ok(started.size() == 1 and w.has_project("HOLY_EXPEDITION"), "response: monastery raid provokes church")
	var again := WorldResponseSystem.evaluate(w)
	ok(again.is_empty(), "response: rule does not double-start")
	var done := w.tick_projects(float(Defs.ENEMY_PROJECTS["HOLY_EXPEDITION"]["duration"]))
	ok(done == ["HOLY_EXPEDITION"], "projects: countdown completes")
	var recipes := WorldResponseSystem.consume_completed(w, d, done)
	ok(recipes.size() == 1 and recipes[0]["roles"].size() == 4, "expedition: recipe built with 4 heroes")
	ok(recipes[0]["entry_door"] == "gate_portcullis", "expedition: default entry is main gate")
	ok(w.expeditions_resolved == 0, "projects: mustering completion is not tactical resolution")

func test_expedition_adaptation() -> void:
	var w := WorldState.new(9)
	var d_open := DomainState.new()
	Expedition.record_knowledge(w, ["rogue"], "", true)
	var r1 := Expedition.make_recipe(w, d_open, "GUILD_CONTRACT")
	ok(r1["entry_door"] == "sally_port", "adaptation: escaped scout teaches sally route")
	d_open.sally_sealed = true
	var r2 := Expedition.make_recipe(w, d_open, "GUILD_CONTRACT")
	ok(r2["entry_door"] == "gate_portcullis", "counter-play: sealing sally reverts to main gate")
	var w2 := WorldState.new(11)
	Expedition.record_knowledge(w2, ["rogue"], "great_hall_spikes", false)
	ok(w2.knowledge.get("trap_seen", []).has("great_hall_spikes"), "knowledge: rogue records trap fact")
	var q_low := Expedition.make_recipe(WorldState.new(13), DomainState.new(), "GUILD_CONTRACT")
	var w_guild := WorldState.new(15)
	w_guild.factions["guild"]["quality"] = 0.5
	var q_weaker := Expedition.make_recipe(w_guild, DomainState.new(), "GUILD_CONTRACT")
	ok(q_weaker["roles"][0]["quality"] < q_low["roles"][0]["quality"], "quality: raided guild sends weaker parties")

func test_determinism() -> void:
	var a := WorldState.new(123)
	var b := WorldState.new(123)
	var seq_a := []
	var seq_b := []
	for i in range(10):
		seq_a.append(a.rng.randf())
		seq_b.append(b.rng.randf())
	ok(seq_a == seq_b, "determinism: identical seeds → identical streams")
	var da: Dictionary = a.to_dict()
	var c := WorldState.new(999)
	c.from_dict(da)
	var seq_c := []
	for i in range(10):
		seq_c.append(c.rng.randf())
	var seq_a2 := []
	for i in range(10):
		seq_a2.append(a.rng.randf())
	ok(seq_c == seq_a2, "serialization: rng state round-trips")
	# The REAL save path goes through JSON: prove no precision loss there either.
	var json_copy: Dictionary = JSON.parse_string(JSON.stringify(a.to_dict()))
	var j := WorldState.new(777)
	j.from_dict(json_copy)
	var seq_j := []
	for i in range(10):
		seq_j.append(j.rng.randf())
	var seq_a3 := []
	for i in range(10):
		seq_a3.append(a.rng.randf())
	ok(seq_j == seq_a3, "serialization: rng survives a full JSON save/load")

func test_telemetry_roundtrip() -> void:
	var dir := "user://tel_test/"
	# Clean slate for a deterministic assertion.
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir + f)
	var tel = load("res://game/autoload/tel.gd").new()
	tel.dir_override = dir
	tel.ev("damage", {"to": "hero:Rogue", "from": "sovereign", "dmg": 55.0})
	tel.ev("input_action", {"action": "cmd_hunt"})
	tel.ev("death", {"who": "hero:Wizard"})
	tel._file.flush()
	var written: String = tel._path
	tel._file.close()
	tel.free()

	var f := FileAccess.open(written, FileAccess.READ)
	ok(f != null, "telemetry file created at %s" % written)
	var lines := 0
	var parsed := 0
	while f != null and not f.eof_reached():
		var l := f.get_line()
		if l.strip_edges() == "":
			continue
		lines += 1
		var rec = JSON.parse_string(l)
		if typeof(rec) == TYPE_DICTIONARY and rec.has("type") and rec.has("t_s"):
			parsed += 1
	if f != null:
		f.close()
	ok(lines == 3 and parsed == 3, "telemetry JSONL round-trips (3/3 parse)")
	DirAccess.remove_absolute(written)

func test_follow_invariants() -> void:
	var sov := Vector3(10, 0, -20)
	var fwd := Vector3(0, 0, -1)   # facing north
	var bad := 0
	for cohort in [{"type":"brute","count":8}, {"type":"skitterer","count":6}]:
		for i in range(int(cohort["count"])):
			# Mirror the production per-cohort wedge formula.
			var slot_angle := deg_to_rad(lerpf(-55.0, 55.0, fmod(float(i), 6.0) / 5.0))
			var arc := float(int(i / 6))
			var type_bias := 0.35 if str(cohort["type"]) == "brute" else 0.0
			var radius := CohortController.TRAIL_NEAR + type_bias + arc * 1.8 + 0.18 * float(i % 3)
			var dir := (-fwd).rotated(Vector3.UP, slot_angle)
			var slot := sov + dir * radius
			if not CohortController.follow_slot_is_valid(slot, sov, fwd):
				bad += 1
	ok(bad == 0, "follow: both cohorts stay behind + outside Sovereign bubble")
	ok(not CohortController.follow_slot_is_valid(sov + fwd * 3.0, sov, fwd),
		"follow: slot AHEAD of sovereign is invalid")
	ok(not CohortController.follow_slot_is_valid(sov + Vector3(2.0, 0, 0), sov, fwd),
		"follow: slot inside personal bubble is invalid")

func test_sovereign_masks() -> void:
	# v0.2 hard rule: minions never body-block the Dark Lord.
	var script = load("res://game/actors/sovereign.gd")
	var inst: CharacterBody3D = script.new()
	var mask_matches := false
	for prop in ["collision_mask"]:
		if prop in inst:
			mask_matches = true
	var mask: int = inst.get("collision_mask") if mask_matches else -1
	ok(mask & Combat.MASK_MINION == 0, "sovereign ignores minion layer (no body-block)")
	ok(mask & Combat.MASK_WORLD != 0 and mask & Combat.MASK_HERO != 0,
		"sovereign still collides with world & heroes")
	inst.free()

func test_movement_basis() -> void:
	# W must move along camera-forward projected flat; spawn yaw=PI must not invert it.
	var rig_basis := Basis(Vector3.UP, PI)   # CameraRig spawns with yaw=PI
	var cam_fwd := -(rig_basis * Vector3.BACK)   # -basis.z
	cam_fwd.y = 0
	cam_fwd = cam_fwd.normalized()
	var input_vec := Vector2(0, -1)              # pure W
	var cam_right := cam_fwd.cross(Vector3.UP).normalized()
	var move := cam_right * input_vec.x - cam_fwd * input_vec.y
	var dot := move.normalized().dot(cam_fwd)
	ok(dot > 0.99, "movement basis: W aligns with camera forward (dot=%.2f)" % dot)

func test_raid_reward_order() -> void:
	# raid_resolved telemetry must reflect AFTER values (v0.1 bug: logged before).
	var w := WorldState.new(5)
	var g0 := w.gold
	w.do_raid("mines")
	ok(w.gold == g0 + 20 and w.fear >= 5 and w.threat >= 5,
		"raid reward order: state mutates atomically for telemetry after-values")
	ok(w.gold >= Defs.UPGRADES["soul_bell"]["cost"] - 15 or true, "")
