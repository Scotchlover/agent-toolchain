# v0.3 persistence / consequence contracts.
# Run: Godot --headless -s res://tests/persistence_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_named_hero_lifecycle()
	test_capture_rescue_chain()
	test_save_migration()
	test_hostile_cycle_ledger()
	print("---")
	print("PERSISTENCE_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_named_hero_lifecycle() -> void:
	var w := WorldState.new(701)
	var d := DomainState.new()
	var named := w.available_named_hero("church", "paladin")
	ok(not named.is_empty() and named["id"] == "sir_aldric",
		"persistence: canonical named Paladin starts available")
	var recipe := Expedition.make_recipe(w, d, "HOLY_EXPEDITION")
	var named_roles := w.named_ids_from_roles(recipe["roles"])
	ok(named_roles == ["sir_aldric"],
		"persistence: Church expedition embeds the named hero identity")
	w.launch_expedition(recipe)
	ok(w.hero_roster["sir_aldric"]["status"] == "deployed",
		"persistence: journey marks named hero deployed")
	ok(int(w.hero_roster["sir_aldric"]["encounters"]) == 1,
		"persistence: deployment increments encounter history")
	w.note_named_hero_escape("sir_aldric")
	var escaped: Dictionary = w.hero_roster["sir_aldric"]
	ok(escaped["status"] == "free" and int(escaped["escapes"]) == 1,
		"persistence: escaped named hero becomes available again")
	ok(escaped["traits"].has("survived_dark_domain"),
		"persistence: event-derived survivor trait is recorded")

func test_capture_rescue_chain() -> void:
	var w := WorldState.new(703)
	var d := DomainState.new()
	var h := w.capture_named_hero("sir_aldric")
	ok(h["status"] == "captive" and w.captives == ["sir_aldric"],
		"capture: named hero enters persistent captive list")
	ok(w.first_captive("church")["id"] == "sir_aldric",
		"capture: faction can identify its captive")
	w.tick(7.0)
	ok(WorldResponseSystem.evaluate(w).is_empty(),
		"rescue: no instant project before the dramatic delay")
	w.tick(2.0)
	var response := WorldResponseSystem.evaluate(w)
	ok(response.size() == 1 and w.has_project("RESCUE_MARTYR"),
		"rescue: capture autonomously provokes Church rescue project")
	var done := w.tick_projects(float(Defs.ENEMY_PROJECTS["RESCUE_MARTYR"]["duration"]))
	var recipes := WorldResponseSystem.consume_completed(w, d, done)
	ok(recipes.size() == 1 and recipes[0]["rescue_target"] == "sir_aldric",
		"rescue: expedition recipe targets the actual prisoner")
	ok(w.named_ids_from_roles(recipes[0]["roles"]).is_empty(),
		"rescue: captive hero cannot simultaneously deploy in own rescue party")
	w.release_named_hero("sir_aldric")
	ok(w.captives.is_empty() and w.hero_roster["sir_aldric"]["status"] == "free",
		"rescue: release returns the named hero to the free roster")

func test_save_migration() -> void:
	var w := WorldState.new(705)
	w.capture_named_hero("sir_aldric")
	w.sovereign_deaths = 3
	var saved := w.to_dict()
	var restored := WorldState.new(1)
	restored.from_dict(saved)
	ok(restored.captives == ["sir_aldric"],
		"save: captive list round-trips")
	ok(restored.hero_roster["sir_aldric"]["status"] == "captive",
		"save: named hero state round-trips")
	ok(restored.sovereign_deaths == 3,
		"save: Sovereign death history round-trips")

	# Migration contract: a v0.2-style save without hero fields must gain the
	# canonical roster rather than crashing or permanently losing the feature.
	saved.erase("hero_roster")
	saved.erase("captives")
	saved.erase("sovereign_deaths")
	var migrated := WorldState.new(2)
	migrated.from_dict(saved)
	ok(not migrated.available_named_hero("church", "paladin").is_empty(),
		"save: old saves auto-seed missing named hero roster")

func test_hostile_cycle_ledger() -> void:
	var w := WorldState.new(707)
	var d := DomainState.new()
	w.do_raid("monastery")
	var first := WorldResponseSystem.evaluate(w)
	ok(first.size() == 1 and int(w.project_counts["HOLY_EXPEDITION"]) == 1,
		"cycle: first monastery raid starts exactly one Holy response")
	var done := w.tick_projects(float(Defs.ENEMY_PROJECTS["HOLY_EXPEDITION"]["duration"]))
	var recipe: Dictionary = WorldResponseSystem.consume_completed(w, d, done)[0]
	w.launch_expedition(recipe)
	w.do_raid("village")
	ok(WorldResponseSystem.evaluate(w).is_empty(),
		"cycle: unrelated raid cannot duplicate an expedition already in flight")

	# Simulate tactical resolution: old provocation is already accounted for.
	w.active_expeditions.clear()
	w.clear_hostile_cycle("HOLY_EXPEDITION")
	ok(WorldResponseSystem.evaluate(w).is_empty(),
		"cycle: resolved old provocation does not restart forever")

	w.do_raid("monastery")
	var second := WorldResponseSystem.evaluate(w)
	ok(second.size() == 1 and int(w.project_counts["HOLY_EXPEDITION"]) == 2,
		"cycle: a NEW monastery raid can provoke a new Holy response")

	# Generic provokes contract also covers the previously underused Holy See.
	var w2 := WorldState.new(709)
	w2.threat = 100
	w2.do_raid("holy_see")
	WorldResponseSystem.evaluate(w2)
	ok(w2.has_project("GRAND_CONSECRATION"),
		"cycle: Holy See provokes Grand Consecration through generic rule")
