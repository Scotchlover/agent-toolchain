# End-to-end headless smoke test of the full causal loop:
# raid monastery -> church project -> hero expedition -> raid resolution ->
# persistent consequences -> save/load integrity.
extends Node

var main: Node3D
var phase := "boot"
var t := 0.0
var total_t := 0.0
var fails := 0
var checks := 0
var saw_party := false

func _ready() -> void:
	Engine.time_scale = 6.0   # Godot scales dt; test clocks must not multiply again
	var packed: PackedScene = load("res://game/main.tscn")
	main = packed.instantiate()
	add_child(main)
	GS.new_game(777)
	print("SMOKE: booting...")

func set_phase(p: String) -> void:
	phase = p
	print("PHASE-> ", p)
	t = 0.0


func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func _process(dt: float) -> void:
	t += dt
	total_t += dt
	if total_t > 900.0:
		ok(false, "smoke timed out at phase=%s" % phase)
		_finish()
		return
	match phase:
		"boot":
			if t > 1.0:
				ok(GS.minions_alive == 14, "horde mustered (14 minions)")
				ok(main.fortress.interactables.size() >= 10, "fortress semantics present (%d)" % main.fortress.interactables.size())
				ok(main.party == null, "no expedition at start")
				GS.raid_and_respond("monastery")
				ok(GS.world.has_project("HOLY_EXPEDITION"), "monastery raid provoked HOLY EXPEDITION")
				ok(GS.world.threat >= 20, "threat spiked")
				set_phase("wait_party")
				t = 0.0
		"wait_party":
			for p in GS.world.active_projects:
				p["progress"] += 8.0 * dt
			if main.party != null:
				ok(main.party.launched == 4, "expedition launched with 4 adventurers")
				set_phase("raid")
				t = 0.0
			elif t > 60.0:
				ok(false, "party never spawned")
				_finish()
		"raid":
			if main.party != null:
				saw_party = true
			elif saw_party:
				ok(GS.world.last_result.length() > 0, "world recorded result: %s" % GS.world.last_result)
				ok(GS.world.last_result.contains("STOLEN") or GS.world.last_result.contains("repelled"), "decisive outcome recorded")
				set_phase("post_raid")
				t = 0.0
			elif t > 300.0:
				ok(false, "raid never resolved")
				_dump_diagnostics()
				_finish()
		"post_raid":
			if t > 3.0 and not bool(get_meta("post_done", false)):
				set_meta("post_done", true)
				ok(Safe.gs().minions_alive == 14, "horde re-mustered after the raid")
				ok(main.party == null, "party cleaned up")
				# UI paths that only run when opened/cycled:
				main.world_map.toggle(true)
				ok(main.world_map.panel.visible, "world map opens")
				main.world_map.toggle(false)
				for m in [1, 2, 3]:
					main.debug_overlay.cycle(m)
					main.debug_overlay._process(0.0)
				main.debug_overlay.cycle(0)
				_test_save_load()
				_test_second_raid_adaptation()
		"raid2":
			if main.party != null:
				if not saw_party:
					saw_party = true
					ok(main.party.used_sally, "raid 2 entered via the crypt sally port")
			elif saw_party:
				ok(GS.world.last_result.length() > 0, "raid 2 resolved: %s" % GS.world.last_result)
				_finish()
			elif t > 300.0:
				ok(false, "raid 2 never resolved")
				_dump_diagnostics()
				_finish()

func _test_second_raid_adaptation() -> void:
	# NATURAL chain, no injection: raid 1's rogue sweeps the crypt, discovers
	# the sally port, and escapes. The world remembers without any test setup.
	var recipe := Expedition.make_recipe(Safe.gs().world, Safe.gs().domain, "HOLY_EXPEDITION")
	ok(recipe["entry_door"] == "sally_port",
		"adaptation: raid 2 plans sally route from natural scouting (got %s)" % recipe["entry_door"])
	main._spawn_expedition(recipe)
	set_phase("raid2")
	t = 0.0
func _test_save_load() -> void:
	var pre_threat := GS.world.threat
	var pre_gold := GS.world.gold
	ok(GS.save_game(), "save succeeds")
	GS.world.threat = 1
	GS.world.gold = 999999
	ok(GS.load_game(), "load succeeds")
	ok(GS.world.threat == pre_threat and GS.world.gold == pre_gold, "save/load roundtrip restores strategic truth")

func _dump_diagnostics() -> void:
	print("--- event log tail ---")
	for l in GS.log.lines(20):
		print(l)
	var p = main.party
	if p != null:
		print("--- party debug ---")
		print("state=", PartyController.P.keys()[p.state], " conf=", p.confidence, " route=", p.route.size())
		for h in p.members:
			if is_instance_valid(h):
				print("  ", h.def["label"], " hp=", h.hp, " goal=", h.move_goal, " pos=", h.global_position)

func _finish() -> void:
	set_process(false)
	print("---")
	print("SMOKE CHECKS=%d FAILS=%d" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)