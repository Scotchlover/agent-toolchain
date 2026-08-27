# PartyController — ONE adventuring party with a shared goal, not four bots.
# Owns: objective, phase, target room, group confidence, retreat route, orders.
# HeroAgents execute locally (Ready-or-Not style staged activities).
extends Node
class_name PartyController

enum P { APPROACH, SCOUT, BREACH, ENGAGE, OBJECTIVE, REGROUP, RETREAT }
enum Conf { CONFIDENT, CAUTIOUS, BROKEN }

signal party_resolved(result: Dictionary)
signal raid_progress(stage: String, room_id: String, detail: String, fraction: float)

var members: Array = []
var objective := "steal_relic"
var objective_sequence: Array = []
var objective_index := 0
var doctrine := "balanced"
var objective_successes: Array = []
var lair_system_disabled := ""
var label := "Party"
var state: int = P.APPROACH
var confidence := 100.0
var recipe: Dictionary
var fortress: FortressBuilder

var route: Array = []            # door dicts remaining
var retreat_route: Array = []    # door dicts for the march home
var rally_point := Vector3.ZERO
var _no_enemy_t := 0.0
var _hp_memory := 1.0
var _poll_t := 0.0
var resolved := false
var used_sally := false
var rogue_saw_trap := ""         # socket id if our scout encountered a trap
var relic_stolen := false
var launched := 0
var _repath_t := 0.0
var _caution_logged := false     # one-shot caution notice, not per-second spam
var _breach_worker: Hero = null
var _breach_watch := 0.0
var _breach_total := 0.0
var _breach_door_id := ""
var _breach_target_room := ""
var _last_progress_room := "__outside__"
var _rooms_reported: Array = []
var discovered_sally := false    # scout curiosity reveals the hidden exit
var combat_plan := "FORM UP"
var combat_focus_label := ""
var _coord_left := 0.0
var _resource_memory := 1.0
var _retreat_cover_used := false
var named_launched: Array = []
var escaped_heroes: Array = []
var captured_ids: Array = []
var _capture_grace_left := -1.0
var sovereign_slain_this_raid := false

func setup(p_recipe: Dictionary, p_fortress: FortressBuilder, root: Node3D) -> void:
	recipe = p_recipe
	fortress = p_fortress
	objective_sequence = recipe.get("objectives", [recipe.get("objective", "steal_relic")]).duplicate(true)
	if objective_sequence.is_empty():
		objective_sequence = ["steal_relic"]
	objective_index = 0
	objective = str(objective_sequence[0])
	doctrine = str(recipe.get("doctrine", "balanced"))
	label = recipe.get("label", "Party")
	var door_id: String = recipe["entry_door"]
	var door: Dictionary = Safe.gs().graph["doors"][door_id]
	used_sally = door_id == "sally_port"
	var spawn := _outside_spawn(door)
	for r in recipe["roles"]:
		var h := Hero.new()
		h.setup(r["role"], r["quality"], r)
		if h.hero_id != "" and not named_launched.has(h.hero_id):
			named_launched.append(h.hero_id)
		if r.has("resources"):
			h.restore_resources(r["resources"])
		if r.has("hp_frac"):
			h.hp = clampf(float(r["hp_frac"]), 0.05, 1.0) * h.max_hp
		root.add_child(h)
		h.global_position = spawn + Vector3(randf_range(-1.2, 1.2), 0.6, randf_range(-1.2, 1.2))
		h.hero_died.connect(_on_hero_died)
		h.escaped.connect(_on_hero_escaped)
		members.append(h)
	route = _plan_route_from(door)
	launched = members.size()
	Safe.gs().el("%s approaches — %d adventurers (%s)." % [label, members.size(), ", ".join(roles())])
	if not recipe.get("knowledge", {}).is_empty():
		Safe.gs().el("They move like they know something.")
	_announce_current_objective()

func roles() -> Array:
	var out: Array = []
	for m in members:
		if is_instance_valid(m) and not m.down:
			out.append(m.role)
	return out

func _outside_spawn(door: Dictionary) -> Vector3:
	var p := Defs.door_pos(door)
	if door["kind"] == "portcullis":
		return Vector3(p.x, 0.6, p.z + 2.5)
	if door["kind"] == "sally":
		return Vector3(p.x - 2.0, 0.6, p.z)
	return p

func _plan_route_from(entry_door: Dictionary) -> Array:
	# Live BFS to the objective room honoring current passability.
	# Parties always enter INTO door["b"] (outside is courtyard/__outside__/door["a"]).
	return RoomGraph.path(Safe.gs().graph, entry_door["b"], _objective_room(objective), _passable())

func _objective_room(id: String) -> String:
	match id:
		"consecrate_crypt": return "crypt"
		"disable_gate": return "gatehouse"
		"free_prisoner": return "chapel"
		"kill_sovereign":
			var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
			if sov != null and is_instance_valid(sov):
				return RoomGraph.room_of_pos((sov as Node3D).global_position)
			return "throne"
		_: return Defs.OBJECTIVE_ROOM

func _passable() -> Callable:
	return func(door: Dictionary) -> bool:
		match door["kind"]:
			"sally":
				return not Safe.gs().domain.sally_sealed
			"portcullis":
				return true   # breachable; path exists even through it
			_:
				return true

# ---------------------------------------------------------------- update -----
func _physics_process(dt: float) -> void:
	if resolved:
		return
	var alive := live_members()
	if alive.is_empty():
		var capturable := capturable_named_down()
		if not capturable.is_empty():
			if _capture_grace_left < 0.0:
				_capture_grace_left = 6.0
				Safe.gs().el("%s lies defeated — [E] CAPTURE before the moment passes." % capturable[0].display_name)
			_capture_grace_left -= dt
			if _capture_grace_left > 0.0:
				return
		_finish("wiped")
		return
	_capture_grace_left = -1.0
	_track_room_progress(alive)
	_poll_t += dt
	if _poll_t >= 1.0:
		_poll(alive)
	for h in alive:
		h.tick_work(dt)
	_handle_locked_doors(alive)
	# Watchdog: a breach whose worker vanished/restarted must re-channel.
	if state == P.BREACH:
		_breach_watch += dt
		if _breach_watch >= 1.0:
			_breach_watch = 0.0
			if _breach_worker == null or not is_instance_valid(_breach_worker) \
					or _breach_worker.down or not _breach_worker.is_working():
				Safe.gs().el("%s re-forms the breach." % (label))
				_start_breach(recipe["entry_door"])
	match state:
		P.APPROACH: _state_approach(alive, dt)
		P.SCOUT: _state_scout(alive, dt)
		P.BREACH: pass   # handled by work callbacks
		P.ENGAGE: _state_engage(alive, dt)
		P.OBJECTIVE: _state_objective(alive, dt)
		P.REGROUP: _state_regroup(alive, dt)
		P.RETREAT: _state_retreat(alive, dt)

func _track_room_progress(alive: Array) -> void:
	if alive.is_empty():
		return
	var room_id: String = RoomGraph.room_of_pos(_centroid(alive))
	if room_id == "__outside__" or room_id == "courtyard":
		return
	_last_progress_room = room_id
	if _rooms_reported.has(room_id):
		return
	_rooms_reported.append(room_id)
	raid_progress.emit("room_entered", room_id,
		room_id.replace("_", " ").to_upper(), raid_depth_for_room(room_id))

static func raid_depth_for_room(room_id: String) -> float:
	match room_id:
		"gatehouse": return 0.18
		"great_hall": return 0.38
		"crypt", "chapel": return 0.58
		"treasury": return 0.82
		"throne": return 1.0
		_: return 0.0

func current_room_label() -> String:
	if _last_progress_room == "__outside__":
		return "OUTER APPROACH"
	return _last_progress_room.replace("_", " ").to_upper()

func breach_progress() -> float:
	if state != P.BREACH or _breach_worker == null or not is_instance_valid(_breach_worker):
		return -1.0
	return _breach_worker.work_progress()

func live_members() -> Array:
	var out: Array = []
	for m in members:
		if is_instance_valid(m) and not m.down and not m.is_queued_for_deletion():
			out.append(m)
	return out

func capturable_named_down() -> Array:
	var out: Array = []
	for h in members:
		if is_instance_valid(h) and h.down and h.hero_id != "" and not h.captured 				and not h.is_queued_for_deletion():
			out.append(h)
	return out

func capture_hero(hero: Hero) -> Dictionary:
	if hero == null or not is_instance_valid(hero) or not hero.down 			or hero.hero_id == "" or hero.captured:
		return {}
	hero.captured = true
	if not captured_ids.has(hero.hero_id):
		captured_ids.append(hero.hero_id)
	var snap := hero.identity_snapshot()
	snap["resources"] = hero.resource_snapshot()
	snap["hp_frac"] = 0.05
	members.erase(hero)
	hero.cancel_work()
	hero.visible = false
	hero.set_physics_process(false)
	hero.call_deferred("queue_free")
	Safe.tel().ev("hero_captured_tactical", {"hero_id": hero.hero_id, "name": hero.display_name})
	Safe.gs().el("%s is dragged away in chains." % hero.display_name)
	return snap

func notify_sovereign_fallen() -> void:
	sovereign_slain_this_raid = true
	confidence = minf(100.0, confidence + 25.0)
	Safe.gs().el("%s surges with confidence — the Dark Sovereign has fallen!" % label)
	_bark(["The tyrant falls!", "Press the advantage!"])
	if objective == "kill_sovereign":
		_complete_current_objective()

# ------------------------------------------------------------ FSM states -----
func _state_approach(alive: Array, _dt: float) -> void:
	combat_plan = "ADVANCE"
	combat_focus_label = ""
	_clear_combat_intent(alive)
	var door: Dictionary = Safe.gs().graph["doors"][recipe["entry_door"]]
	var goal := Defs.door_pos(door)
	_order_move(alive, goal, 2.2)
	if _avg_dist(alive, goal) < 2.6:
		var gate = fortress.interactables[door["id"]]
		if door["kind"] == "portcullis" and gate["target_y"] < gate["raised_y"]:
			_start_breach(door["id"])
		else:
			state = P.SCOUT
			Safe.gs().el("%s slips inside." % label)

func _start_breach(door_id: String) -> void:
	state = P.BREACH
	combat_plan = "BREACH"
	combat_focus_label = ""
	confidence -= 10.0
	var paladin := find_role("paladin")
	var worker: Hero = paladin if paladin != null else live_members()[0]
	_breach_worker = worker
	var door: Dictionary = Safe.gs().graph["doors"][door_id]
	var pos := Defs.door_pos(door)
	_order_move(live_members(), pos + Vector3(0, 0, 3.0), 2.0)
	var dur := 8.0 if door["kind"] != "portcullis" else 12.0
	if doctrine == "strike":
		dur *= 0.72
	# Reinforced Gate domain upgrade: raiders force it twice as long.
	if door["kind"] == "portcullis" and Safe.gs().domain.upgrades.has("gate_reinforcement"):
		dur *= 2.0
	_breach_total = dur
	_breach_door_id = door_id
	var from_room: String = RoomGraph.room_of_pos(_centroid(live_members()))
	_breach_target_room = str(door["b"]) if str(door["a"]) == from_room else str(door["a"])
	raid_progress.emit("breach_started", _breach_target_room, door_id, 0.0)
	worker.start_work(dur, "breaching", func():
		var gate = fortress.interactables[door_id]
		gate["target_y"] = gate["raised_y"]
		Safe.gs().el("The %s forces the way open!" % worker.def["label"])
		raid_progress.emit("door_breached", _breach_target_room, _breach_door_id, 1.0)
		_breach_total = 0.0
		state = P.SCOUT
	)
	Safe.gs().el("%s braces to force the gate." % worker.def["label"])

# A dead worker must never leave a channel frozen: retry the breach.
func _retry_breach_if_stalled() -> void:
	if state == P.BREACH and recipe.has("entry_door"):
		_start_breach(recipe["entry_door"])

func _state_scout(alive: Array, _dt: float) -> void:
	combat_plan = "ADVANCE"
	combat_focus_label = ""
	_clear_combat_intent(alive)
	var rogue := find_role("rogue")
	var lead: Hero = rogue if rogue != null else alive[0]

	# Trap awareness is orthogonal to strategic objective.
	var trap := _trap_near(lead.global_position, 2.6)
	if not trap.is_empty():
		rogue_saw_trap = trap["socket_id"]
		var known: bool = recipe.get("knowledge", {}).get("trap_seen", []).has(trap["socket_id"])
		if Safe.gs().domain.traps_armed.get(trap["socket_id"], false):
			if known:
				lead.move_goal = trap["pos"] + Vector3(trap["radius"] * 1.6, 0, 0)
			elif not lead.is_working():
				confidence -= 4.0
				lead.start_work(2.0, "disarming", func():
					Safe.gs().domain.toggle_trap(trap["socket_id"])
					fortress.set_trap_armed(trap["socket_id"], false)
					Safe.gs().el("Rogue disarms the %s." % trap["socket_id"].replace("_", " "))
				)
				Safe.gs().el("Rogue spots a trap!")
				return

	# Grand Consecration hunts the Sovereign dynamically rather than walking
	# toward a stale authored room.
	if objective == "kill_sovereign":
		var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
		if sov == null or not is_instance_valid(sov) or (sov as Sovereign).dead:
			state = P.OBJECTIVE
			return
		_repath_t -= _dt
		if _repath_t <= 0.0:
			var from_room := RoomGraph.room_of_pos(_centroid(alive))
			var target_room := RoomGraph.room_of_pos((sov as Node3D).global_position)
			route = RoomGraph.path(Safe.gs().graph, from_room, target_room, _passable())
			_repath_t = 1.25
		if route.is_empty():
			state = P.OBJECTIVE
			return
	elif route.is_empty():
		state = P.OBJECTIVE
		return

	# Scouts can discover the hidden exit naturally while sweeping the crypt.
	var sally = fortress.interactables.get("sally_port", null)
	var detour_active := false
	if not discovered_sally and sally != null and not Safe.gs().domain.sally_sealed 			and RoomGraph.room_of_pos(lead.global_position) == "crypt":
		var ds: float = lead.global_position.distance_to(sally["pos"])
		if ds < 2.5:
			discovered_sally = true
			Safe.tel().ev("sally_discovered", {"by": lead.def["label"]})
			Safe.gs().el("%s: «A hidden way out... I'll remember this.»" % lead.def["label"])
		else:
			detour_active = true
	if detour_active:
		lead.set_destination(sally["pos"])
		lead.has_goal = true
		return

	if route.is_empty():
		state = P.OBJECTIVE
		return
	var next_door: Dictionary = route[0]
	if next_door["kind"] == "portcullis":
		var gate = fortress.interactables[next_door["id"]]
		if gate["target_y"] < gate["raised_y"]:
			_start_breach(next_door["id"])
			return
	var entry_gate = fortress.interactables["gate_portcullis"]
	if entry_gate["target_y"] < entry_gate["raised_y"] 			and lead.global_position.distance_to(entry_gate["pos"]) < 2.2:
		_start_breach("gate_portcullis")
		return

	_order_move(alive, Defs.door_pos(next_door), 1.15)
	if _enemy_within(alive, 9.0):
		state = P.ENGAGE
		_bark(["To arms!", "Hold the line!", "For the Light!"])
		Safe.gs().el("%s draws steel!" % label)
	elif _max_dist(alive, Defs.door_pos(next_door)) < 3.4:
		route.pop_front()

func _state_engage(alive: Array, dt: float) -> void:
	# PartyController now owns shared combat intent; HeroAgents execute locally.
	_coord_left -= dt
	if _coord_left <= 0.0:
		_coord_left = 0.35
		_coordinate_combat(alive)
	var enemy := _nearest_enemy_to(_centroid(alive), 15.0)
	if enemy == null:
		_no_enemy_t += dt
		if _no_enemy_t > 2.4:
			_no_enemy_t = 0.0
			state = P.REGROUP
			rally_point = _centroid(alive)
			confidence = minf(100.0, confidence + 4.0)
	else:
		_no_enemy_t = 0.0

func _state_regroup(_alive: Array, dt: float) -> void:
	combat_plan = "REGROUP"
	combat_focus_label = ""
	_clear_combat_intent(live_members())
	_order_move(live_members(), rally_point, 2.0)
	if _avg_dist(live_members(), rally_point) < 2.5:
		state = P.SCOUT

func _state_objective(alive: Array, _dt: float) -> void:
	combat_plan = "EXECUTE OBJECTIVE"
	combat_focus_label = ""
	_clear_combat_intent(alive)
	match objective:
		"steal_relic":
			_objective_steal(alive)
		"consecrate_crypt":
			_objective_disable_lair(alive, "soul_bell")
		"disable_gate":
			_objective_disable_lair(alive, "gate_controls")
		"free_prisoner":
			_objective_free_prisoner(alive)
		"kill_sovereign":
			_objective_kill_sovereign(alive)
		_:
			_complete_current_objective()

func _objective_steal(alive: Array) -> void:
	var relic = fortress.interactables["relic"]
	if relic_stolen:
		_complete_current_objective()
		return
	var rogue := find_role("rogue")
	if rogue == null:
		var w: Hero = alive[0]
		_order_move(alive, Defs.OBJECTIVE_POS, 1.2)
		if not w.is_working() and w.global_position.distance_to(Defs.OBJECTIVE_POS) < 1.8:
			w.start_work(7.0, "smashing", func(): _steal(w))
		return
	_order_move([rogue], Defs.OBJECTIVE_POS, 0.9)
	if not rogue.is_working() and rogue.global_position.distance_to(Defs.OBJECTIVE_POS) < 1.6:
		var work := 2.2 if doctrine == "retrieval" else 3.0
		rogue.start_work(work, "stealing", func(): _steal(rogue))

func _objective_disable_lair(alive: Array, system_id: String) -> void:
	var it = fortress.interactables.get(system_id, null)
	if it == null:
		_complete_current_objective()
		return
	var preferred_role := "cleric" if system_id == "soul_bell" else "rogue"
	var worker := find_role(preferred_role)
	if worker == null:
		worker = alive[0]
	var pos: Vector3 = it["pos"]
	_order_move([worker], pos, 0.8)
	if worker.global_position.distance_to(pos) >= 1.8 or worker.is_working():
		return
	var duration := 9.0
	if system_id == "soul_bell":
		if worker.role == "cleric" and worker.resource("consecration") > 0 				and worker.spend_resource("consecration", "consecrate_crypt"):
			duration = 5.5
		Safe.gs().el("The Cleric begins a CONSECRATION in the crypt!")
	else:
		if worker.role == "rogue" and worker.resource("tools") > 0 				and worker.spend_resource("tools", "sabotage_gate_controls"):
			duration = 4.0
		Safe.gs().el("The Rogue starts sabotaging the gate controls!")
	worker.start_work(duration, "disabling_%s" % system_id, func():
		Safe.gs().domain.suppress_raid_system(system_id)
		fortress.set_lair_system_disabled(system_id, true)
		lair_system_disabled = system_id
		Safe.tel().ev("lair_system_disabled", {"system": system_id, "doctrine": doctrine})
		Safe.gs().el("%s is DISABLED by the raiders!" % Defs.LAIR_SYSTEMS[system_id]["label"])
		_complete_current_objective()
	)

func _objective_free_prisoner(alive: Array) -> void:
	var target_id := str(recipe.get("rescue_target", ""))
	if target_id == "":
		state = P.RETREAT
		return
	var captive: Dictionary = Safe.gs().world.first_captive(str(Defs.ENEMY_PROJECTS[recipe["def_id"]]["faction"]))
	if captive.is_empty() or str(captive.get("id", "")) != target_id:
		_complete_current_objective()
		return
	var prison = fortress.interactables.get("prison", null)
	if prison == null:
		state = P.RETREAT
		return
	var worker := find_role("rogue")
	if worker == null:
		worker = find_role("cleric")
	if worker == null:
		worker = alive[0]
	var pos: Vector3 = prison["pos"]
	_order_move([worker], pos, 0.8)
	if worker.global_position.distance_to(pos) >= 1.8 or worker.is_working():
		return
	var duration := 5.0
	if worker.role == "rogue" and worker.resource("tools") > 0 			and worker.spend_resource("tools", "free_prisoner"):
		duration = 3.2
	worker.start_work(duration, "freeing_prisoner", func():
		var freed: Dictionary = Safe.gs().world.release_named_hero(target_id)
		fortress.refresh_prison_visual()
		Safe.tel().ev("named_hero_rescued", {"hero_id": target_id,
			"name": str(freed.get("name", target_id))})
		Safe.gs().el("%s is FREED from the Iron Prison!" % str(freed.get("name", target_id)))
		_complete_current_objective()
	)

func _objective_kill_sovereign(alive: Array) -> void:
	if sovereign_slain_this_raid:
		_complete_current_objective()
		return
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov == null or not is_instance_valid(sov) or (sov as Sovereign).dead:
		sovereign_slain_this_raid = true
		_complete_current_objective()
		return
	_order_move(alive, (sov as Node3D).global_position, 1.8)

func _steal(taker: Hero) -> void:
	var relic = fortress.interactables["relic"]
	relic["taken"] = true
	relic["visual"].visible = false
	taker.carrying_relic = true
	relic_stolen = true
	relic["carrier"] = taker
	confidence += 15.0
	Safe.gs().el("The relic is TAKEN! The party turns to flee!")
	_bark(["We have it! GO, GO!"])
	_complete_current_objective()

func _complete_current_objective() -> void:
	if not objective_successes.has(objective):
		objective_successes.append(objective)
	Safe.tel().ev("raid_objective_complete", {"objective": objective, "index": objective_index,
		"doctrine": doctrine})
	objective_index += 1
	if objective_index >= objective_sequence.size():
		state = P.RETREAT
		_bark(["Objective complete! Extract!", "We have done what we came for — GO!"])
		return
	objective = str(objective_sequence[objective_index])
	_announce_current_objective()
	var from_room := RoomGraph.room_of_pos(_centroid(live_members()))
	var target_room := _objective_room(objective)
	route = RoomGraph.path(Safe.gs().graph, from_room, target_room, _passable())
	retreat_route.clear()
	state = P.SCOUT
	Safe.gs().el("%s shifts to its next objective: %s." % [label, objective.replace("_", " ").to_upper()])

var _bark_cd := 0.0
func _bark(lines: Array) -> void:
	if _bark_cd > 0.0 or lines.is_empty():
		return
	_bark_cd = 4.0
	var who := find_role("paladin")
	if who == null:
		who = live_members()[0] if not live_members().is_empty() else null
	if who != null:
		Safe.gs().el("%s: «%s»" % [who.display_name, str(lines[randi() % lines.size()])])

func _state_retreat(alive: Array, dt: float) -> void:
	combat_plan = "EXTRACT"
	_prime_retreat_cover(alive)
	for h in alive:
		h.set_combat_directive("retreat", null, Vector3.ZERO, 0.8)
	var exit_door: Dictionary = Safe.gs().graph["doors"][recipe["entry_door"]]
	var exit_pos := _outside_spawn(exit_door)
	# Breach detection: if a portcullis blocks the way home, break it.
	if retreat_route.is_empty():
		var cur := RoomGraph.room_of_pos(_centroid(alive))
		var outside_room: String = exit_door["a"]
		retreat_route = RoomGraph.path(Safe.gs().graph, cur, outside_room, _passable())
	for d in retreat_route:
		if d["kind"] == "portcullis":
			var gate = fortress.interactables["gate_portcullis"]
			if gate["target_y"] < gate["raised_y"]:
				var breacher := _nearest_hero(door_pos_of(d))
				if breacher != null and not breacher.is_working():
					breacher.start_work(12.0, "breaking the portcullis", func():
						gate["target_y"] = gate["raised_y"]
						Safe.gs().el("Sealed in, they smash their way out through the gate!")
					)
			break
	# Everyone navigates home independently through the semantic graph.
	_order_move(alive, exit_pos, 1.4)
	var outside_room: String = exit_door["a"]
	for h in alive:
		# Converge exactly onto the exit once close, or offsets keep them circling.
		if h.global_position.distance_to(exit_pos) < 5.0:
			h.set_destination(exit_pos)
		# Escaped = out of the fortress rooms, not pixel-perfect on a point
		# (crowding at a doorway would otherwise mill forever).
		var h_room := RoomGraph.room_of_pos(h.global_position)
		var near_exit: bool = h.global_position.distance_to(exit_pos) < 4.5
		if (h_room == outside_room and near_exit) or h.global_position.distance_to(exit_pos) < 1.9:
			if h.carrying_relic:
				Safe.gs().el("%s escapes with the relic!" % h.def["label"])
			else:
				Safe.gs().el("%s flees into the dark." % h.def["label"])
			h.escape(exit_pos)

func door_pos_of(d: Dictionary) -> Vector3:
	return Defs.door_pos(d)

# ------------------------------------------------------------- confidence ----
## Global pre-step: any phase, if the lead stands at a locked door, someone
## picks it. Keeps OBJECTIVE/ENGAGE from dead-ending behind vault doors.
func _handle_locked_doors(alive: Array) -> void:
	# Strong hits can interrupt Hero work. Recover stale door ownership or the
	# lock would remain permanently "being_worked" with no active channel.
	for id in fortress.interactables:
		var it: Dictionary = fortress.interactables[id]
		if it.get("kind", "") != "door" or not it.get("being_worked", false):
			continue
		var worker = it.get("worker", null)
		if worker == null or not is_instance_valid(worker) or worker.down or not worker.is_working():
			it["being_worked"] = false
			it["worker"] = null
			Safe.tel().ev("door_work_recovered", {"door": id})

	var lead := find_role("rogue")
	if lead == null and not alive.is_empty():
		lead = alive[0]
	if lead == null or lead.is_working():
		return
	var lock := _locked_door_near(lead.global_position, 2.2)
	if lock.is_empty():
		return
	if not lock.get("being_worked", false):
		lock["being_worked"] = true
		lock["worker"] = lead
		var rogue := find_role("rogue")
		var dur: float = 3.0 if rogue != null else 6.0
		lead.start_work(dur, "unlocking", func():
			if is_instance_valid(lock.get("body", null)):
				lock["body"].queue_free()
			lock["locked"] = false
			lock["being_worked"] = false
			lock["worker"] = null
			Safe.gs().el("A door creaks open...")
		)
		_order_move([lead], lock["pos"], 0.9)


func _poll(alive: Array) -> void:
	var frac := 0.0
	var resources := 0.0
	for h in alive:
		frac += h.hp / h.max_hp
		resources += h.resource_fraction()
	frac /= float(maxi(1, alive.size()))
	resources /= float(maxi(1, alive.size()))
	if _hp_memory - frac > 0.18:
		confidence -= 10.0
		Safe.gs().el("%s confidence wavers." % label)
	_hp_memory = frac
	if _resource_memory >= 0.45 and resources < 0.45:
		confidence -= 8.0
		Safe.gs().el("%s is running low on spells and tools." % label)
	if _resource_memory >= 0.20 and resources < 0.20:
		confidence -= 12.0
		Safe.gs().el("%s is nearly spent." % label)
	_resource_memory = resources
	for h in alive:
		if h.pinned:
			confidence -= 1.0
	if confidence <= 30.0 and state != P.RETREAT:
		state = P.RETREAT
		_bark(["Fall back! We cannot win this!", "RUN! Save yourselves!"])
		Safe.gs().el("%s breaks and RUNS!" % label)
	elif confidence <= 60.0 and state in [P.SCOUT, P.APPROACH] and not _caution_logged:
		_caution_logged = true
		Safe.gs().el("%s grows cautious." % label)

func _clear_combat_intent(group: Array) -> void:
	for h in group:
		if is_instance_valid(h):
			h.set_combat_directive("independent", null, Vector3.ZERO, 0.1)

static func choose_combat_plan(p_doctrine: String, p_objective: String,
		sovereign_near: bool, backline_threat: bool, p_confidence: float) -> String:
	if p_confidence <= 30.0:
		return "BREAK CONTACT"
	if backline_threat:
		return "PROTECT BACKLINE"
	if p_objective == "kill_sovereign" or (p_doctrine == "strike" and sovereign_near):
		return "PRESS SOVEREIGN"
	if p_doctrine in ["retrieval", "rescue"]:
		return "SCREEN OBJECTIVE"
	if p_doctrine == "purge":
		return "HOLD FORMATION"
	return "FOCUS THREAT"

func _coordinate_combat(alive: Array) -> void:
	if alive.is_empty():
		return
	var center := _centroid(alive)
	var sov: Node = get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	var sovereign_near: bool = sov != null and is_instance_valid(sov) 		and not (sov as Sovereign).dead 		and (sov as Node3D).global_position.distance_to(center) <= 14.0

	var backliner: Hero = find_role("cleric")
	if backliner == null:
		backliner = find_role("wizard")
	var backline_threat: Node = null
	if backliner != null:
		backline_threat = _nearest_enemy_to(backliner.global_position, 5.5)
	var plan := choose_combat_plan(doctrine, objective, sovereign_near,
		backline_threat != null, confidence)

	var focus: Node = null
	if plan == "PRESS SOVEREIGN" and sovereign_near:
		focus = sov
	elif backline_threat != null:
		focus = backline_threat
	else:
		focus = _priority_enemy(center, 15.0)
	if focus == null:
		focus = _nearest_enemy_to(center, 15.0)

	if plan != combat_plan:
		combat_plan = plan
		Safe.tel().ev("party_combat_plan", {"plan": plan, "doctrine": doctrine,
			"objective": objective, "confidence": confidence})
		Safe.gs().el("%s tactic: %s." % [label, plan.capitalize()])
	combat_focus_label = _actor_label(focus)

	var focus_pos := center
	var toward := Vector3(0, 0, -1)
	if focus != null and is_instance_valid(focus):
		focus_pos = (focus as Node3D).global_position
		toward = focus_pos - center
		toward.y = 0
		if toward.length_squared() > 0.01:
			toward = toward.normalized()
	var side := Vector3(-toward.z, 0, toward.x)

	for h in alive:
		match h.role:
			"paladin":
				var anchor := center + toward * 1.8
				h.set_combat_directive("frontline", focus, anchor, 0.8)
				if plan == "PRESS SOVEREIGN" and focus == sov and confidence > 45.0:
					h.try_challenge(sov)
			"rogue":
				var flank_sign := -1.0 if h.get_instance_id() % 2 == 0 else 1.0
				var flank := focus_pos + side * 2.6 * flank_sign - toward * 0.6
				flank = _clamp_to_semantic_room(flank, focus_pos)
				h.set_combat_directive("flank", focus, flank, 0.8)
			"cleric":
				h.set_combat_directive("support", focus, center - toward * 3.0, 0.8)
			"wizard":
				h.set_combat_directive("ranged", focus, center - toward * 3.8 + side * 1.2, 0.8)
			_:
				h.set_combat_directive("frontline", focus, center + toward, 0.8)

func _clamp_to_semantic_room(point: Vector3, reference: Vector3) -> Vector3:
	var room_id := RoomGraph.room_of_pos(reference)
	if not Defs.ROOMS.has(room_id):
		return point
	var r := Defs.room_rect(room_id).grow(-1.0)
	return Vector3(
		clampf(point.x, r.position.x, r.end.x),
		point.y,
		clampf(point.z, r.position.y, r.end.y)
	)

func _priority_enemy(pos: Vector3, radius: float) -> Node:
	var best: Node = null
	var best_score := -INF
	for n in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if not is_instance_valid(n) or n.state == Minion.S.DEAD:
			continue
		var d := (n as Node3D).global_position.distance_to(pos)
		if d > radius:
			continue
		var score := 30.0 - d
		var m := n as Minion
		if m.is_lieutenant:
			score += 18.0
		if m.type_id == "brute":
			score += 5.0
		if score > best_score:
			best_score = score
			best = n
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov != null and is_instance_valid(sov) and not sov.dead:
		var ds := (sov as Node3D).global_position.distance_to(pos)
		if ds <= radius:
			var ss := 20.0 - ds
			if ss > best_score:
				best = sov
	return best

func _prime_retreat_cover(alive: Array) -> void:
	if _retreat_cover_used:
		return
	_retreat_cover_used = true
	var rogue := find_role("rogue")
	if rogue != null and rogue.resource("smoke") > 0 			and rogue.spend_resource("smoke", "party_retreat"):
		for h in alive:
			h.grant_retreat_haste(5.0)
		Safe.tel().ev("party_smoke_retreat", {"members": alive.size()})
		Safe.gs().el("Smoke floods the corridor — the party disengages under cover.")

func confidence_band() -> String:
	if confidence > 65.0:
		return "CONFIDENT"
	if confidence > 30.0:
		return "PRESSURED"
	return "BROKEN"

func party_resource_fraction() -> float:
	var alive := live_members()
	if alive.is_empty():
		return 0.0
	var total := 0.0
	for h in alive:
		total += h.resource_fraction()
	return total / float(alive.size())

func current_objective_label() -> String:
	match objective:
		"consecrate_crypt": return "CONSECRATE SOUL BELL"
		"disable_gate": return "SABOTAGE GATE CONTROLS"
		"free_prisoner": return "FREE THE PRISONER"
		"kill_sovereign": return "SLAY THE SOVEREIGN"
		"steal_relic": return "STEAL THE RELIC"
		_: return objective.replace("_", " ").to_upper()

func state_label() -> String:
	if state < 0 or state >= P.keys().size():
		return "UNKNOWN"
	return str(P.keys()[state])

func player_status_line() -> String:
	var focus := (" · FOCUS " + combat_focus_label.to_upper()) if combat_focus_label != "" else ""
	var line := "%s · %s%s\nPOSITION: %s · DEPTH %d%%\nOBJECTIVE: %s\n%s · RESOURCES %d%%" % [
		str(doctrine).to_upper(), combat_plan, focus, current_room_label(),
		roundi(raid_depth_for_room(_last_progress_room) * 100.0), current_objective_label(),
		confidence_band(), roundi(party_resource_fraction() * 100.0)]
	var breach := breach_progress()
	if breach >= 0.0:
		line += "\n⚠ BREACHING — %d%%" % roundi(breach * 100.0)
	var work := active_work_summary()
	if work != "":
		line += "\n⚠ CHANNEL: " + work
	return line

func active_work_summary() -> String:
	for h in live_members():
		if h.is_working():
			return "%s — %s (%.1fs)" % [
				h.display_name, h.work_label.replace("_", " ").to_upper(), maxf(0.0, h.work_left)]
	return ""

func _announce_current_objective() -> void:
	Safe.tel().ev("party_objective_active", {"objective": objective, "doctrine": doctrine,
		"index": objective_index})
	var gs := Safe.gs()
	if gs != null:
		gs.banner.emit("HERO OBJECTIVE — %s" % current_objective_label(),
			"%s is attempting to dismantle your Domain." % label)

func _actor_label(actor: Node) -> String:
	if actor == null or not is_instance_valid(actor):
		return ""
	if actor is Sovereign:
		return "Dark Sovereign"
	if actor is Hero:
		return (actor as Hero).display_name
	if actor is Minion:
		var m := actor as Minion
		return str(m.get_meta("lt_name", m.def.get("label", "Minion")))
	return actor.name

func _on_trap_hit(hero: Hero, socket_id: String) -> void:
	confidence -= 15.0
	if rogue_saw_trap == "":
		rogue_saw_trap = socket_id
	Safe.gs().el("%s is skewered by spikes!" % hero.def["label"])

func _on_hero_died(hero: Hero) -> void:
	confidence -= 30.0
	if hero.carrying_relic:
		relic_stolen = false
	# Free any staged activity this hero was performing (softlock guard):
	for id in fortress.interactables.keys():
		var it = fortress.interactables[id]
		if it.get("worker", null) == hero:
			it["being_worked"] = false
			it["worker"] = null
	_retry_breach_if_stalled()
	Safe.gs().el("%s falls!" % hero.def["label"])

var escaped_roles: Array = []

func _on_hero_escaped(hero: Hero) -> void:
	escaped_roles.append(hero.role)
	if hero.hero_id != "":
		escaped_heroes.append(hero.identity_snapshot())
	members.erase(hero)
	if live_members().is_empty() and not resolved:
		# A defeated named hero still on the floor gets the same capture grace
		# even if every mobile companion has already escaped.
		if not capturable_named_down().is_empty():
			_capture_grace_left = maxf(_capture_grace_left, 6.0)
			return
		_finish_dict({
			"outcome": "fled",
			"escaped_roles": escaped_roles,
			"used_sally": used_sally,
			"discovered_sally": discovered_sally,
			"saw_trap": rogue_saw_trap,
			"relic_stolen": relic_stolen,
			"objective": objective,
			"objective_successes": objective_successes.duplicate(),
			"lair_system_disabled": lair_system_disabled,
			"escaped_heroes": escaped_heroes.duplicate(true),
			"captured_ids": captured_ids.duplicate(),
			"named_launched": named_launched.duplicate(),
		})

func _finish(outcome: String) -> void:
	_finish_dict({"outcome": outcome, "escaped_roles": escaped_roles, "used_sally": used_sally,
		"saw_trap": rogue_saw_trap, "relic_stolen": relic_stolen,
		"objective": objective, "objective_successes": objective_successes.duplicate(),
		"lair_system_disabled": lair_system_disabled})

func _finish_dict(result: Dictionary) -> void:
	if resolved:
		return
	result["escaped_heroes"] = result.get("escaped_heroes", escaped_heroes.duplicate(true))
	result["captured_ids"] = result.get("captured_ids", captured_ids.duplicate())
	result["named_launched"] = result.get("named_launched", named_launched.duplicate())
	result["sovereign_slain"] = sovereign_slain_this_raid
	resolved = true
	party_resolved.emit(result)

# --------------------------------------------------------------- helpers -----
func find_role(r: String) -> Hero:
	for h in live_members():
		if h.role == r:
			return h
	return null

func _order_move(group: Array, point: Vector3, spread: float) -> void:
	var i := 0
	for h in group:
		var ang := float(i) * 2.39996
		var off := Vector3(cos(ang), 0, sin(ang)) * (spread * sqrt(float(i)))
		h.has_goal = true
		h.set_destination(point + off)   # per-hero semantic pathing
		i += 1

func _centroid(group: Array) -> Vector3:
	var c := Vector3.ZERO
	if group.is_empty():
		return c
	for h in group:
		c += h.global_position
	return c / float(group.size())

func _avg_dist(group: Array, point: Vector3) -> float:
	if group.is_empty():
		return 999.0
	var d := 0.0
	for h in group:
		d += h.global_position.distance_to(point)
	return d / float(group.size())

func _max_dist(group: Array, point: Vector3) -> float:
	var d := 0.0
	for h in group:
		d = maxf(d, h.global_position.distance_to(point))
	return d

func _enemy_within(group: Array, radius: float) -> bool:
	return _nearest_enemy_to(_centroid(group), radius) != null

func _nearest_enemy_to(pos: Vector3, radius: float) -> Node:
	var best: Node = null
	var bd := radius
	for n in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if not is_instance_valid(n) or n.state == Minion.S.DEAD:
			continue
		var d: float = n.global_position.distance_to(pos)
		if d < bd:
			bd = d
			best = n
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov != null and is_instance_valid(sov) and not sov.dead:
		var ds: float = sov.global_position.distance_to(pos)
		if ds < bd:
			best = sov
	return best

func _nearest_hero(pos: Vector3) -> Hero:
	var best: Hero = null
	var bd := 99999.0
	for h in live_members():
		var d: float = h.global_position.distance_to(pos)
		if d < bd:
			bd = d
			best = h
	return best

func _trap_near(pos: Vector3, radius: float) -> Dictionary:
	for id in fortress.interactables.keys():
		var it: Dictionary = fortress.interactables[id]
		if it["kind"] == "trap" and pos.distance_to(it["pos"]) < radius:
			return it
	return {}

func _locked_door_near(pos: Vector3, radius: float) -> Dictionary:
	for id in fortress.interactables.keys():
		var it: Dictionary = fortress.interactables[id]
		if it["kind"] == "door" and it.get("locked", false) and pos.distance_to(it["pos"]) < radius:
			return it
	return {}