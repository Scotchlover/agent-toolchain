# Main — wires simulation data to the 3D runtime and owns the game loop:
# Sovereign input, horde commands, expeditions, defenses, UI, save hooks.
extends Node3D

var fortress: FortressBuilder
var sovereign: Sovereign
var cam_rig: CameraRig
var horde: HordeManager
var hud: HUD
var world_map: WorldMap
var debug_overlay: DebugOverlay
var party: PartyController = null
var perimeter: PerimeterBuilder = null
var interception: InterceptionController = null
var intercepting_expedition_id := ""

var _respawn_t := 0.0
var _trap_triggered := {}     # per-expedition trap triggers
var _last_invasion_alarm := 0
var _soul_bell_pulse := 0.0
var _soul_bell_extra_waves := 0
var _sfx_players: Array = []
var _sfx_idx := 0
var _sfx_last: Dictionary = {}   # cue -> last play ms (throttle)

func play_sfx(cue: String, throttle_ms := 70) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_sfx_last.get(cue, -10000)) < throttle_ms:
		return
	_sfx_last[cue] = now
	if _sfx_players.is_empty():
		for i in range(6):
			var p := AudioStreamPlayer.new()
			p.volume_db = -6.0
			add_child(p)
			_sfx_players.append(p)
	var p2: AudioStreamPlayer = _sfx_players[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_players.size()
	p2.stream = Sfx.stream(cue)
	p2.play()


## Transient 3D marker: expanding/fading emissive mesh, auto-freed.
func spawn_marker(pos: Vector3, size: Vector3, color: Color, life := 1.2, flat := false) -> void:
	var mi := MeshInstance3D.new()
	var mesh: Mesh = BoxMesh.new() if not flat else CylinderMesh.new()
	if flat:
		(mesh as CylinderMesh).top_radius = 0.5
		(mesh as CylinderMesh).bottom_radius = 0.5
		(mesh as CylinderMesh).height = 0.06
	else:
		(mesh as BoxMesh).size = Vector3.ONE
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mi.material_override = mat
	mi.position = pos + (Vector3(0, 0.05, 0) if flat else Vector3.ZERO)
	add_child(mi)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", size, life * 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, life).set_delay(life * 0.35)
	tw.chain().tween_interval(0.05)
	tw.chain().tween_callback(mi.queue_free)


## Small impact spark at a victim — player-facing feedback only.
func spawn_impact(pos: Vector3, color: Color = Color(1.0, 0.5, 0.25)) -> void:
	spawn_marker(pos + Vector3(0, 1.0, 0), Vector3(0.9, 0.9, 0.9), color, 0.28)

# Outdoor raid state (played village assault).
var village: VillageBuilder = null
var outdoor_region := ""      # "" while in the fortress

func shutdown_sfx() -> void:
	for player in _sfx_players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
			player.queue_free()
	_sfx_players.clear()
	_sfx_idx = 0
	Sfx.clear_cache()

func _exit_tree() -> void:
	# Normal application shutdown shares the explicit teardown path used by
	# accelerated headless tests.
	shutdown_sfx()

func _ready() -> void:
	Safe.gs().main = self
	fortress = FortressBuilder.new()
	add_child(fortress)
	fortress.build()

	sovereign = Sovereign.new()
	add_child(sovereign)
	sovereign.global_position = Defs.SOVEREIGN_SPAWN
	sovereign.died.connect(_on_sovereign_died)
	sovereign.hit_landed.connect(func(n: int):
		cam_rig.shake = maxf(cam_rig.shake, 0.35 + 0.1 * n)
		play_sfx("thud", 60))

	cam_rig = CameraRig.new()
	add_child(cam_rig)
	cam_rig.global_position = sovereign.global_position + Vector3(0, 1.9, 0)
	cam_rig.setup(sovereign)
	cam_rig.yaw = PI   # face north into the hall

	horde = HordeManager.new()
	add_child(horde)
	horde.setup(sovereign, fortress, self)

	hud = HUD.new()
	add_child(hud)
	hud.build()
	# v0.2 authored this layer but left it behind a bisection switch. The
	# physical throne/War Table/Treasury/Soul Bell are now part of runtime.
	fortress.build_lair_identity()
	world_map = WorldMap.new()
	add_child(world_map)
	world_map.build()
	debug_overlay = DebugOverlay.new()
	add_child(debug_overlay)
	debug_overlay.build()

	Safe.gs().expedition_requested.connect(_spawn_expedition)
	Safe.gs().banner.connect(func(t: String, s: String): hud.queue_banner(t, s))
	world_map.raid_requested.connect(start_outdoor_raid)
	world_map.upgrade_requested.connect(_buy_upgrade)
	world_map.intercept_requested.connect(_start_interception)
	for id in fortress.interactables.keys():
		var it = fortress.interactables[id]
		if it["kind"] == "trap":
			it["area"].body_entered.connect(_on_trap_body.bind(id))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Safe.gs().el("You are the Dark Sovereign. Your horde waits. TAB — the world beyond.")
	_set_objective_idx(0)
	fortress.refresh_domain_visuals(GS.world.gold, GS.domain.upgrades)
	fortress.refresh_prison_visual()


# ---- v0.2 objective chain (§15/§17): Exposition → Validation → Challenge ----
func _set_objective_idx(idx: int) -> void:
	objective_idx = clampi(idx, 0, Defs.OBJECTIVE_CHAIN.size() - 1)
	var o: Dictionary = Defs.OBJECTIVE_CHAIN[objective_idx]
	hud.set_objective(str(o["text"]))
	Safe.tel().ev("objective_shown", {"id": str(o["id"])})


func _complete_objective(objective_id: String) -> void:
	if objective_idx >= Defs.OBJECTIVE_CHAIN.size():
		return
	var cur: Dictionary = Defs.OBJECTIVE_CHAIN[objective_idx]
	if str(cur["id"]) != objective_id:
		return
	Safe.tel().ev("objective_completed", {"id": objective_id})
	match objective_id:
		"rally":
			GS.el("Grashnak: «The mines have stopped paying tribute, my lord.»")
			_set_objective_idx(1)   # consult the war table
		"war_table":
			_set_objective_idx(2)   # seize the mines
		"raid_mines":
			_set_objective_idx(3)   # spend the spoils
		"spend":
			_set_objective_idx(4)   # grow the dominion


## Called from _unhandled_input for every issued horde command (readability+telemetry).
func notify_command_issued(action: String) -> void:
	TEL.ev("input_action", {"action": action,
		"sov_z": snappedf(sovereign.global_position.z, 0.1)})
	if action == "cmd_follow":
		_complete_objective("rally")

# ------------------------------------------------------------------ loop -----
func _process(dt: float) -> void:
	Safe.gs().tick_world(dt)
	_sync_invasion_alarm()
	_animate_portcullis(dt)
	_update_power()
	hud.update_hud(sovereign, horde)
	if party != null and not party.resolved:
		_update_soul_bell(dt)
	if interception != null:
		_update_interception_prompt()
	elif outdoor_region != "":
		_update_outdoor()
	else:
		_update_prompt()
	if not sovereign.dead:
		_respawn_t = 0.0
	elif outdoor_region == "" and interception == null:
		_respawn_t += dt
		if _respawn_t > 5.0:
			sovereign.revive(Defs.SOVEREIGN_SPAWN)
			Safe.gs().world.add_fear(-10)
			Safe.gs().el("The Sovereign reforms upon his throne.")

func _update_power() -> void:
	Safe.gs().world.compute_power(Safe.gs().minions_alive, Safe.gs().domain.upgrade_count())

func _physics_process(_dt: float) -> void:
	pass

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		world_map.toggle(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE else Input.MOUSE_MODE_VISIBLE
		return
	if event.is_action_pressed("world_map"):
		if interception != null:
			Safe.gs().el("The battle is here — no time for the War Table.")
		else:
			world_map.toggle()
		return
	if event.is_action_pressed("save"):
		if _physical_conflict_active():
			Safe.gs().el("Cannot save while a battle is physically in progress.")
		else:
			Safe.gs().save_game()
		return
	if event.is_action_pressed("load"):
		if _physical_conflict_active():
			Safe.gs().el("Cannot load while a battle is physically in progress.")
			return
		if Safe.gs().load_game():
			fortress.refresh_domain_visuals(Safe.gs().world.gold, Safe.gs().domain.upgrades)
			fortress.refresh_prison_visual()
			fortress.reset_lair_system_visuals()
			fortress.reset_raid_progress_visuals()
		return
	if event.is_action_pressed("debug_horde"):
		debug_overlay.cycle(1); return
	if event.is_action_pressed("debug_party"):
		debug_overlay.cycle(2); return
	if event.is_action_pressed("debug_world"):
		debug_overlay.cycle(3); return
	if world_map.open:
		return
	if sovereign.dead:
		return
	for a in ["attack", "ability", "execute", "interact", "cmd_follow", "cmd_hold", "cmd_hunt"]:
		if event.is_action_pressed(a):
			notify_command_issued(a)
			break
	if event.is_action_pressed("cmd_follow"):
		horde.issue_follow()
	elif event.is_action_pressed("cmd_hold"):
		horde.issue_hold(cam_rig.crosshair_point())
	elif event.is_action_pressed("cmd_hunt"):
		var t := cam_rig.crosshair_actor(Combat.MASK_HERO)
		if t == null:
			t = _nearest_exposed_hero()
		if t == null:
			t = _nearest_enemy_actor()
		horde.issue_hunt(t)
	elif event.is_action_pressed("interact"):
		if not _outdoor_interact():
			_do_interact()
	elif event.is_action_pressed("execute"):
		_do_execute()

func _nearest_exposed_hero(radius: float = 18.0) -> Hero:
	var best: Hero = null
	var bd := radius
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if not is_instance_valid(h) or h.is_down() or not h.has_method("is_guard_broken") 				or not h.is_guard_broken():
			continue
		var d := _flat_dist((h as Node3D).global_position, sovereign.global_position)
		if d < bd:
			bd = d
			best = h
	return best

func _nearest_enemy_actor() -> Node:
	# Open-field raids need a longer command eye than fortress corridors.
	# Horizontal distance only: fallen bodies must not blind the command view.
	var bd := 90.0 if outdoor_region != "" else 26.0
	var best: Node = null
	var sov_pos := sovereign.global_position
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if not is_instance_valid(h):
			continue
		var d: float = _flat_dist((h as Node3D).global_position, sov_pos)
		if d < bd:
			bd = d
			best = h
	for g in get_tree().get_nodes_in_group("militia"):
		if not is_instance_valid(g) or g.dead:
			continue
		var d2: float = _flat_dist((g as Node3D).global_position, sov_pos)
		if d2 < bd:
			bd = d2
			best = g
	return best

func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _physical_conflict_active() -> bool:
	return outdoor_region != "" or interception != null or (party != null and not party.resolved)

# --------------------------------------------------------------- commands ----
func _do_interact() -> void:
	# Capturing a named defeated hero outranks ambient fortress interactions.
	var captive_candidate := _nearest_capturable_named_hero()
	if captive_candidate != null:
		_capture_named_hero(captive_candidate)
		return

	# Contextual: war table / trap socket / sally seal / portcullis winch.
	var wt = fortress.interactables.get("war_table", null)
	if wt != null and sovereign.global_position.distance_to(wt["pos"]) < 3.0:
		world_map.toggle(true)
		_complete_objective("war_table")
		Safe.tel().ev("war_table_open", {})
		return
	for id in fortress.interactables.keys():
		var it = fortress.interactables[id]
		if it["kind"] == "trap" and sovereign.global_position.distance_to(it["pos"]) < 2.2:
			Safe.gs().domain.toggle_trap(id)
			fortress.set_trap_armed(id, Safe.gs().domain.traps_armed[id])
			Safe.gs().el("%s %s." % [id.replace("_", " ").capitalize(), "ARMED" if Safe.gs().domain.traps_armed[id] else "DISARMED"])
			return
		if it["kind"] == "sally" and not it["sealed"] and sovereign.global_position.distance_to(it["pos"]) < 3.0:
			it["sealed"] = true
			Safe.gs().domain.seal_sally()
			it["visual"].scale = Vector3(1.4, 2.0, 1.6)
			it["seal_shape"].disabled = false
			Safe.gs().el("The crypt sally port is SEALED with rubble.")
			return
	if sovereign.global_position.distance_to(fortress.interactables["gate_portcullis"]["pos"]) < 7.0 \
			or horde.nearest_minion_dist_to(fortress.interactables["gate_portcullis"]["pos"]) < 14.0:
		horde.issue_portcullis_toggle()
		return
	Safe.gs().el("Nothing to command here.")

func _nearest_capturable_named_hero(radius: float = 3.2) -> Hero:
	if party == null or party.resolved:
		return null
	var best: Hero = null
	var bd := radius
	for h in party.capturable_named_down():
		var d: float = h.global_position.distance_to(sovereign.global_position)
		if d < bd:
			bd = d
			best = h
	return best

func _capture_named_hero(hero: Hero) -> void:
	if party == null or hero == null:
		return
	var snap := party.capture_hero(hero)
	if snap.is_empty():
		return
	var id := str(snap.get("hero_id", ""))
	var state: Dictionary = Safe.gs().world.capture_named_hero(id)
	if state.is_empty():
		return
	Safe.gs().world.add_fear(8)
	Safe.gs().world.add_threat(8)
	fortress.refresh_prison_visual()
	hud.queue_banner("A CHAMPION IN CHAINS",
		"%s is imprisoned. The Church will not ignore this." % str(state["name"]))
	Safe.tel().ev("named_hero_captured", {"hero_id": id, "name": str(state["name"]),
		"captures": int(state.get("captures", 1))})
	Safe.gs().el("%s is dragged to the Iron Prison." % str(state["name"]))

func _do_execute() -> void:
	for h in horde.get_pinned_heroes():
		if h.global_position.distance_to(sovereign.global_position) < 3.4:
			sovereign.global_position = h.global_position - (h.global_position - sovereign.global_position).normalized() * 1.2
			h.take_damage(150.0, sovereign)
			Safe.tel().hit(h, 150.0, sovereign)
			spawn_impact(h.global_position, Color(1.0, 0.2, 0.15))
			play_sfx("execute", 0)
			cam_rig.shake = 0.9
			sovereign.hp = minf(sovereign.max_hp, sovereign.hp + 20.0)
			Safe.gs().el("EXECUTED. The horde roars.")
			cam_rig.shake = 1.0
			return
	Safe.gs().el("No pinned victim within reach.")

# ---------------------------------------------------------------- prompts ----
func _update_prompt() -> void:
	if sovereign.dead:
		hud.set_prompt("The throne stands empty...")
		return
	var capturable := _nearest_capturable_named_hero()
	if capturable != null:
		hud.set_prompt("[E] CAPTURE %s" % capturable.display_name.to_upper())
		return
	for id in fortress.interactables.keys():
		var it = fortress.interactables[id]
		if it["kind"] == "trap" and sovereign.global_position.distance_to(it["pos"]) < 2.2:
			hud.set_prompt("[E] %s spikes (%s)" % ["ARM" if not Safe.gs().domain.traps_armed[id] else "DISARM", id.replace("_", " ")])
			return
		if it["kind"] == "sally" and not it["sealed"] and sovereign.global_position.distance_to(it["pos"]) < 3.0:
			hud.set_prompt("[E] SEAL the sally port forever")
			return
	var pinned := horde.get_pinned_heroes()
	for h in pinned:
		if h.global_position.distance_to(sovereign.global_position) < 3.4:
			hud.set_prompt("[F] EXECUTE the %s!" % h.display_name)
			return
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if not is_instance_valid(h) or h.is_down() or not h.has_method("is_guard_broken"):
			continue
		if h.is_guard_broken() and h.global_position.distance_to(sovereign.global_position) < 18.0:
			hud.set_prompt("[3] HUNT %s — Skitterers exploit EXPOSED" % h.display_name.to_upper())
			return
	if sovereign.global_position.distance_to(fortress.interactables["gate_portcullis"]["pos"]) < 8.0:
		var open_now: bool = fortress.interactables["gate_portcullis"]["target_y"] >= fortress.interactables["gate_portcullis"]["raised_y"]
		hud.set_prompt("[E] horde winch — %s portcullis (needs 4)" % ["LOWER" if open_now else "RAISE"])
		return
	hud.set_prompt("")

# ------------------------------------------------------------- portcullis ----
func _animate_portcullis(dt: float) -> void:
	var gate = fortress.interactables["gate_portcullis"]
	var body: AnimatableBody3D = gate["body"]
	body.position.y = move_toward(body.position.y, float(gate["target_y"]), dt * 2.2)

# ------------------------------------------------------------------ traps ----
func _on_trap_body(body: Node3D, id: String) -> void:
	if not Safe.gs().domain.traps_armed.get(id, false):
		return
	if not body is Hero or body.is_down():
		return
	if _trap_triggered.get(id, false):
		return
	_trap_triggered[id] = true
	body.take_damage(float(Defs.TRAP_SOCKETS[id]["dmg"]))
	Safe.tel().hit(body, float(Defs.TRAP_SOCKETS[id]["dmg"]), null)
	if party != null:
		party._on_trap_hit(body as Hero, id)
	fortress.set_trap_armed(id, false)
	Safe.gs().domain.traps_armed[id] = false

# ------------------------------------------------------------ expeditions ----
func _on_party_resolved(result: Dictionary) -> void:
	Safe.gs().expedition_active = false
	var w: WorldState = Safe.gs().world
	w.mark_expedition_resolved()
	var launched: int = party.launched if party != null else 4
	var escaped: Array = result.get("escaped_roles", [])
	var captured_named: Array = result.get("captured_ids", [])
	var killed := maxi(0, launched - escaped.size() - captured_named.size())
	var successes: Array = result.get("objective_successes", [])
	var disabled_system := str(result.get("lair_system_disabled", ""))
	var def_id := str(party.recipe.get("def_id", "")) if party != null else ""
	var escaped_named: Array = []
	for h in result.get("escaped_heroes", []):
		var hid := str(h.get("hero_id", ""))
		if hid != "" and not escaped_named.has(hid):
			escaped_named.append(hid)
	var launched_named: Array = result.get("named_launched", [])
	w.resolve_named_outcomes(launched_named, escaped_named, captured_named)
	if def_id != "":
		w.clear_hostile_cycle(def_id)
	Safe.tel().ev("expedition_end", {
		"relic_stolen": bool(result.get("relic_stolen", false)),
		"slain": killed, "escaped_roles": escaped,
		"used_sally": bool(result.get("used_sally", false)),
		"objective_successes": successes,
		"lair_system_disabled": disabled_system,
		"named_escaped": escaped_named,
		"named_captured": captured_named,
	})

	if result.get("relic_stolen", false):
		w.add_fear(-15)
		w.gold = maxi(0, w.gold - 30)
		w.last_result = "The relic was STOLEN."
	elif successes.has("kill_sovereign"):
		w.add_fear(-20)
		w.add_threat(+12)
		w.last_result = "The expedition slew the Sovereign and escaped his halls."
	elif not successes.is_empty():
		w.add_fear(-6)
		w.add_threat(+8)
		w.gold += 10 * killed
		w.last_result = "Raiders damaged the Domain before being driven out."
	else:
		w.add_fear(+10)
		w.add_threat(+5)
		w.gold += 20 * killed
		w.last_result = "Expedition repelled. %d adventurers slain." % killed

	var taught_sally := bool(result.get("used_sally", false)) or bool(result.get("discovered_sally", false))
	Expedition.record_knowledge(w, escaped, str(result.get("saw_trap", "")), taught_sally)
	Safe.gs().el("RAID OVER — %s" % w.last_result)
	if disabled_system != "":
		Safe.gs().el("%s was compromised during the raid." % Defs.LAIR_SYSTEMS[disabled_system]["label"])
	if result.get("used_sally", false) and not escaped.is_empty():
		Safe.gs().el("They came through the crypt! They knew the way.")

	party.queue_free()
	party = null
	horde.remuster(self)
	Safe.gs().domain.reset_raid_systems()
	fortress.reset_defenses()
	fortress.reset_lair_system_visuals()
	fortress.reset_raid_progress_visuals()
	fortress.refresh_prison_visual()
	Safe.gs().save_game()
	_spawn_next_pending_expedition()

func _on_sovereign_died() -> void:
	if interception != null and not interception.finished:
		Safe.gs().world.sovereign_deaths += 1
		Safe.gs().el("The Sovereign falls at the perimeter — the expedition breaks through!")
		interception.force_sovereign_defeat()
		return
	Safe.gs().world.sovereign_deaths += 1
	if party != null and not party.resolved:
		party.notify_sovereign_fallen()
		hud.queue_banner("THE DARK LORD HAS FALLEN",
			"The raiders press their advantage while the throne reforms its master.")
		Safe.tel().ev("sovereign_fallen_during_raid", {
			"deaths": Safe.gs().world.sovereign_deaths,
			"party_confidence": party.confidence,
		})
	Safe.gs().el("The Sovereign FALLS! ...but death is a door he owns.")

# ----------------------------------------------------------- interception ----
func _start_interception(expedition_id: String) -> void:
	if _physical_conflict_active():
		Safe.gs().el("Another battle already demands the Sovereign.")
		return
	var e: Dictionary = Safe.gs().world.begin_interception(expedition_id)
	if e.is_empty():
		Safe.gs().el("That expedition can no longer be intercepted.")
		return
	intercepting_expedition_id = expedition_id
	Safe.gs().expedition_active = true
	perimeter = PerimeterBuilder.new()
	add_child(perimeter)
	perimeter.build()
	if sovereign.dead:
		sovereign.revive(perimeter.sovereign_spawn)
	else:
		sovereign.global_position = perimeter.sovereign_spawn
	_move_horde_to(perimeter.horde_spawn)
	interception = InterceptionController.new()
	add_child(interception)
	interception.setup(e, self, perimeter.expedition_spawn, perimeter.breakthrough_pos)
	interception.resolved.connect(_on_interception_resolved)
	hud.queue_banner("INTERCEPTION", "Break %s before it reaches your gates." % str(e["label"]))
	Safe.tel().ev("interception_runtime_started", {"id": expedition_id,
		"heroes": int(e["recipe"].get("roles", []).size())})
	Safe.gs().el("The Sovereign rides out to intercept %s." % str(e["label"]))

func _update_interception_prompt() -> void:
	if interception == null:
		return
	if sovereign.dead:
		hud.set_prompt("The expedition breaks through while the Sovereign reforms...")
	else:
		hud.set_prompt("INTERCEPTION — break them here or they reach the fortress.")

func _move_horde_to(spawn: Vector3) -> void:
	var index := 0
	for cc in horde.cohorts:
		for m in cc.members:
			if is_instance_valid(m) and m.state != Minion.S.DEAD:
				m.global_position = spawn + Vector3((index % 5 - 2) * 1.25, 0.6, float(index / 5) * 1.3)
				index += 1
		cc.command_follow()

func _on_interception_resolved(expedition_id: String, outcome: String, survivors: Array) -> void:
	# The signal can arrive from physics processing; finalize on the idle boundary.
	call_deferred("_finalize_interception", expedition_id, outcome, survivors)

func _finalize_interception(expedition_id: String, outcome: String, survivors: Array) -> void:
	if interception == null or expedition_id != intercepting_expedition_id:
		return
	var original_roles: Array = interception.expedition["recipe"].get("roles", []).duplicate(true)
	var launched_named: Array = Safe.gs().world.named_ids_from_roles(original_roles)
	var survivor_named: Array = Safe.gs().world.named_ids_from_roles(survivors)
	for hid in launched_named:
		if not survivor_named.has(hid):
			Safe.gs().world.mark_named_hero_dead(str(hid))
	var resolution: Dictionary = Safe.gs().world.resolve_interception(expedition_id, outcome, survivors)
	var cancelled := bool(resolution.get("cancelled", true))
	var e: Dictionary = resolution.get("expedition", {})
	var label := str(e.get("label", "Expedition"))
	Safe.gs().expedition_active = false

	if sovereign.dead:
		Safe.gs().world.add_fear(-5)
		sovereign.revive(Defs.SOVEREIGN_SPAWN)
	else:
		sovereign.global_position = Defs.SOVEREIGN_SPAWN
	horde.return_home(Defs.HORDE_SPAWN)

	interception.queue_free()
	interception = null
	if perimeter != null:
		perimeter.queue_free()
		perimeter = null
	intercepting_expedition_id = ""

	if cancelled:
		for hid in survivor_named:
			Safe.gs().world.note_named_hero_escape(str(hid))
		var def_id := str(e.get("def_id", ""))
		if def_id != "":
			Safe.gs().world.clear_hostile_cycle(def_id)
		Safe.gs().world.last_result = "%s broken at the Domain perimeter." % label
		Safe.gs().world.add_fear(8)
		hud.queue_banner("EXPEDITION BROKEN", "%s turns back before reaching the fortress." % label)
		Safe.gs().el("%s ABORTS after the border battle." % label)
	else:
		hud.queue_banner("THEY SURVIVED THE AMBUSH",
			"%d battered adventurers continue toward the fortress." % survivors.size())
		Safe.gs().el("%s survives the interception — wounded and depleted." % label)
	Safe.tel().ev("interception_finalized", {"id": expedition_id, "outcome": outcome,
		"cancelled": cancelled, "survivors": survivors.size()})
	fortress.refresh_domain_visuals(GS.world.gold, GS.domain.upgrades)
	fortress.refresh_prison_visual()
	Safe.gs().save_game()
	_spawn_next_pending_expedition()


# ------------------------------------------------------- village assault -----
# Played skirmish outside the walls (mandate §18.2): the Sovereign personally
# leads the horde out, breaks the militia, seizes tribute.
func start_outdoor_raid(region_id: String) -> void:
	if outdoor_region != "":
		Safe.gs().el("Your warband is already in the field.")
		return
	if Safe.gs().expedition_active:
		Safe.gs().el("Raiders are inside your halls — defend first!")
		return
	outdoor_region = region_id
	village = VillageBuilder.new()
	add_child(village)
	village.build(region_id)
	TEL.ev("assault_begin", {"region": region_id})
	_assault_snapshot = {"gold": GS.world.gold, "fear": GS.world.fear,
		"threat": GS.world.threat, "minions": GS.minions_alive}
	var v: Dictionary = Defs.SITES[region_id]
	sovereign.global_position = village.entry_pos + Vector3(0, 0.4, 3)
	for cc in horde.cohorts:
		var i := 0
		for m in cc.members:
			if is_instance_valid(m):
				m.global_position = village.entry_pos + Vector3(randf_range(-3, 3) + i * 0.2, 0.6, randf_range(1.5, 5))
				i += 1
		cc.command_follow()
	var defender_mix := ["shield", "spearman", "archer"]
	var defender_idx := 0
	for s in v["spawns"]:
		var g := Grunt.new()
		g.setup(v, false, defender_mix[defender_idx % defender_mix.size()])
		defender_idx += 1
		g.home = v["origin"] + Vector3(s[0], 0.6, s[1])
		add_child(g)
		g.global_position = g.home
	var cap := Grunt.new()
	cap.setup(v, true, "captain")
	cap.home = v["origin"] + Vector3(v["captain_spawn"][0], 0.6, v["captain_spawn"][1])
	add_child(cap)
	cap.global_position = cap.home
	Safe.gs().el("The horde marches on %s. Break them, seize the tribute." % Defs.REGIONS[region_id]["label"])

func current_site_defender_label(captain: bool) -> String:
	if outdoor_region == "":
		return "Defender"
	var site: Dictionary = Defs.SITES.get(outdoor_region, {})
	return str(site["captain_label"] if captain else site["defender_label"])

func militia_alive() -> int:
	var n := 0
	for g in get_tree().get_nodes_in_group("militia"):
		if is_instance_valid(g) and not g.dead:
			n += 1
	return n

func _update_outdoor() -> void:
	if sovereign.dead:
		end_outdoor_raid(false)
		return
	var cleared := militia_alive() == 0
	var near_chest := sovereign.global_position.distance_to(village.chest_pos) < 2.6
	if cleared and near_chest:
		hud.set_prompt("[E] SEIZE THE TRIBUTE")
	else:
		hud.set_prompt("Militia remaining: %d" % militia_alive())

func _outdoor_interact() -> bool:
	# Context action inside the played raid: claim the tribute once defended
	# positions are broken, or send minions to drag the cart early.
	if outdoor_region == "" or village == null:
		return false
	if militia_alive() > 0:
		return false
	end_outdoor_raid(true)
	return true

func end_outdoor_raid(victory: bool) -> void:
	var region_id := outdoor_region
	outdoor_region = ""
	Safe.tel().ev("assault_end", {"region": region_id, "victory": victory,
		"minions_left": Safe.gs().minions_alive})
	if victory:
		var before: Dictionary = _assault_snapshot.duplicate()
		Safe.gs().raid_and_respond(region_id)
		var label: String = Defs.REGIONS[region_id]["label"]
		var d_gold := GS.world.gold - int(before.get("gold", 0))
		var losses := maxi(0, int(before.get("minions", 0)) - GS.minions_alive)
		hud.queue_banner("%s SUBJUGATED" % str(label).to_upper(),
			"Gold +%d   Horde losses: %d" % [d_gold, losses])
		Safe.tel().ev("assault_summary", {"region": region_id, "gold_delta": d_gold,
			"losses": losses})
		_complete_objective("raid_mines")
		# §21: the first reward must be spendable immediately — point at it.
		if GS.world.gold >= 25:
			hud.queue_banner("THE TREASURY GLEAMS",
				"War Table: new upgrades affordable.")
	else:
		GS.world.add_fear(-5)
		GS.world.add_threat(+5)
		hud.queue_banner("THE ASSAULT FAILS",
			"The survivors of %s talk." % Defs.REGIONS[region_id]["label"])
	if village != null:
		village.queue_free()
		village = null
	sovereign.global_position = Defs.SOVEREIGN_SPAWN
	if sovereign.dead:
		sovereign.revive(Defs.SOVEREIGN_SPAWN)
	horde.return_home(Defs.HORDE_SPAWN)
	fortress.refresh_domain_visuals(GS.world.gold, GS.domain.upgrades)
	_spawn_next_pending_expedition()

# ------------------------------------------------------------- upgrades ------
func _buy_upgrade(id: String) -> void:
	var u: Dictionary = Defs.UPGRADES[id]
	if Safe.gs().domain.upgrades.has(id) or Safe.gs().world.gold < int(u["cost"]):
		return
	Safe.gs().world.gold -= int(u["cost"])
	Safe.gs().domain.upgrades[id] = true
	Safe.tel().ev("upgrade_bought", {"id": id, "cost": int(u["cost"])})
	hud.queue_banner(str(u["label"]).to_upper(), str(u["desc"]))
	if id == "soul_bell":
		fortress.refresh_domain_visuals(GS.world.gold, GS.domain.upgrades)
		play_sfx("bell", 0)
	if id == "gate_reinforcement":
		fortress.apply_gate_reinforcement()
	GS.el("The %s tolls. The crypt answers." % u["label"])
	GS.save_game()
	_complete_objective("spend")

var _pending_expedition_recipes: Array = []   # arrivals wait out physical battles

# ---- v0.2 onboarding: Exposition → Validation → Challenge beat chain ----
var objective_idx := 0
var _assault_snapshot := {}   # economy before an assault, for the AAR

func _spawn_next_pending_expedition() -> void:
	if _physical_conflict_active() or _pending_expedition_recipes.is_empty():
		return
	var next: Dictionary = _pending_expedition_recipes.pop_front()
	_spawn_expedition(next)

func _sync_invasion_alarm() -> void:
	var level := 0
	if party != null and is_instance_valid(party) and not party.resolved:
		level = 2
	else:
		for e in Safe.gs().world.active_expeditions:
			if str(e.get("stage", "")) in ["approach", "intercepting"]:
				level = 1
				break
	if level == _last_invasion_alarm:
		return
	_last_invasion_alarm = level
	fortress.set_invasion_alarm(level)
	if level == 1:
		play_sfx("alarm", 1200)
	elif level == 2:
		play_sfx("breach", 1200)

func _on_raid_progress(stage: String, room_id: String, detail: String, fraction: float) -> void:
	Safe.tel().ev("raid_progress", {"stage": stage, "room": room_id,
		"detail": detail, "fraction": fraction})
	if stage != "room_entered":
		return
	fortress.mark_room_compromised(room_id)
	play_sfx("breach", 180)
	var title := ""
	var sub := "Enemy penetration: %d%%" % roundi(fraction * 100.0)
	match room_id:
		"gatehouse": title = "THE GATEHOUSE IS BREACHED"
		"great_hall": title = "THEY ARE INSIDE"
		"crypt": title = "THE CRYPT IS COMPROMISED"
		"chapel": title = "THE CHAPEL IS COMPROMISED"
		"treasury": title = "THE TREASURY IS BREACHED"
		"throne": title = "THE THRONE ROOM IS UNDER ATTACK"
		_: title = "%s COMPROMISED" % detail
	hud.queue_banner(title, sub)

func _spawn_expedition(recipe: Dictionary) -> void:
	if _physical_conflict_active():
		_pending_expedition_recipes.append(recipe.duplicate(true))
		Safe.gs().el("Another hostile force reaches the Domain while battle already rages.")
		return
	_trap_triggered.clear()
	party = PartyController.new()
	party.add_to_group("__party_debug__")
	add_child(party)
	party.setup(recipe, fortress, self)
	party.party_resolved.connect(_on_party_resolved)
	party.raid_progress.connect(_on_raid_progress)
	Safe.gs().expedition_active = true
	var edef: Dictionary = Defs.ENEMY_PROJECTS.get(str(recipe.get("def_id", "")), {})
	hud.queue_banner("EXPEDITION AT THE GATES",
		"%s — %s" % [str(recipe.get("label", "Raiders")), str(edef.get("cause", ""))])
	Safe.tel().ev("expedition_start", {"label": str(recipe.get("label", "")),
		"objective": str(recipe.get("objective", "")),
		"objectives": recipe.get("objectives", []),
		"doctrine": str(recipe.get("doctrine", "balanced")),
		"entry": str(recipe.get("entry_door", "")),
		"launched": party.launched})
	_soul_bell_pulse = 14.0
	_soul_bell_extra_waves = 0
	_raise_soul_bell_defenders()

func _raise_soul_bell_defenders() -> void:
	if not Safe.gs().domain.upgrades.has("soul_bell") 			or Safe.gs().domain.is_raid_system_disabled("soul_bell"):
		return
	horde.raise_risen(int(Defs.UPGRADES["soul_bell"]["skeletons"]), Defs.room_center("crypt"), self)
	Safe.gs().el("The Soul Bell tolls — the Risen climb from their crypt!")

func _update_soul_bell(dt: float) -> void:
	if not Safe.gs().domain.upgrades.has("soul_bell") 			or Safe.gs().domain.is_raid_system_disabled("soul_bell") 			or _soul_bell_extra_waves >= 2:
		return
	_soul_bell_pulse -= dt
	if _soul_bell_pulse > 0.0:
		return
	_soul_bell_pulse = 18.0
	_soul_bell_extra_waves += 1
	horde.raise_risen(1, Defs.room_center("crypt"), self)
	Safe.tel().ev("soul_bell_reinforcement", {"wave": _soul_bell_extra_waves})
	Safe.gs().el("The Soul Bell tolls again — another corpse answers.")
