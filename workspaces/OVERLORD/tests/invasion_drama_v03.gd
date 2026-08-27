# v0.3 invasion drama / raid progress contracts.
# Run: Godot --headless -s res://tests/invasion_drama_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_work_progress()
	test_penetration_depth()
	test_strategic_alerts()
	test_alarm_contract()
	print("---")
	print("INVASION_DRAMA_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_work_progress() -> void:
	var h := Hero.new()
	h.setup("cleric", 1.0)
	h.start_work(10.0, "consecrating", func(): pass)
	ok(absf(h.work_progress()) < 0.001,
		"drama: objective channel begins at zero progress")
	h.tick_work(2.5)
	ok(absf(h.work_progress() - 0.25) < 0.01,
		"drama: channel exposes real elapsed percentage")
	h.cancel_work()
	ok(h.work_progress() == 0.0,
		"drama: interrupted channel clears progress instead of lying to HUD")
	h.free()

func test_penetration_depth() -> void:
	var gate := PartyController.raid_depth_for_room("gatehouse")
	var hall := PartyController.raid_depth_for_room("great_hall")
	var wing := PartyController.raid_depth_for_room("crypt")
	var treasury := PartyController.raid_depth_for_room("treasury")
	var throne := PartyController.raid_depth_for_room("throne")
	ok(gate > 0.0 and gate < hall and hall < wing and wing < treasury and treasury < throne,
		"drama: authored room penetration is strictly monotonic")
	ok(throne == 1.0,
		"drama: throne room represents full fortress penetration")
	ok(PartyController.raid_depth_for_room("__outside__") == 0.0,
		"drama: outside approach is not falsely reported as an interior breach")

func test_strategic_alerts() -> void:
	var travelling := {
		"label": "Holy Expedition", "stage": "travelling",
		"route": ["holy_see", "dark_domain"], "leg_index": 0,
		"leg_duration": 8.0, "leg_progress": 2.0,
	}
	var approach := travelling.duplicate(true)
	approach["stage"] = "approach"
	approach["approach_left"] = 9.0
	var intercepting := approach.duplicate(true)
	intercepting["stage"] = "intercepting"
	var route_text := HUD.expedition_alert_text(travelling)
	var approach_text := HUD.expedition_alert_text(approach)
	var intercept_text := HUD.expedition_alert_text(intercepting)
	ok(route_text.contains("EN ROUTE") and route_text.contains("WAR TABLE"),
		"drama: travelling expedition tells player where to track it")
	ok(approach_text.contains("INSIDE YOUR DOMAIN") and approach_text.contains("INTERCEPT NOW"),
		"drama: Domain entry escalates to an explicit urgent warning")
	ok(intercept_text.contains("INTERCEPTION IN PROGRESS"),
		"drama: border battle has its own persistent alert state")
	var farther := travelling.duplicate(true)
	farther["label"] = "Crown Reprisal"
	farther["leg_progress"] = 0.0
	var nearest := HUD.nearest_expedition([farther, approach])
	ok(str(nearest["label"]) == "Holy Expedition",
		"drama: HUD selects the expedition with the shortest fortress ETA")

func test_alarm_contract() -> void:
	ok(FortressBuilder.alarm_energy(0) == 0.0,
		"drama: idle fortress alarm is dark")
	ok(FortressBuilder.alarm_energy(2) > FortressBuilder.alarm_energy(1),
		"drama: physical gate alarm escalates when raiders reach the fortress")
	var alarm := Sfx.stream("alarm")
	var breach := Sfx.stream("breach")
	ok(alarm != null and alarm.data.size() > 0,
		"drama: incoming-expedition horn is generated without binary assets")
	ok(breach != null and breach.data.size() > 0,
		"drama: room-breach impact cue is generated without binary assets")
