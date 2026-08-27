# E2E played outdoor raid (mandate §18.2) + Soul Bell upgrade (§18.3):
# march out → break militia → seize tribute → rewards applied → home again;
# then buy the Bell, verify Risen join the defense of an expedition.
extends Node

var main: Node3D
var phase := "boot"
var t := 0.0
var total_t := 0.0
var fails := 0
var checks := 0
var gold_before := 0
var hunt_t := 0.0
var saw_defense := false
var horde_before_bell := 0
var sovereign_hits := 0

func _ready() -> void:
	Engine.time_scale = 6.0
	var packed: PackedScene = load("res://game/main.tscn")
	main = packed.instantiate()
	add_child(main)
	GS.new_game(555)

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
	match phase:
		"boot":
			if t > 1.0:
				main.sovereign.max_hp = 1000000.0   # deterministic survival
				main.sovereign.hp = main.sovereign.max_hp
				if not main.sovereign.hit_landed.is_connected(_on_sovereign_hit):
					main.sovereign.hit_landed.connect(_on_sovereign_hit)
				GS.world.gold = 500
				gold_before = GS.world.gold
				main.start_outdoor_raid("village")
				ok(main.outdoor_region == "village", "marched out to the village")
				ok(main.militia_alive() == 9, "militia stands ready (9)")
				ok(main.village != null and main.village.chest_pos.z > 300.0, "village built off-map south")
				phase = "fight"
				t = 0.0
		"fight":
			hunt_t += dt
			if hunt_t > 1.5:
				hunt_t = 0.0
				var foe = main._nearest_enemy_actor()
				print("      HUNT t=%.0f foe=%s militia=%d sov_z=%.1f" % [t,
					("null" if foe == null else "ok"), main.militia_alive(),
					main.sovereign.global_position.z])
				main.horde.issue_hunt(foe)
				_sovereign_pressure(foe)
			if main.militia_alive() == 0 or main.outdoor_region == "":
				if main.outdoor_region != "":
					ok(true, "militia broken")
					main.sovereign.global_position = main.village.chest_pos + Vector3(0, 0.4, 1.0)
					var claimed: bool = main._outdoor_interact()
					ok(claimed, "tribute seized")
					_after_victory()
				elif phase == "fight":
					ok(false, "raid failed unexpectedly")
					_finish()
			elif t > 240.0:
				for g in get_tree().get_nodes_in_group("militia"):
					if is_instance_valid(g):
						print("      MILITIA dead=%s pos=%s hp=%.0f" % [str(g.dead), str((g as Node3D).global_position), g.hp])
				ok(false, "village fight stalled (%d militia left, horde=%d, sovereign_hits=%d)" % [
					main.militia_alive(), main.horde.total_alive(), sovereign_hits])
				for l in GS.log.lines(12):
					print(l)
				_finish()
		"bell":
			horde_before_bell = main.horde.total_alive()
			ok(GS.minions_alive == horde_before_bell,
				"horde count is truthful before Soul Bell (%d)" % horde_before_bell)
			GS.world.gold += 200
			main._buy_upgrade("soul_bell")
			ok(GS.domain.upgrades.has("soul_bell"), "Soul Bell installed")
			var recipe := Expedition.make_recipe(GS.world, GS.domain, "HOLY_EXPEDITION")
			main._spawn_expedition(recipe)
			phase = "defense"
			t = 0.0
		"defense":
			if main.party != null and not saw_defense:
				saw_defense = true
				var risen_found := false
				for cc in main.horde.cohorts:
					if cc.id == "risen" and cc.count_alive() == 3:
						risen_found = true
				ok(risen_found, "three Risen claw free of the crypt")
				ok(main.horde.total_alive() == horde_before_bell + 3,
					"Soul Bell adds exactly three defenders (%d -> %d)" % [
						horde_before_bell, main.horde.total_alive()])
				ok(GS.minions_alive == main.horde.total_alive(),
					"global Horde count matches physical actors (%d)" % GS.minions_alive)
				var lt_found := false
				for m in main.horde.cohorts[0].members:
					if is_instance_valid(m) and m.is_lieutenant:
						lt_found = true
				ok(lt_found, "a named lieutenant leads the bruisers")
				# Close the loop administratively, then prove sites generalize.
				main._on_party_resolved({"outcome": "test", "escaped_roles": [],
					"used_sally": false, "saw_trap": "", "relic_stolen": false})
				phase = "monastery"
				t = 0.0
		"monastery":
			if t > 1.0:
				ok(main.party == null, "prior expedition closed")
				main.start_outdoor_raid("monastery")
				ok(main.outdoor_region == "monastery", "monastery assault launches")
				ok(main.militia_alive() == 10, "Prior Anselm fields 9 brothers + captain")
				ok(absf(main.village.chest_pos.x - 400.0) < 1.0, "site built at its own origin")
				_finish()

func _on_sovereign_hit(victims: int) -> void:
	sovereign_hits += victims

func _sovereign_pressure(foe: Node) -> void:
	if foe == null or not is_instance_valid(foe) or not (foe is Node3D):
		return
	var target_pos := (foe as Node3D).global_position
	var to := target_pos - main.sovereign.global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		to = Vector3.FORWARD
	if to.length() > 3.0:
		main.sovereign.global_position = target_pos - to.normalized() * 2.4 + Vector3(0, 0.2, 0)
	var face := target_pos - main.sovereign.global_position
	face.y = 0.0
	if face.length_squared() > 0.01:
		main.sovereign.facing = face.normalized()
	main.sovereign.try_heavy_attack()

func _after_victory() -> void:
	ok(sovereign_hits > 0, "Sovereign personally contributed (%d heavy-hit victims)" % sovereign_hits)
	ok(main.outdoor_region == "", "returned to the fortress")
	ok(GS.world.gold == gold_before + 15, "tribute paid (+15 gold)")
	ok(GS.world.fear >= 10, "fear rose from the sack")
	ok(main.village == null, "village cleaned up")
	phase = "bell"
	t = 0.0

func _finish() -> void:
	set_process(false)
	print("---")
	print("VILLAGE CHECKS=%d FAILS=%d" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
