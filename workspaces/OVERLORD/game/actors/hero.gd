# HeroAgent — one D&D-style adventurer. Local tactical execution only;
# group intent comes from PartyController. v0.3 adds finite expedition resources:
# a party can fail by body, resources or resolve rather than HP alone.
extends CharacterBody3D
class_name Hero

var role := "paladin"
var def: Dictionary
var quality := 1.0
var hero_id := ""
var display_name := ""
var traits: Array = []
var captured := false

var hp := 100.0
var max_hp := 100.0
var down := false
var staggered := 0.0
var attack_cd := 0.0
var heal_cd := 0.0
var nova_cd := 0.0

# Finite tactical resources persist for the life of this expedition.
# Keys are role-specific but snapshots are generic for travel/interception later.
var resources: Dictionary = {}
var resource_caps: Dictionary = {}

# Group-shared state (written by PartyController).
var move_goal := Vector3.ZERO
var has_goal := false
var path_pts: Array = []
var work_left := 0.0
var work_total := 0.0
var work_label := ""
var on_work_done: Callable = Callable()

var pin_pressure := 0.0
var pinned := false: set = set_pinned
var carrying_relic := false
var threat := ThreatMemory.new()

# PartyController writes short-lived combat intent here. Local behaviors still
# execute movement/attacks, but target choice is no longer four independent bots.
var combat_focus: Node = null
var combat_directive := "independent"
var combat_anchor := Vector3.ZERO
var directive_left := 0.0
var retreat_haste_left := 0.0
var evade_left := 0.0
var evade_cd := 0.0
var evade_dir := Vector3.ZERO
var guard_broken_left := 0.0

signal hero_died(hero)
signal escaped(hero)

func setup(p_role: String, p_quality: float, identity: Dictionary = {}) -> void:
	role = p_role
	quality = p_quality
	def = Defs.HERO_DEFS[p_role]
	hero_id = str(identity.get("hero_id", ""))
	display_name = str(identity.get("name", def["label"]))
	traits = identity.get("traits", []).duplicate(true)
	max_hp = def["hp"] * (0.8 + 0.2 * quality)
	hp = max_hp
	match role:
		"cleric":
			_set_resource("major_heal", 3)
			_set_resource("consecration", 2)
		"wizard":
			_set_resource("control", 2)
			_set_resource("arcane_burst", 4)
		"rogue":
			_set_resource("tools", 3)
			_set_resource("smoke", 1)
		"paladin":
			_set_resource("holy_guard", 2)
			_set_resource("challenge", 1)

func _set_resource(id: String, amount: int) -> void:
	resources[id] = amount
	resource_caps[id] = amount

func resource(id: String) -> int:
	return int(resources.get(id, 0))

func spend_resource(id: String, reason: String) -> bool:
	var n := resource(id)
	if n <= 0:
		return false
	resources[id] = n - 1
	Safe.tel().ev("hero_resource_spent", {"role": role, "hero_id": hero_id,
		"name": display_name, "resource": id,
		"reason": reason, "remaining": int(resources[id])})
	return true

func resource_fraction() -> float:
	if resource_caps.is_empty():
		return 1.0
	var have := 0.0
	var cap := 0.0
	for id in resource_caps:
		have += float(resources.get(id, 0))
		cap += float(resource_caps[id])
	return have / cap if cap > 0.0 else 1.0

func resource_snapshot() -> Dictionary:
	return resources.duplicate(true)

func restore_resources(snapshot: Dictionary) -> void:
	for id in snapshot:
		if resources.has(id):
			resources[id] = clampi(int(snapshot[id]), 0, int(resource_caps[id]))

func identity_snapshot() -> Dictionary:
	return {
		"hero_id": hero_id,
		"name": display_name,
		"role": role,
		"quality": quality,
		"traits": traits.duplicate(true),
	}

func _ready() -> void:
	add_to_group(Combat.GROUP_HEROES)
	collision_layer = Combat.MASK_HERO
	collision_mask = Combat.MASK_WORLD | Combat.MASK_MINION | Combat.MASK_SOVEREIGN | Combat.MASK_LOCKS
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	cs.shape = cap
	add_child(cs)
	var mesh := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.38
	m.height = 1.55
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = def.get("color", Color.WHITE)
	mesh.material_override = mat
	mesh.position.y = 0.8
	add_child(mesh)
	var label := Label3D.new()
	label.text = display_name
	label.font_size = 40
	label.pixel_size = 0.005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 2.1
	add_child(label)
	match role:
		"paladin":
			_prop_box(Vector3(0.55, 0.9, 0.12), Color(0.8, 0.72, 0.4), Vector3(0.62, 1.0, 0.0))
		"cleric":
			_prop_box(Vector3(0.34, 0.44, 0.1), Color(1.0, 0.95, 0.7), Vector3(0.5, 1.15, 0.1))
		"rogue":
			_prop_box(Vector3(0.08, 0.5, 0.14), Color(0.25, 0.28, 0.3), Vector3(0.45, 0.9, 0.2))
		"wizard":
			var staff := MeshInstance3D.new()
			var sm := BoxMesh.new(); sm.size = Vector3(0.07, 1.7, 0.07)
			staff.mesh = sm
			var stmat := StandardMaterial3D.new()
			stmat.albedo_color = Color(0.4, 0.3, 0.18)
			staff.material_override = stmat
			staff.position = Vector3(0.52, 0.85, 0.05)
			add_child(staff)
			var orb := MeshInstance3D.new()
			var om := SphereMesh.new(); om.radius = 0.11; om.height = 0.22
			orb.mesh = om
			var ormat := StandardMaterial3D.new()
			ormat.albedo_color = Color(0.5, 0.4, 1.0)
			ormat.emission_enabled = true
			ormat.emission = Color(0.45, 0.3, 0.95)
			orb.material_override = ormat
			orb.position = Vector3(0.52, 1.78, 0.05)
			add_child(orb)

func _prop_box(size: Vector3, color: Color, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if role == "cleric":
		mat.emission_enabled = true
		mat.emission = color * 0.6
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _physics_process(dt: float) -> void:
	if down:
		return
	if global_position.y < -15.0:
		take_damage(99999.0)
		return
	attack_cd = maxf(0.0, attack_cd - dt)
	heal_cd = maxf(0.0, heal_cd - dt)
	nova_cd = maxf(0.0, nova_cd - dt)
	staggered = maxf(0.0, staggered - dt)
	directive_left = maxf(0.0, directive_left - dt)
	retreat_haste_left = maxf(0.0, retreat_haste_left - dt)
	evade_left = maxf(0.0, evade_left - dt)
	evade_cd = maxf(0.0, evade_cd - dt)
	guard_broken_left = maxf(0.0, guard_broken_left - dt)
	if directive_left <= 0.0:
		combat_focus = null
		combat_directive = "independent"
	pin_pressure = maxf(0.0, pin_pressure - dt * 0.6)
	var sov2 := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	threat.tick(dt, sov2 if (sov2 != null and is_instance_valid(sov2) and not sov2.dead
		and (sov2 as Node3D).global_position.distance_to(global_position) < 6.5) else null)
	pinned = pin_pressure > 1.1 and _adjacent_brutes() >= 2

	if staggered > 0.0 or pinned:
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	if is_working():
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	if evade_left > 0.0:
		velocity.x = evade_dir.x * def["speed"] * 1.35
		velocity.z = evade_dir.z * def["speed"] * 1.35
		_face(evade_dir)
		move_and_slide()
		return
	_try_react_to_sovereign_telegraph()
	if evade_left > 0.0:
		velocity.x = evade_dir.x * def["speed"] * 1.35
		velocity.z = evade_dir.z * def["speed"] * 1.35
		_face(evade_dir)
		move_and_slide()
		return

	_role_behavior(dt)
	move_and_slide()

func _role_behavior(dt: float) -> void:
	if combat_directive == "retreat" and has_goal:
		var mult := 1.25 if retreat_haste_left > 0.0 else 1.0
		_steer_toward(nav_target(), float(def["speed"]) * mult, dt)
		return
	match role:
		"wizard": _wizard(dt)
		"cleric": _cleric(dt)
		_: _melee(dt)

# ------------------------------------------------------------- behaviors -----
func _melee(dt: float) -> void:
	var enemy := _nearest_enemy(9.0)
	if enemy != null:
		if role == "rogue" and combat_directive == "flank" 				and combat_anchor != Vector3.ZERO 				and global_position.distance_to(combat_anchor) > 0.9 				and global_position.distance_to((enemy as Node3D).global_position) > def["range"] * 1.1:
			_steer_toward(combat_anchor, def["speed"] * 1.08, dt)
			return
		var to: Vector3 = (enemy as Node3D).global_position - global_position
		to.y = 0
		var dist := to.length()
		if dist > def["range"]:
			_steer_toward(enemy.global_position, def["speed"], dt)
		else:
			_face(to.normalized())
			velocity.x = 0; velocity.z = 0
		if attack_cd <= 0.0:
			attack_cd = 1.3 / quality
			enemy.take_damage(def["dmg"], self)
			Safe.tel().hit(enemy, def["dmg"], self)
			if role == "paladin":
				enemy.stagger(0.25)
		return
	if has_goal:
		_steer_toward(nav_target(), def["speed"], dt)

func _cleric(dt: float) -> void:
	var wounded := _lowest_ally(Defs.HERO_DEFS["cleric"]["heal_range"])
	if wounded != null and heal_cd <= 0.0 and wounded.hp < wounded.max_hp * 0.72 and resource("major_heal") > 0:
		if spend_resource("major_heal", "triage"):
			heal_cd = 3.0
			var amount := Defs.HERO_DEFS["cleric"]["heal"] * 1.35
			var before: float = wounded.hp
			wounded.hp = minf(wounded.max_hp, wounded.hp + amount)
			Safe.tel().heal(wounded, wounded.hp - before, self)
			_heal_beam(wounded)
			Safe.gs().el("Cleric spends a major heal (%d left)." % resource("major_heal"))
	var enemy := _nearest_enemy(4.0)
	if enemy != null:
		var away: Vector3 = (global_position - (enemy as Node3D).global_position).normalized() * 3.0 + global_position
		_steer_toward(away, def["speed"], dt)
		return
	if combat_directive == "support" and combat_anchor != Vector3.ZERO 			and global_position.distance_to(combat_anchor) > 2.0:
		_steer_toward(combat_anchor, def["speed"], dt)
		return
	if has_goal:
		_steer_toward(nav_target(), def["speed"], dt)

func _wizard(dt: float) -> void:
	var enemy := _nearest_enemy(def["range"])
	if enemy != null:
		var to: Vector3 = (enemy as Node3D).global_position - global_position
		to.y = 0
		_face(Vector3(to.x, 0, to.z).normalized())
		var dist := to.length()
		if dist < 3.4 and nova_cd <= 0.0 and resource("control") > 0:
			if spend_resource("control", "frost_nova"):
				nova_cd = 12.0
				for h in Combat.actors_in_radius(get_world_3d().direct_space_state, global_position + Vector3(0, 0.6, 0), 5.0, Combat.MASK_MINION):
					h.stagger(1.4)
				Safe.gs().el("Wizard burns a control spell — frost locks the horde! (%d left)" % resource("control"))
				velocity.x = 0; velocity.z = 0
		elif dist <= def["range"]:
			velocity.x = 0; velocity.z = 0
			if attack_cd <= 0.0:
				attack_cd = 2.1 / quality
				var mult := 1.35 if spend_resource("arcane_burst", "arcane_bolt") else 0.8
				var dmg: float = float(def["dmg"]) * quality * mult
				enemy.take_damage(dmg, self)
				Safe.tel().hit(enemy, dmg, self)
				_bolt(enemy)
		else:
			_steer_toward(global_position + Vector3(to.x, 0, to.z).normalized() * 2.0, def["speed"], dt)
		return
	if combat_directive == "ranged" and combat_anchor != Vector3.ZERO 			and global_position.distance_to(combat_anchor) > 2.4:
		_steer_toward(combat_anchor, def["speed"], dt)
		return
	if has_goal:
		_steer_toward(nav_target(), def["speed"], dt)

# ----------------------------------------------------- party combat intent ----
func set_combat_directive(kind: String, focus: Node = null,
		anchor: Vector3 = Vector3.ZERO, ttl: float = 0.75) -> void:
	combat_directive = kind
	combat_focus = focus
	combat_anchor = anchor
	directive_left = maxf(directive_left, ttl)

func grant_retreat_haste(duration: float) -> void:
	retreat_haste_left = maxf(retreat_haste_left, duration)

func try_challenge(target: Node) -> bool:
	if role != "paladin" or resource("challenge") <= 0 			or target == null or not is_instance_valid(target):
		return false
	if not (target is Sovereign) or (target as Sovereign).dead:
		return false
	if global_position.distance_to((target as Node3D).global_position) > 5.5:
		return false
	if not spend_resource("challenge", "holy_challenge"):
		return false
	var dmg := float(def["dmg"]) * 0.55
	target.take_damage(dmg, self)
	target.stagger(0.5)
	threat.add(target, 35.0)
	Safe.tel().ev("paladin_challenge", {"hero_id": hero_id, "damage": dmg})
	Safe.gs().el("%s invokes a HOLY CHALLENGE!" % display_name)
	_fx_line((target as Node3D).global_position, Color(1.0, 0.82, 0.35))
	return true

func _try_react_to_sovereign_telegraph() -> void:
	if evade_cd > 0.0 or role == "paladin":
		return
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov == null or not is_instance_valid(sov) or (sov as Sovereign).dead:
		return
	if not sov.has_method("attack_intent_id") or str(sov.attack_intent_id()) != "committed_heavy":
		return
	if not sov.has_method("attack_threatens") or not bool(sov.attack_threatens(global_position)):
		return
	var away := global_position - (sov as Node3D).global_position
	away.y = 0
	if away.length_squared() < 0.01:
		away = Vector3.RIGHT
	away = away.normalized()
	var side := Vector3(-away.z, 0, away.x)
	if get_instance_id() % 2 == 0:
		side = -side
	evade_dir = (away * 0.45 + side).normalized()
	evade_left = 0.28 if role == "rogue" else 0.22
	evade_cd = 2.8 if role == "rogue" else 4.5
	Safe.tel().ev("hero_evade_heavy", {"role": role, "hero_id": hero_id})
	Safe.gs().el("%s reads the heavy swing and slips aside!" % display_name)

# --------------------------------------------------------------- channels ----
func start_work(duration: float, label: String, done: Callable) -> void:
	work_left = duration
	work_total = maxf(0.001, duration)
	work_label = label
	on_work_done = done

func work_progress() -> float:
	if work_total <= 0.0:
		return 0.0
	return clampf(1.0 - work_left / work_total, 0.0, 1.0)

func is_working() -> bool:
	return work_left > 0.0

func tick_work(dt: float) -> void:
	if not is_working():
		return
	work_left -= dt
	if work_left <= 0.0:
		var cb := on_work_done
		work_label = ""
		work_left = 0.0
		work_total = 0.0
		on_work_done = Callable()
		cb.call()

# ---------------------------------------------------------------- helpers ----
func _nearest_enemy(radius: float) -> Node:
	if combat_focus != null and is_instance_valid(combat_focus) 			and not Combat.target_spent(combat_focus):
		var focus_dist := (combat_focus as Node3D).global_position.distance_to(global_position)
		if focus_dist <= radius * 1.35:
			return combat_focus
	var candidates: Array = []
	for n in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if is_instance_valid(n) and n.state != Minion.S.DEAD \
				and (n as Node3D).global_position.distance_to(global_position) <= radius:
			candidates.append(n)
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov != null and is_instance_valid(sov) and not sov.dead \
			and (sov as Node3D).global_position.distance_to(global_position) <= radius * 1.15:
		candidates.append(sov)
	return threat.pick(candidates, global_position)

func _lowest_ally(radius: float) -> Node:
	var best: Node = null
	var frac := 1.0
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if not is_instance_valid(h) or h.down:
			continue
		var f: float = h.hp / h.max_hp
		if f < frac and (h as Node3D).global_position.distance_to(global_position) <= radius:
			frac = f
			best = h
	return best

func _adjacent_brutes() -> int:
	var n := 0
	for m in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if is_instance_valid(m) and m.type_id == "brute" and m.state != Minion.S.DEAD \
				and (m as Node3D).global_position.distance_to(global_position) < 1.45:
			n += 1
	return n

func add_pin_pressure(dt: float) -> void:
	pin_pressure += dt

func set_pinned(v: bool) -> void:
	if pinned == v:
		return
	pinned = v
	if v:
		Safe.gs().el("%s is PINNED by the horde!" % def["label"])
		Safe.tel().ev("pin", {"role": role})
		var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
		if sov != null and is_instance_valid(sov) and sov.has_method("add_dominion"):
			sov.add_dominion(10.0, "brute_pin")

func _steer_toward(goal: Vector3, speed: float, dt: float) -> void:
	var to := goal - global_position
	to.y = 0
	if to.length() < 0.35:
		velocity.x = 0; velocity.z = 0
		return
	var dir := to.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face(dir)

static func _passable(door: Dictionary) -> bool:
	match door["kind"]:
		"sally": return not Safe.gs().domain.sally_sealed
		_: return true

func set_destination(pt: Vector3) -> void:
	move_goal = pt
	path_pts.clear()
	var from_room := RoomGraph.room_of_pos(global_position)
	var to_room := RoomGraph.room_of_pos(pt)
	if from_room != to_room:
		var doors := RoomGraph.path(Safe.gs().graph, from_room, to_room, _passable)
		for d in doors:
			path_pts.append(Defs.door_pos(d))
	path_pts.append(pt)

func nav_target() -> Vector3:
	while path_pts.size() > 1 and global_position.distance_to(path_pts[0]) < 1.3:
		path_pts.pop_front()
	return path_pts[0] if not path_pts.is_empty() else move_goal

func _face(dir: Vector3) -> void:
	if dir.length_squared() > 0.001:
		rotation.y = atan2(-dir.x, -dir.z)

func take_damage(dmg: float, source: Node = null) -> void:
	if down:
		return
	var final_dmg := dmg
	# Paladins carry a few finite Holy Guard charges. Burning them now means
	# they are unavailable deeper in the fortress or after an interception.
	if role == "paladin" and dmg >= 45.0 and resource("holy_guard") > 0:
		if spend_resource("holy_guard", "absorb_heavy_hit"):
			final_dmg *= 0.55
			Safe.gs().el("Paladin's Holy Guard flares! (%d charges left)" % resource("holy_guard"))
	hp -= final_dmg
	if final_dmg >= 20.0 and is_working():
		var interrupted := work_label
		cancel_work()
		Safe.tel().ev("hero_work_interrupted", {"role": role, "hero_id": hero_id,
			"work": interrupted, "damage": final_dmg})
		Safe.gs().el("%s is knocked out of %s!" % [display_name, interrupted.replace("_", " ")])
	if source != null:
		threat.add(source, 7.0 + final_dmg * 0.12)
	if hp <= 0.0:
		down = true
		cancel_work()
		Safe.tel().death(self)
		rotation_degrees = Vector3(-90, rotation_degrees.y, 0)
		position.y = 0.4
		collision_layer = 0
		if carrying_relic:
			drop_relic()
		hero_died.emit(self)
	else:
		staggered = maxf(staggered, final_dmg * 0.008)

func cancel_work() -> void:
	work_left = 0.0
	work_total = 0.0
	work_label = ""
	on_work_done = Callable()

func is_down() -> bool:
	return down

func stagger(t: float) -> void:
	staggered = maxf(staggered, t)

func break_guard(duration: float = 3.5) -> void:
	if down:
		return
	var newly_broken := guard_broken_left <= 0.0
	guard_broken_left = maxf(guard_broken_left, duration)
	if newly_broken:
		Safe.tel().ev("guard_broken", {"role": role, "hero_id": hero_id,
			"duration": duration})
		Safe.gs().el("%s is EXPOSED — Skitterers surge for the opening!" % display_name)
		var main = Safe.main()
		if main != null:
			main.spawn_marker(global_position + Vector3(0, 2.4, 0),
				Vector3(0.3, 3.8, 0.3), Color(1.0, 0.52, 0.08, 0.85), 1.5)

func is_guard_broken() -> bool:
	return guard_broken_left > 0.0

func knockback_from(from: Vector3, force: float) -> void:
	var dir := global_position - from
	dir.y = 0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	global_position += dir * force * 0.14

func escape(_exit_pos: Vector3) -> void:
	escaped.emit(self)
	queue_free.call_deferred()

# ------------------------------------------------------------------ fx -------
func _bolt(target: Node) -> void:
	_fx_line(target.global_position, Color(0.6, 0.4, 1.0))

func _heal_beam(target: Node) -> void:
	_fx_line(target.global_position, Color(0.5, 1.0, 0.6))

func _fx_line(to: Vector3, color: Color) -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var from := global_position + Vector3(0, 1.1, 0)
	var end := to + Vector3(0, 0.8, 0)
	var seg := end - from
	bm.size = Vector3(0.09, 0.09, seg.length())
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mi.material_override = mat
	mi.position = (from + end) / 2.0
	if seg.length() > 0.01:
		mi.look_at_from_position(mi.position, end, Vector3.UP)
	root.add_child(mi)
	var tw := mi.create_tween()
	tw.tween_interval(0.08)
	tw.tween_property(mi, "transparency", 1.0, 0.25)
	tw.tween_callback(mi.queue_free)

func drop_relic() -> void:
	carrying_relic = false
	var relic = Safe.gs().main.fortress.interactables["relic"]
	relic["taken"] = false
	relic["visual"].visible = true
	relic["visual"].global_position = Defs.OBJECTIVE_POS
	Safe.gs().el("The relic drops!")
