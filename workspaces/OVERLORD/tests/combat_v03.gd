# v0.3 Combat 2.0 regression checks.
# Run: Godot --headless -s res://tests/combat_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_attack_grammar()
	test_dominion_contract()
	test_horde_empower_contract()
	print("---")
	print("COMBAT_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_attack_grammar() -> void:
	var normal: Dictionary = Sovereign.STANDARD_ATTACK
	var heavy: Dictionary = Sovereign.HEAVY_ATTACK
	ok(float(heavy["dmg"]) > float(normal["dmg"]), "combat: committed heavy deals more damage")
	ok(float(heavy["windup"]) > float(normal["windup"]), "combat: committed heavy demands more anticipation")
	ok(float(heavy["recover"]) > float(normal["recover"]), "combat: committed heavy has more recovery risk")
	ok(float(heavy["stagger"]) > float(normal["stagger"]), "combat: committed heavy is the stagger/guard-break tool")
	ok(float(normal["arc"]) > float(heavy["arc"]), "combat: sweep controls wider space than committed heavy")

func test_dominion_contract() -> void:
	ok(Sovereign.DOMINION_MAX == 100.0, "Dominion: bounded readable meter")
	ok(Sovereign.DREAD_COMMAND_COST > 0.0 and Sovereign.DREAD_COMMAND_COST < Sovereign.DOMINION_MAX,
		"Dominion: Dread Command is a real spend decision")
	ok(float(Sovereign.STANDARD_ATTACK["dominion"]) < float(Sovereign.HEAVY_ATTACK["dominion"]),
		"Dominion: riskier heavy hit earns more authority")

func test_horde_empower_contract() -> void:
	ok(Minion.EMPOWER_DMG > 1.0, "Horde: Dread Command increases damage")
	ok(Minion.EMPOWER_SPEED > 1.0, "Horde: Dread Command increases pressure/mobility")
	ok(Minion.EMPOWER_DMG < 1.6 and Minion.EMPOWER_SPEED < 1.35,
		"Horde: empowerment stays a synergy buff, not an auto-win multiplier")
