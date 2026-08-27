# Combat-focused integration scenario:
# prepared defenses (trap + dropped portcullis) -> breach -> hunt -> melee ->
# confidence collapse -> organized retreat under fire.
extends Node

var main: Node3D
var phase := "boot"
var t := 0.0
var total_t := 0.0
var fails := 0
var checks := 0
var saw_party := false
var saw_breach := false
var deaths_at_start := 0
var horde_alive_start := 0
var min_horde_alive := 999

func _ready() -> void:
	Engine.time_scale = 6.0
	var packed: PackedScene = load("res://game/main.tscn")
	main = packed.instantiate()
	add_child(main)
	GS.new_game(4242)

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
		ok(false, "timed out phase=%s" % phase)
		_finish()
		return
	for l in GS.log.entries:
		if String(l["msg"]).contains("forces the way open") or String(l["msg"]).contains("braces"):
			saw_breach = true
	match phase:
		"boot":
			if t > 1.0:
				# Preparation: park the warband mid-fortress, arm spikes,
				# drop the portcullis. The party must breach their way in.
				main.sovereign.global_position = Vector3(0, 0.5, 8.5)   # great hall
				GS.domain.traps_armed["great_hall_spikes"] = true
				main.fortress.set_trap_armed("great_hall_spikes", true)
				var gate = main.fortress.interactables["gate_portcullis"]
				gate["target_y"] = gate["lowered_y"]
				gate["body"].position.y = gate["lowered_y"]
				var recipe := Expedition.make_recipe(GS.world, GS.domain, "HOLY_EXPEDITION")
				main._spawn_expedition(recipe)
				phase = "fight"
				t = 0.0
		"fight":
			if main.party != null:
				if not saw_party:
					saw_party = true
					deaths_at_start = _dead_heroes()
					horde_alive_start = main.horde.total_alive()
					min_horde_alive = horde_alive_start
					print("      party spawned, hunting begins")
				_sample_horde_losses()
				if t > 2.0:
					for cc in main.horde.cohorts:
						for h in main.party.live_members():
							cc.command_hunt(h)
							break
						break   # bruisers hunt; skitterers follow orders too below
					for h in main.party.live_members():
						main.horde.issue_hunt(h)
						break
					phase = "melee"
					t = 0.0
		"melee":
			_sample_horde_losses()
			var p = main.party
			if p == null and saw_party:
				_resolve_checks()
			elif t > 240.0:
				ok(false, "battle unresolved")
				_dump()
				_finish()

func _sample_horde_losses() -> void:
	if main == null or main.horde == null:
		return
	min_horde_alive = mini(min_horde_alive, main.horde.total_alive())

func _dead_heroes() -> int:
	var n := 0
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if is_instance_valid(h) and h.down:
			n += 1
	return n

func _resolve_checks() -> void:
	ok(saw_breach, "party breached the dropped portcullis")
	var result := GS.world.last_result
	ok(result.length() > 0, "battle resolved: %s" % result)
	ok(_dead_heroes() > 0 or result.contains("repelled"), "horde drew blood (%d dead)" % _dead_heroes())
	ok(min_horde_alive < horde_alive_start,
		"horde paid during combat (minimum %d/%d)" % [min_horde_alive, horde_alive_start])
	ok(GS.minions_alive == 14 and main.horde.total_alive() == 14,
		"horde remustered after raid (%d)" % GS.minions_alive)
	var gate: Dictionary = main.fortress.interactables["gate_portcullis"]
	var gate_y: float = float(gate["body"].position.y)
	ok(gate_y >= float(gate["lowered_y"]) - 0.1 and gate_y <= float(gate["raised_y"]) + 0.1,
		"gate body remains within authored travel (%.1f)" % gate_y)
	_finish()

func _dump() -> void:
	for l in GS.log.lines(25):
		print(l)
	if main.party != null:
		print("party state=", PartyController.P.keys()[main.party.state], " conf=", main.party.confidence)
		for h in main.party.members:
			if is_instance_valid(h):
				print("  HERO ", h.def["label"], " hp=", int(h.hp), " pos=", h.global_position,
					" staggered=", h.staggered > 0.0, " pinned=", h.pinned)
	var i := 0
	for cc in main.horde.cohorts:
		for m in cc.members:
			if is_instance_valid(m) and i < 6:
				i += 1
				var tgt := "none"
				if m.combat_target != null and is_instance_valid(m.combat_target):
					tgt = String(m.combat_target.def["label"]) if m.combat_target is Hero else "sov"
				print("  MINION ", m.type_id, " state=", Minion.S.keys()[m.state],
					" pos=", m.global_position.snapped(Vector3(0.1, 0.1, 0.1)),
					" tgt=", tgt, " cd=", snapped(m.attack_cd, 0.1),
					" slotdist=", snapped(m.slot_pos.distance_to(m.global_position), 0.1))

func _finish() -> void:
	set_process(false)
	print("---")
	print("BATTLE CHECKS=%d FAILS=%d" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
