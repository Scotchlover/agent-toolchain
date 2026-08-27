# v0.3 Horde spacing / synergy contracts.
# Run: Godot --headless -s res://tests/horde_synergy_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_follow_clearance()
	test_combat_personal_space()
	test_role_target_priority()
	test_exposed_opening()
	print("---")
	print("HORDE_SYNERGY_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_follow_clearance() -> void:
	ok(CohortController.BUBBLE_RADIUS >= 3.0,
		"spacing: Sovereign owns a meaningful personal bubble")
	ok(CohortController.TRAIL_NEAR >= CohortController.BUBBLE_RADIUS + 0.5,
		"spacing: nearest FOLLOW envelope sits clearly outside the bubble")
	var sov := Vector3.ZERO
	var fwd := Vector3(0, 0, -1)
	var slot := sov + Vector3(0, 0, 1) * CohortController.TRAIL_NEAR
	ok(CohortController.follow_slot_is_valid(slot, sov, fwd),
		"spacing: trailing slot remains a valid FOLLOW position")
	ok(not CohortController.follow_slot_is_valid(sov + Vector3(0, 0, -3.5), sov, fwd),
		"spacing: a slot in front of the Sovereign is rejected")

func test_combat_personal_space() -> void:
	var sov := Vector3.ZERO
	var brute_push := Minion.sovereign_clearance_force(Vector3(1.0, 0, 0), sov, "brute")
	var skitter_push := Minion.sovereign_clearance_force(Vector3(1.0, 0, 0), sov, "skitterer")
	ok(brute_push.length() > 0.0,
		"spacing: Brute standing under the Sovereign receives soft repulsion")
	ok(skitter_push.length() > brute_push.length(),
		"spacing: smaller Skitterers preserve more combat clearance than Brutes")
	ok(Minion.sovereign_clearance_force(Vector3(4.0, 0, 0), sov, "skitterer") == Vector3.ZERO,
		"spacing: personal-space force disappears outside its local radius")

func test_role_target_priority() -> void:
	var normal_paladin := Minion.local_target_score("skitterer", "paladin", false, 2.0)
	var caster := Minion.local_target_score("skitterer", "wizard", false, 2.0)
	var exposed_paladin := Minion.local_target_score("skitterer", "paladin", true, 2.0)
	ok(caster > normal_paladin,
		"roles: Skitterer prefers a caster over an equally distant normal frontline")
	ok(exposed_paladin > caster,
		"roles: EXPOSED target becomes an even stronger Skitterer priority")
	var brute_front := Minion.local_target_score("brute", "paladin", false, 2.0)
	var brute_caster := Minion.local_target_score("brute", "wizard", false, 2.0)
	ok(brute_front > brute_caster,
		"roles: Brute prefers frontline pressure instead of copying Skitterer logic")

func test_exposed_opening() -> void:
	ok(absf(Minion.opening_damage_multiplier("skitterer", true) - 1.45) < 0.001,
		"synergy: Skitterer receives a bounded bonus against EXPOSED target")
	ok(Minion.opening_damage_multiplier("skitterer", false) == 1.0,
		"synergy: no free bonus without Sovereign-created opening")
	ok(Minion.opening_damage_multiplier("brute", true) == 1.0,
		"synergy: opening bonus is cohort-specific, not global DPS inflation")
	var hero := Hero.new()
	hero.setup("cleric", 1.0)
	hero.guard_broken_left = 2.0
	ok(hero.is_guard_broken(),
		"synergy: Hero exposes a short-lived queryable opening state")
	hero.free()
