# GS — game session singleton. Owns persistent WorldState / DomainState and
# turns strategic simulation events into player-facing warnings.
extends Node

var world: WorldState
var domain: DomainState
var log: EventLog
var main: Node = null

var graph: Dictionary
var minions_alive := 0
var expedition_active := false
var _response_eval_left := 0.0
signal toast(msg: String)
signal expedition_requested(recipe: Dictionary)
signal banner(title: String, sub: String)

const SAVE_PATH := "user://overlord_save.json"

func _ready() -> void:
	_setup_input_map()
	new_game()

func new_game(p_seed: int = -1) -> void:
	world = WorldState.new(p_seed)
	domain = DomainState.new()
	log = EventLog.new()
	graph = RoomGraph.build(Defs.DOORS)
	minions_alive = 0
	_response_eval_left = 0.0
	log.add("The Dark Sovereign stirs. Seed %d." % world.seed_value)

func el(msg: String) -> void:
	log.add(msg)
	_append_log_file(msg)
	toast.emit(msg)

func _append_log_file(msg: String) -> void:
	var f := FileAccess.open("user://overlord_event_log.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://overlord_event_log.txt", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("[%s] %s" % [log.stamp(), msg])
	f.close()

func raid_and_respond(region_id: String) -> Array:
	var before := {"gold": world.gold, "fear": world.fear, "threat": world.threat}
	var lines := world.do_raid(region_id)
	for l in lines:
		el(l)
	TEL.ev("raid_reward", {"region": region_id,
		"gold_delta": world.gold - int(before["gold"]),
		"fear_delta": world.fear - int(before["fear"]),
		"threat_delta": world.threat - int(before["threat"])})
	var responses := WorldResponseSystem.evaluate(world)
	for r in responses:
		el(r)
	TEL.ev("raid_resolved", {"region": region_id, "before": before,
		"after": {"gold": world.gold, "fear": world.fear, "threat": world.threat}})
	return lines

func tick_world(dt: float) -> void:
	world.tick(dt)
	log.tick(dt)

	# The hostile world has its own pulse. Causal ledgers/cycle locks keep this
	# from duplicating old responses while allowing capture→rescue to happen
	# without requiring the player to perform another raid first.
	_response_eval_left -= dt
	if _response_eval_left <= 0.0:
		_response_eval_left = 1.0
		if not expedition_active:
			for r in WorldResponseSystem.evaluate(world):
				el(r)

	# Project completion creates an expedition JOURNEY, not a tactical spawn.
	var done := world.tick_projects(dt)
	if not done.is_empty():
		var recipes := WorldResponseSystem.consume_completed(world, domain, done)
		for recipe in recipes:
			var journey := world.launch_expedition(recipe)
			var def: Dictionary = Defs.ENEMY_PROJECTS[recipe["def_id"]]
			el("%s DEPARTS from %s." % [def["label"], Defs.REGIONS[str(journey["route"][0])]["label"]])
			banner.emit("A %s HAS DEPARTED" % str(def["label"]).to_upper(),
				"Track it on the War Table. ETA %ds." % ceili(ExpeditionJourney.eta_seconds(journey)))
			TEL.ev("expedition_departed", {"def_id": recipe["def_id"], "route": journey["route"],
				"eta": ExpeditionJourney.eta_seconds(journey)})

	# Strategic travel is visible and has escalating warning thresholds.
	for ev in world.tick_expeditions(dt):
		var e: Dictionary = ev["expedition"]
		var typ := str(ev["type"])
		match typ:
			"node_entered":
				var node_id := str(ev["node"])
				el("%s reaches %s." % [e["label"], Defs.REGIONS[node_id]["label"]])
				TEL.ev("expedition_node_entered", {"id": e["id"], "node": node_id,
					"eta": ExpeditionJourney.eta_seconds(e)})
			"domain_entered":
				banner.emit("⚠ %s HAS ENTERED YOUR DOMAIN" % str(e["label"]).to_upper(),
					"The outer watchfires are lit. The fortress is next.")
				el("ALARM: %s crosses into the Dark Domain." % e["label"])
				TEL.ev("domain_entered", {"id": e["id"], "approach": float(e["approach_left"])})
			"arrived":
				banner.emit("THE GATES ARE UNDER ATTACK", "%s has reached the fortress." % e["label"])
				el("THE GATES ARE UNDER ATTACK — %s arrives." % e["label"])
				TEL.ev("fortress_arrival", {"id": e["id"], "def_id": e["def_id"]})
				expedition_requested.emit(ev["recipe"])

func save_game() -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({
		"version": 2,
		"world": world.to_dict(),
		"domain": domain.to_dict(),
		"log": log.to_dict(),
	}))
	f.close()
	if TEL != null:
		TEL.ev("save_game", {})
	el("Game saved.")
	return true

func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY or not data.has("world"):
		return false
	new_game(int(data["world"].get("seed", -1)))
	world.from_dict(data["world"])
	domain.from_dict(data.get("domain", {}))
	log.from_dict(data.get("log", {}))
	expedition_active = false
	minions_alive = 0
	el("Game loaded (seed %d)." % world.seed_value)
	return true

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func _setup_input_map() -> void:
	_add_key_actions({
		"move_forward": [KEY_W], "move_back": [KEY_S],
		"move_left": [KEY_A], "move_right": [KEY_D],
		"execute": [KEY_F], "interact": [KEY_E],
		"heavy_attack": [KEY_Q], "brace": [KEY_SPACE], "dominion_command": [KEY_R],
		"cmd_follow": [KEY_1], "cmd_hold": [KEY_2], "cmd_hunt": [KEY_3],
		"world_map": [KEY_TAB, KEY_M], "sprint": [KEY_SHIFT],
		"debug_horde": [KEY_F1], "debug_party": [KEY_F2], "debug_world": [KEY_F3],
		"save": [KEY_F5], "load": [KEY_F9], "toggle_mouse": [KEY_ESCAPE],
	})
	_add_mouse_action("attack", MOUSE_BUTTON_LEFT)
	_add_mouse_action("ability", MOUSE_BUTTON_RIGHT)

func _add_key_actions(map: Dictionary) -> void:
	for action in map:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in map[action]:
			var ke := InputEventKey.new()
			ke.physical_keycode = key as Key
			InputMap.action_add_event(action, ke)

func _add_mouse_action(action: String, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var mb := InputEventMouseButton.new()
	mb.button_index = button
	InputMap.action_add_event(action, mb)
