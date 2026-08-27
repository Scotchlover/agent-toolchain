# v0.3 party combat-intelligence contracts.
# Run: Godot --headless -s res://tests/combat_intelligence_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_doctrine_plans()
	test_heavy_telegraph_geometry()
	test_hero_directives()
	test_readable_objective_state()
	print("---")
	print("COMBAT_INTELLIGENCE_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_doctrine_plans() -> void:
	ok(PartyController.choose_combat_plan("strike", "steal_relic", true, false, 80.0)
			== "PRESS SOVEREIGN",
		"intelligence: Crown strike doctrine presses a nearby Sovereign")
	ok(PartyController.choose_combat_plan("retrieval", "steal_relic", true, false, 80.0)
			== "SCREEN OBJECTIVE",
		"intelligence: Guild retrieval does not become kill-Sovereign doctrine")
	ok(PartyController.choose_combat_plan("purge", "consecrate_crypt", false, false, 80.0)
			== "HOLD FORMATION",
		"intelligence: Church purge maintains formation around its specialist")
	ok(PartyController.choose_combat_plan("purge", "consecrate_crypt", true, true, 80.0)
			== "PROTECT BACKLINE",
		"intelligence: immediate threat to support line overrides doctrine")
	ok(PartyController.choose_combat_plan("strike", "steal_relic", true, false, 25.0)
			== "BREAK CONTACT",
		"intelligence: broken confidence overrides offensive plan")
	ok(PartyController.choose_combat_plan("purge", "kill_sovereign", true, false, 80.0)
			== "PRESS SOVEREIGN",
		"intelligence: explicit kill objective overrides normal purge posture")

func test_heavy_telegraph_geometry() -> void:
	var spec := Sovereign.HEAVY_ATTACK
	ok(Sovereign.attack_spec_threatens(Vector3.ZERO, Vector3(0, 0, -1),
			spec, Vector3(0, 0, -3.0)),
		"telegraph: point inside heavy arc is threatened")
	ok(not Sovereign.attack_spec_threatens(Vector3.ZERO, Vector3(0, 0, -1),
			spec, Vector3(3.0, 0, 0.0)),
		"telegraph: point outside heavy arc is not falsely threatened")
	ok(not Sovereign.attack_spec_threatens(Vector3.ZERO, Vector3(0, 0, -1),
			spec, Vector3(0, 0, -6.0)),
		"telegraph: point beyond heavy range is not threatened")
	var sov := Sovereign.new()
	sov._pending_attack = spec.duplicate()
	sov._windup_left = 0.5
	ok(sov.attack_intent_id() == "committed_heavy",
		"telegraph: current heavy intent is externally readable")
	sov._windup_left = 0.0
	ok(not sov.is_winding_attack(),
		"telegraph: no predictive dodge after windup has ended")
	sov.free()

func test_hero_directives() -> void:
	var rogue := Hero.new()
	rogue.setup("rogue", 1.0)
	rogue.set_combat_directive("flank", null, Vector3(2, 0, 1), 0.8)
	ok(rogue.combat_directive == "flank" and rogue.combat_anchor == Vector3(2, 0, 1),
		"intelligence: party can assign a short-lived semantic flank intent")
	rogue.grant_retreat_haste(5.0)
	rogue.set_combat_directive("retreat", null, Vector3.ZERO, 0.8)
	ok(rogue.combat_directive == "retreat" and rogue.retreat_haste_left == 5.0,
		"intelligence: retreat is a semantic directive with explicit cover window")
	ok(rogue.resource("smoke") == 1,
		"intelligence: controller does not silently consume Rogue resources")
	rogue.free()

func test_readable_objective_state() -> void:
	var p := PartyController.new()
	p.doctrine = "purge"
	p.objective = "consecrate_crypt"
	p.combat_plan = "EXECUTE OBJECTIVE"
	p.confidence = 52.0
	ok(p.current_objective_label() == "CONSECRATE SOUL BELL",
		"readability: semantic objective has player-facing label")
	ok(p.confidence_band() == "PRESSURED",
		"readability: exact confidence becomes qualitative state")
	var line := p.player_status_line()
	ok(line.contains("PURGE") and line.contains("CONSECRATE SOUL BELL")
			and line.contains("PRESSURED"),
		"readability: HUD summary exposes doctrine, objective and confidence")
	p.free()
