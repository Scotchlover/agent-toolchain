# WorldState — persistent strategic campaign truth (scene-independent).
extends RefCounted
class_name WorldState

var seed_value: int = 0
var rng := RandomNumberGenerator.new()
var time := 0.0

var power := 10
var fear := 0
var threat := 0
var gold := 0

var factions := {}
var active_projects: Array = []
var active_expeditions: Array = []
var hostile_cycles := {}       # def_id stays locked through project→journey→raid
var project_counts := {}       # how many causal responses actually started
var project_last_started := {}
var knowledge := {}
var raid_counts := {}
var hero_roster := {}
var captives: Array = []
var sovereign_deaths := 0
var expeditions_resolved := 0
var last_result := ""

func _init(p_seed: int = -1) -> void:
	if p_seed < 0:
		p_seed = int(Time.get_unix_time_from_system() * 1000.0) % 1000000000
	seed_value = p_seed
	rng.seed = seed_value
	for f in Defs.FACTIONS:
		factions[f] = {"hostility": 10.0, "quality": 1.0}
	_init_named_heroes()

func _init_named_heroes() -> void:
	hero_roster.clear()
	for id in Defs.NAMED_HEROES:
		var d: Dictionary = Defs.NAMED_HEROES[id]
		hero_roster[id] = {
			"id": id, "name": str(d["name"]), "role": str(d["role"]),
			"faction": str(d["faction"]), "alive": true, "status": "free",
			"encounters": 0, "escapes": 0, "captures": 0,
			"traits": d.get("traits", []).duplicate(true), "captured_at": -1.0,
		}

func _merge_named_hero_defaults() -> void:
	for id in Defs.NAMED_HEROES:
		if hero_roster.has(id):
			continue
		var d: Dictionary = Defs.NAMED_HEROES[id]
		hero_roster[id] = {
			"id": id, "name": str(d["name"]), "role": str(d["role"]),
			"faction": str(d["faction"]), "alive": true, "status": "free",
			"encounters": 0, "escapes": 0, "captures": 0,
			"traits": d.get("traits", []).duplicate(true), "captured_at": -1.0,
		}

func tick(dt: float) -> void:
	time += dt

func clamp100(v: float) -> int:
	return int(clamp(v, 0.0, 100.0))

func add_threat(v: int) -> void:
	threat = clamp100(threat + v)

func add_fear(v: int) -> void:
	fear = clamp100(fear + v)

func add_hostility(faction: String, v: float) -> void:
	factions[faction]["hostility"] = clampf(factions[faction]["hostility"] + v, 0.0, 100.0)

func compute_power(minions_alive: int, upgrades: int) -> void:
	power = 10 + minions_alive * 2 + upgrades * 15

func do_raid(region_id: String) -> Array:
	var region: Dictionary = Defs.REGIONS[region_id]
	var out: Array = []
	if not can_raid(region_id):
		return ["Raid unavailable."]
	raid_counts[region_id] = int(raid_counts.get(region_id, 0)) + 1
	var raid: Dictionary = region["raid"]
	gold += int(raid.get("gold", 0))
	add_fear(int(raid.get("fear", 0)))
	add_threat(int(raid.get("threat", 0)))
	out.append("Raided %s: +%d gold" % [region["label"], int(raid.get("gold", 0))])
	if raid.get("guild_quality_hit", false):
		factions["guild"]["quality"] = maxf(0.5, factions["guild"]["quality"] - 0.25)
		add_hostility("guild", 20.0)
		out.append("Guild ranks thinned — future contracts are weaker.")
	var provokes: String = raid.get("provokes", "")
	if provokes != "":
		var fac: String = Defs.ENEMY_PROJECTS[provokes]["faction"]
		add_hostility(fac, 25.0)
		out.append("%s hostility rises." % fac.capitalize())
	return out

func can_raid(region_id: String) -> bool:
	var r: Dictionary = Defs.REGIONS[region_id]
	if not r.has("raid"):
		return false
	if r.has("req_fear") and fear < int(r["req_fear"]):
		return false
	if r.has("req_threat") and threat < int(r["req_threat"]):
		return false
	return true

func start_project(def_id: String) -> Dictionary:
	for p in active_projects:
		if p["def_id"] == def_id:
			return p
	if has_hostile_cycle(def_id):
		return {}
	var def: Dictionary = Defs.ENEMY_PROJECTS[def_id]
	var proj := {
		"id": "%s_%d" % [def_id.to_lower(), int(time)],
		"def_id": def_id,
		"progress": 0.0,
		"duration": float(def["duration"]),
		"faction": def["faction"],
	}
	active_projects.append(proj)
	hostile_cycles[def_id] = true
	project_counts[def_id] = int(project_counts.get(def_id, 0)) + 1
	project_last_started[def_id] = time
	return proj

func has_project(def_id: String) -> bool:
	for p in active_projects:
		if p["def_id"] == def_id:
			return true
	return false

func has_hostile_cycle(def_id: String) -> bool:
	if bool(hostile_cycles.get(def_id, false)):
		return true
	for p in active_projects:
		if str(p.get("def_id", "")) == def_id:
			return true
	for e in active_expeditions:
		if str(e.get("def_id", "")) == def_id:
			return true
	return false

func clear_hostile_cycle(def_id: String) -> void:
	hostile_cycles.erase(def_id)

func tick_projects(dt: float) -> Array:
	var done: Array = []
	for p in active_projects:
		p["progress"] += dt
	for p in active_projects.duplicate():
		if p["progress"] >= p["duration"]:
			done.append(p["def_id"])
			active_projects.erase(p)
	return done

# ------------------------------------------------ expedition journeys --------
func launch_expedition(recipe: Dictionary) -> Dictionary:
	var def_id := str(recipe.get("def_id", ""))
	var def: Dictionary = Defs.ENEMY_PROJECTS.get(def_id, {})
	var faction := str(def.get("faction", "guild"))
	var route := ExpeditionJourney.route_for_faction(faction)
	var state := {
		"id": "%s_journey_%d" % [def_id.to_lower(), int(time * 10.0)],
		"def_id": def_id,
		"label": str(recipe.get("label", def.get("label", "Expedition"))),
		"faction": faction,
		"recipe": recipe.duplicate(true),
		"route": route,
		"leg_index": 0,
		"leg_progress": 0.0,
		"leg_duration": ExpeditionJourney.LEG_DURATION,
		"stage": "travelling",
		"approach_left": ExpeditionJourney.DOMAIN_APPROACH_DURATION,
		"intercepted": false,
	}
	active_expeditions.append(state)
	for r in recipe.get("roles", []):
		var hero_id := str(r.get("hero_id", ""))
		if hero_id != "" and hero_roster.has(hero_id):
			var hs: Dictionary = hero_roster[hero_id]
			hs["status"] = "deployed"
			hs["encounters"] = int(hs.get("encounters", 0)) + 1
	return state

func get_expedition(id: String) -> Dictionary:
	for e in active_expeditions:
		if str(e.get("id", "")) == id:
			return e
	return {}

func begin_interception(id: String) -> Dictionary:
	var e := get_expedition(id)
	if e.is_empty() or str(e.get("stage", "")) != "approach" or bool(e.get("intercepted", false)):
		return {}
	e["stage"] = "intercepting"
	e["intercepted"] = true
	return e

func resolve_interception(id: String, outcome: String, survivors: Array) -> Dictionary:
	var e := get_expedition(id)
	if e.is_empty():
		return {}
	if outcome in ["broken", "aborted"] or survivors.is_empty():
		active_expeditions.erase(e)
		clear_hostile_cycle(str(e.get("def_id", "")))
		expeditions_resolved += 1
		return {"cancelled": true, "expedition": e}
	# The SAME expedition continues: casualties/resources persist in its recipe.
	e["recipe"]["roles"] = survivors.duplicate(true)
	e["stage"] = "approach"
	e["approach_left"] = 13.0
	return {"cancelled": false, "expedition": e}

func tick_expeditions(dt: float) -> Array:
	var events: Array = []
	for e in active_expeditions.duplicate():
		var stage := str(e.get("stage", "travelling"))
		if stage == "intercepting":
			continue
		if stage == "travelling":
			var route: Array = e.get("route", [])
			if route.size() <= 1:
				e["stage"] = "approach"
				events.append({"type": "domain_entered", "expedition": e})
				continue
			e["leg_progress"] = float(e.get("leg_progress", 0.0)) + dt
			var dur := float(e.get("leg_duration", ExpeditionJourney.LEG_DURATION))
			while float(e["leg_progress"]) >= dur and str(e["stage"]) == "travelling":
				e["leg_progress"] = float(e["leg_progress"]) - dur
				e["leg_index"] = mini(int(e["leg_index"]) + 1, route.size() - 1)
				var node_id := str(route[int(e["leg_index"])])
				events.append({"type": "node_entered", "node": node_id, "expedition": e})
				if node_id == "dark_domain":
					e["stage"] = "approach"
					e["approach_left"] = ExpeditionJourney.DOMAIN_APPROACH_DURATION
					events.append({"type": "domain_entered", "expedition": e})
		elif stage == "approach":
			e["approach_left"] = maxf(0.0, float(e.get("approach_left", 0.0)) - dt)
			if float(e["approach_left"]) <= 0.0:
				events.append({"type": "arrived", "expedition": e, "recipe": e["recipe"]})
				active_expeditions.erase(e)
	return events

func has_active_expedition() -> bool:
	return not active_expeditions.is_empty()

# ------------------------------------------------ persistent heroes ----------
func available_named_hero(faction: String, role: String = "") -> Dictionary:
	for id in hero_roster:
		var h: Dictionary = hero_roster[id]
		if bool(h.get("alive", false)) and str(h.get("status", "")) == "free" 				and str(h.get("faction", "")) == faction 				and (role == "" or str(h.get("role", "")) == role):
			return h
	return {}

func first_captive(faction: String = "") -> Dictionary:
	for id in captives:
		if not hero_roster.has(id):
			continue
		var h: Dictionary = hero_roster[id]
		if faction == "" or str(h.get("faction", "")) == faction:
			return h
	return {}

func capture_named_hero(id: String) -> Dictionary:
	if not hero_roster.has(id):
		return {}
	var h: Dictionary = hero_roster[id]
	if not bool(h.get("alive", false)):
		return {}
	if str(h.get("status", "")) != "captive":
		h["captures"] = int(h.get("captures", 0)) + 1
	h["status"] = "captive"
	h["captured_at"] = time
	if not captives.has(id):
		captives.append(id)
	return h

func release_named_hero(id: String) -> Dictionary:
	if not hero_roster.has(id):
		return {}
	var h: Dictionary = hero_roster[id]
	captives.erase(id)
	if bool(h.get("alive", false)):
		h["status"] = "free"
	h["captured_at"] = -1.0
	return h

func mark_named_hero_dead(id: String) -> void:
	if not hero_roster.has(id):
		return
	var h: Dictionary = hero_roster[id]
	h["alive"] = false
	h["status"] = "dead"
	captives.erase(id)

func note_named_hero_escape(id: String) -> void:
	if not hero_roster.has(id):
		return
	var h: Dictionary = hero_roster[id]
	if not bool(h.get("alive", false)):
		return
	h["status"] = "free"
	h["escapes"] = int(h.get("escapes", 0)) + 1
	var traits: Array = h.get("traits", [])
	if int(h["escapes"]) >= 1 and not traits.has("survived_dark_domain"):
		traits.append("survived_dark_domain")
	h["traits"] = traits

func resolve_named_outcomes(launched_ids: Array, escaped_ids: Array, captured_ids: Array) -> void:
	for id in launched_ids:
		var sid := str(id)
		if sid == "" or not hero_roster.has(sid):
			continue
		if captured_ids.has(sid):
			capture_named_hero(sid)
		elif escaped_ids.has(sid):
			note_named_hero_escape(sid)
		else:
			mark_named_hero_dead(sid)

func named_ids_from_roles(roles: Array) -> Array:
	var out: Array = []
	for r in roles:
		var id := str(r.get("hero_id", ""))
		if id != "" and not out.has(id):
			out.append(id)
	return out

func mark_expedition_resolved() -> void:
	expeditions_resolved += 1

func to_dict() -> Dictionary:
	return {
		"seed": seed_value,
		"rng_state": str(rng.state),
		"time": time,
		"fear": fear, "threat": threat, "gold": gold, "power": power,
		"factions": factions.duplicate(true),
		"active_projects": active_projects.duplicate(true),
		"active_expeditions": active_expeditions.duplicate(true),
		"hostile_cycles": hostile_cycles.duplicate(true),
		"project_counts": project_counts.duplicate(true),
		"project_last_started": project_last_started.duplicate(true),
		"knowledge": knowledge.duplicate(true),
		"raid_counts": raid_counts.duplicate(true),
		"hero_roster": hero_roster.duplicate(true),
		"captives": captives.duplicate(true),
		"sovereign_deaths": sovereign_deaths,
		"expeditions_resolved": expeditions_resolved,
		"last_result": last_result,
	}

func from_dict(d: Dictionary) -> void:
	seed_value = int(d.get("seed", 1))
	rng.seed = seed_value
	rng.state = int(str(d.get("rng_state", str(seed_value))))
	time = float(d.get("time", 0.0))
	fear = int(d.get("fear", 0))
	threat = int(d.get("threat", 0))
	gold = int(d.get("gold", 0))
	power = int(d.get("power", 10))
	factions = d.get("factions", {}).duplicate(true)
	active_projects = d.get("active_projects", []).duplicate(true)
	active_expeditions = d.get("active_expeditions", []).duplicate(true)
	hostile_cycles = d.get("hostile_cycles", {}).duplicate(true)
	project_counts = d.get("project_counts", {}).duplicate(true)
	project_last_started = d.get("project_last_started", {}).duplicate(true)
	# Tactical interception runtime is intentionally not serialized. If a save
	# ever contains this transient stage (old build/crash), recover to approach
	# rather than freezing the expedition forever without a controller.
	for e in active_expeditions:
		if str(e.get("stage", "")) == "intercepting":
			e["stage"] = "approach"
			e["approach_left"] = maxf(13.0, float(e.get("approach_left", 0.0)))
	knowledge = d.get("knowledge", {}).duplicate(true)
	raid_counts = d.get("raid_counts", {}).duplicate(true)
	# v0.2 had no causal ledger. Treat all historical provocations in an old
	# save as already answered; only a NEW raid after migration may start a new
	# response. Active projects/journeys are still protected by cycle scans.
	if not d.has("project_counts"):
		for region_id in Defs.REGIONS:
			var region: Dictionary = Defs.REGIONS[region_id]
			var raid: Dictionary = region.get("raid", {})
			var def_id := str(raid.get("provokes", ""))
			if def_id != "":
				project_counts[def_id] = int(raid_counts.get(region_id, 0))
	hero_roster = d.get("hero_roster", {}).duplicate(true)
	if hero_roster.is_empty():
		_init_named_heroes()
	else:
		_merge_named_hero_defaults()
	captives = d.get("captives", []).duplicate(true)
	sovereign_deaths = int(d.get("sovereign_deaths", 0))
	expeditions_resolved = int(d.get("expeditions_resolved", 0))
	last_result = str(d.get("last_result", ""))
