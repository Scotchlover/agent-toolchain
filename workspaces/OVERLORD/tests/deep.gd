# Deep combat & edge-path coverage — systems earlier suites never exercised:
#   1. Sovereign heavy melee kills/wounds a hero directly ahead (arc damage)
#   2. Dread Wave damages + staggers heroes (executed in physics context)
#   3. EXECUTE finisher on a brute-pinned hero
#   4. Cleric heals a wounded ally
#   5. Wizard nova staggers swarming minions
#   6. Party trapped INSIDE by a dropped portcullis smashes its way out
extends Node

var main: Node3D
var phase := "boot"
var t := 0.0
var total_t := 0.0
var fails := 0
var checks := 0
var extra_minions: Array = []   # test-spawned bodies; freed before integration phases

func _spawn_extra_minion(type: String, pos: Vector3) -> Minion:
	var m := Minion.new()
	m.setup(type, "test", randi() % 10000)
	add_child(m)
	m.global_position = pos
	extra_minions.append(m)
	return m

func _ready() -> void:
	Engine.time_scale = 6.0
	_build_test_floor()
	var packed: PackedScene = load("res://game/main.tscn")
	main = packed.instantiate()
	add_child(main)
	GS.new_game(31337)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func _process(dt: float) -> void:
	# NOTE: _process dt already includes Engine.time_scale — accumulate once,
	# otherwise this clock runs 6x faster than the game's own timers.
	t += dt
	total_t += dt
	if total_t > 2000.0:
		ok(false, "timed out phase=%s" % phase)
		_finish()
		return
	match phase:
		"boot":
			if t > 1.0:
				main.sovereign.max_hp = 1000000.0
				main.sovereign.hp = main.sovereign.max_hp
				# Isolated arena far south so horde aggro cannot pollute results.
				main.sovereign.global_position = Vector3(0, 0.5, 336)
				var hero := _spawn_test_hero("paladin", Vector3(0, 0.6, 333.4), false)
				set_meta("hp_before", hero.hp)
				set_meta("victim", hero)
				main.sovereign.facing = Vector3(0, 0, -1)
				main.sovereign.try_heavy_attack()
				phase = "melee"
				t = 0.0
		"melee":
			var hero: Hero = get_meta("victim")
			var before: float = float(get_meta("hp_before"))
			if not is_instance_valid(hero) or hero.down or hero.hp <= before - 40.0:
				var dealt := before - (hero.hp if is_instance_valid(hero) else 0.0)
				ok(true, "sovereign committed heavy connects (%.0f damage)" % dealt)
				phase = "dreadwave"
				t = 0.0
			elif t > 4.0:
				ok(false, "melee arc never connected (hp %.0f/%.0f)" % [hero.hp, before])
				phase = "dreadwave"
				t = 0.0
		"dreadwave":
			if t > 0.2 and not bool(get_meta("dw_spawned", false)):
				set_meta("dw_spawned", true)
				var h1 := _spawn_test_hero("rogue",
					main.sovereign.global_position + Vector3(3, 0.1, 0), false)
				set_meta("dw_target", h1)
				set_meta("dw_before", h1.hp)
				phase = "dreadwave_wait"
				t = 0.0
		"dreadwave_wait":
			if t > 0.5:
				var h1: Hero = get_meta("dw_target")
				var before: float = float(get_meta("dw_before"))
				DreadWave.burst(get_tree(), main.sovereign.global_position, 7.0, 25.0,
					main.sovereign)
				var wounded: bool = (not is_instance_valid(h1)) or h1.down or h1.hp < before
				var staggered: bool = is_instance_valid(h1) and h1.staggered > 0.0
				ok(wounded, "dread wave wounds hero in radius")
				ok(staggered, "dread wave staggers hero")
				phase = "execute"
				t = 0.0
		"execute":
			if t > 0.3:
				var victim := _spawn_test_hero("wizard", Vector3(0, 0.6, -26))
				victim.pin_pressure = 5.0
				for off in [Vector3(1.0, 0, 0), Vector3(-1.0, 0, 0)]:
					_spawn_extra_minion("brute", victim.global_position + off)
				main.sovereign.global_position = victim.global_position + Vector3(0, 0, 2.0)
				set_meta("victim2", victim)
				phase = "exec_do"
				t = 0.0
		"exec_do":
			pass   # handled in _physics_process once pin settles
		"cleric":
			if t > 0.3:
				# Quiet arena: horde parked at the village entry, pair at the chest.
				main.sovereign.global_position = Vector3(0, 0.5, 344)
				main.horde.return_home(Vector3(0, 0.6, 346))
				var pally := _spawn_test_hero("paladin", Vector3(2, 0.6, 320))
				pally.hp = pally.max_hp * 0.3
				var cleric := _spawn_test_hero("cleric", Vector3(2.5, 0.6, 319))
				cleric.heal_cd = 0.0
				set_meta("wounded", pally)
				phase = "cleric_wait"
				t = 0.0
		"cleric_wait":
			if t > 3.5:
				var p: Hero = get_meta("wounded")
				if is_instance_valid(p):
					ok(p.hp > p.max_hp * 0.3, "cleric healed the paladin (%.0f/%.0f)" % [p.hp, p.max_hp])
				else:
					ok(false, "cleric target vanished")
				phase = "nova"
				t = 0.0
		"nova":
			if t > 0.3:
				var wiz := _spawn_test_hero("wizard", Vector3(0, 0.6, -17))
				wiz.nova_cd = 0.0
				set_meta("nova_at", Time.get_ticks_msec() + 900)
				set_meta("wiz", wiz)
				phase = "nova_wait"
				t = 0.0
		"nova_wait":
			var wiz2: Hero = get_meta("wiz")
			if is_instance_valid(wiz2):
				wiz2.nova_cd = 0.0   # keep the button hot for determinism
				if not bool(get_meta("minions_in", false)) and t > 0.3:
					set_meta("minions_in", true)
					for i in range(3):
						_spawn_extra_minion("skitterer", Vector3(float(i) * 0.8 - 0.8, 0.6, -17.8))
			if t > 1.6:
				var stunned := 0
				for m in extra_minions:
					if is_instance_valid(m) and m.stun_left > 0.0:
						stunned += 1
				ok(stunned >= 3, "wizard frost nova stunned minions (%d)" % stunned)
				phase = "trapped_prep"
				t = 0.0
		"trapped_prep":
			if t > 0.3:
				# Remove test bodies so the party fights only real defenders.
				for m in extra_minions:
					if is_instance_valid(m):
						m.queue_free()
				extra_minions.clear()
				main.horde.remuster(main)
				var recipe := Expedition.make_recipe(GS.world, GS.domain, "HOLY_EXPEDITION")
				main._spawn_expedition(recipe)
				phase = "trap_enter"
				t = 0.0
		"trap_enter":
			var p = main.party
			if p != null and p.state == PartyController.P.SCOUT:
				# They are INSIDE now: slam the gate behind them.
				var gate = main.fortress.interactables["gate_portcullis"]
				gate["target_y"] = gate["lowered_y"]
				gate["body"].position.y = gate["lowered_y"]
				GS.el("--- the trap snaps shut behind them ---")
				phase = "trap_out"
				t = 0.0
			elif t > 60.0:
				ok(false, "party never got inside")
				_finish()
		"trap_out":
			var p2 = main.party
			if p2 != null:
				var smashed := false
				for l in GS.log.entries:
					if String(l["msg"]).contains("smash their way out"):
						smashed = true
				if smashed:
					ok(true, "trapped party smashed its way back out!")
					_finish()
				# Second slam: once they turn to flee, drop the gate AGAIN.
				if p2.state == PartyController.P.RETREAT and bool(get_meta("reslam", false)) == false:
					set_meta("reslam", true)
					var gate2 = main.fortress.interactables["gate_portcullis"]
					gate2["target_y"] = gate2["lowered_y"]
					gate2["body"].position.y = gate2["lowered_y"]
					GS.el("--- reslammed behind the fleeing party ---")
			if t > 600.0:
				if p2 != null:
					print("      STATE party=%s conf=%.0f members=%d gate_target=%.1f" % [
						PartyController.P.keys()[p2.state], p2.confidence,
						p2.live_members().size(),
						float(main.fortress.interactables["gate_portcullis"]["target_y"])])
				ok(p2 != null and p2.resolved, "trapped raid resolved one way or another")
				_dump()
				_finish()
func _physics_process(_dt: float) -> void:
	if phase == "exec_do":
		var v: Hero = get_meta("victim2")
		if is_instance_valid(v) and v.pinned:
			main.sovereign.global_position = v.global_position + Vector3(0, 0, 2.0)
			main._do_execute()
			phase = "exec_check"
			t = 0.0
	if phase == "exec_check":
		var v2: Hero = get_meta("victim2")
		if t > 1.0:
			ok((not is_instance_valid(v2)) or v2.down or v2.hp < v2.max_hp,
				"EXECUTE crushed the pinned hero")
			phase = "cleric"
			t = 0.0

func _build_test_floor() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Combat.MASK_WORLD
	floor.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 0.4, 80.0)
	cs.shape = box
	cs.position = Vector3(0, -0.2, 335)
	floor.add_child(cs)
	add_child(floor)

func _spawn_test_hero(role: String, pos: Vector3, active_ai: bool = true) -> Hero:
	var h := Hero.new()
	h.setup(role, 1.0)
	# Keep combat fixtures in the exact same World3D hierarchy as production
	# actors. Isolated hit/ability probes freeze local Hero AI so a long
	# telegraph tests geometry/damage rather than autonomous locomotion.
	main.add_child(h)
	h.global_position = pos
	if not active_ai:
		h.set_physics_process(false)
	return h

func _dump() -> void:
	for l in GS.log.lines(15):
		print(l)

func _finish() -> void:
	set_process(false)
	set_physics_process(false)
	print("---")
	print("DEEP CHECKS=%d FAILS=%d" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)

