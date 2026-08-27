# v0.3 strategic expedition journey regression checks.
# Run: Godot --headless -s res://tests/expedition_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_routes()
	test_persistent_journey()
	print("---")
	print("EXPEDITION_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_routes() -> void:
	var church := ExpeditionJourney.route_for_faction("church")
	var crown := ExpeditionJourney.route_for_faction("crown")
	var guild := ExpeditionJourney.route_for_faction("guild")
	ok(church.front() == "holy_see" and church.back() == "dark_domain", "journey: Church marches Holy See -> Domain")
	ok(crown.front() == "barony" and crown.back() == "dark_domain", "journey: Crown marches Barony -> Domain")
	ok(guild.front() == "guild" and guild.back() == "dark_domain", "journey: Guild contract has a real route to Domain")
	ok(church.size() >= 3, "journey: Church crosses intermediate territory")

func test_persistent_journey() -> void:
	var w := WorldState.new(77)
	var d := DomainState.new()
	var recipe := Expedition.make_recipe(w, d, "HOLY_EXPEDITION")
	var e := w.launch_expedition(recipe)
	ok(w.active_expeditions.size() == 1, "journey: launch creates persistent state")
	ok(str(e["stage"]) == "travelling", "journey: expedition begins travelling, not at fortress")
	ok(ExpeditionJourney.eta_seconds(e) > ExpeditionJourney.DOMAIN_APPROACH_DURATION, "journey: ETA includes map travel")
	var events: Array = []
	for i in range(200):
		events.append_array(w.tick_expeditions(1.0))
		if w.active_expeditions.is_empty():
			break
	var saw_domain := false
	var saw_arrival := false
	for ev in events:
		if ev["type"] == "domain_entered": saw_domain = true
		if ev["type"] == "arrived": saw_arrival = true
	ok(saw_domain, "journey: emits explicit domain-entry warning stage")
	ok(saw_arrival, "journey: reaches fortress only after travel+approach")
	ok(w.active_expeditions.is_empty(), "journey: arrived state leaves strategic travel list")
