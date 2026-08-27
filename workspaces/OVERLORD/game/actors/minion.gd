# MinionAgent — cheap physical horde body. Local states only; brains live in
# CohortController. v0.3 gives cohorts distinct combat roles and Dominion buffs.
extends CharacterBody3D
class_name Minion

enum S { FOLLOW, ENGAGE, INTERACT, STUNNED, DEAD }

var type_id := "brute"
var def: Dictionary
var cohort_id := ""
var cohort_slot := 0
var phase := 0.0

var hp := 60.0
var max_hp := 60.0
var state: int = S.FOLLOW
var slot_pos := Vector3.ZERO
var combat_target: Node = null
var interact_task: Dictionary = {}
var stun_left := 0.0
var attack_cd := 0.0
var corpse_timer := 0.0
var is_lieutenant := false
var empower_left := 0.0

const AGGRO_RADIUS := 3.6
const DISENGAGE_RADIUS := 7.0
const SEPARATION_R := 0.95
const SOVEREIGN_CLEARANCE_BRUTE := 1.7
const SOVEREIGN_CLEARANCE_SKITTERER := 2.15
const SOVEREIGN_CLEARANCE_OTHER := 1.9
const EMPOWER_DMG := 1.35
const EMPOWER_SPEED := 1.18

func setup(p_type: String, p_cohort: String, p_index: int) -> void:
	type_id = p_type
	def = Defs.MINION_TYPES[p_type].duplicate()
	cohort_id = p_cohort
	cohort_slot = p_index
	max_hp = def["hp"]
	hp = max_hp
	phase = float(p_index) * 1.7 + p_cohort.hash() % 10

func promote_lieutenant(lt: Dictionary) -> void:
	is_lieutenant = true
	max_hp *= float(lt.get("hp_mult", 2.0))
	hp = max_hp
	def["dmg"] = float(def["dmg"]) * float(lt.get("dmg_mult", 1.5))
	set_meta("lt_name", str(lt.get("name", "Lieutenant")))
	if is_inside_tree():
		_apply_lieutenant_look()

func _apply_lieutenant_look() -> void:
	scale = Vector3.ONE * float(get_meta("lt_scale", 1.35))
	for c in get_children():
		if c is Label3D:
			c.text = str(get_meta("lt_name"))
			return
	var label := Label3D.new()
	label.text = str(get_meta("lt_name"))
	label.font_size = 42
	label.pixel_size = 0.005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1.0, 0.6, 0.2)
	label.position.y = 1.9
	add_child(label)

func _ready() -> void:
	add_to_group(Combat.GROUP_MINIONS)
	collision_layer = Combat.MASK_MINION
	collision_mask = Combat.MASK_WORLD | Combat.MASK_HERO | Combat.MASK_MINION | Combat.MASK_SOVEREIGN
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.1
	cs.shape = cap
	add_child(cs)
	var mesh := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.32
	m.height = 1.05
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = def.get("color", Color.RED)
	mesh.material_override = mat
	mesh.position.y = 0.55
	add_child(mesh)
	var eye := MeshInstance3D.new()
	var em := SphereMesh.new()
	em.radius = 0.09
	em.height = 0.18
	eye.mesh = em
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(1.0, 0.75, 0.1)
	emat.emission_enabled = true
	emat.emission = Color(1.0, 0.6, 0.05)
	eye.material_override = emat
	eye.position.y = 0.95
	add_child(eye)
	mesh.scale = Vector3(1.25, 1.15, 1.25) if type_id == "brute" else Vector3(0.9, 0.85, 0.9)

func _physics_process(dt: float) -> void:
	if state == S.DEAD:
		corpse_timer -= dt
		if corpse_timer <= 0.0:
			queue_free()
		return
	if global_position.y < -15.0:
		take_damage(99999.0)
		return
	empower_left = maxf(0.0, empower_left - dt)
	attack_cd = maxf(0.0, attack_cd - dt)
	if stun_left > 0.0:
		stun_left -= dt
		state = S.STUNNED
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	if state == S.STUNNED:
		if not interact_task.is_empty():
			state = S.INTERACT
		elif combat_target != null and not Combat.target_spent(combat_target):
			state = S.ENGAGE
		else:
			state = S.FOLLOW

	match state:
		S.ENGAGE:
			_do_engage(dt)
		S.INTERACT:
			_do_interact(dt)
		_:
			_do_travel(dt)

	_separate()
	if not is_on_floor():
		velocity.y -= 22.0 * dt
	else:
		velocity.y = -1.0
	move_and_slide()

func _effective_speed() -> float:
	return float(def["speed"]) * (EMPOWER_SPEED if empower_left > 0.0 else 1.0)

func _effective_damage() -> float:
	return float(def["dmg"]) * (EMPOWER_DMG if empower_left > 0.0 else 1.0)

# ------------------------------------------------------------- movement ------
func _do_travel(dt: float) -> void:
	var eff := RoomGraph.next_waypoint(Safe.gs().graph, global_position, slot_pos)
	var to_slot := eff - global_position
	to_slot.y = 0
	var d := to_slot.length()
	var speed := _effective_speed()
	var idle_wander := Vector3(sin(Time.get_ticks_msec() / 900.0 + phase), 0, cos(Time.get_ticks_msec() / 1100.0 + phase)) * 0.35
	if d > 12.0:
		speed *= 1.45
	elif d < 0.9 and eff == slot_pos:
		velocity.x = idle_wander.x * 0.3
		velocity.z = idle_wander.z * 0.3
		_face_toward(slot_pos, dt)
		return
	var dir := to_slot.normalized()
	velocity.x = dir.x * speed + idle_wander.x
	velocity.z = dir.z * speed + idle_wander.z
	_face_toward(dir, dt)

func _do_engage(dt: float) -> void:
	if Combat.target_spent(combat_target):
		combat_target = null
		state = S.FOLLOW
		return
	var target_body := combat_target as Node3D
	var to: Vector3 = target_body.global_position - global_position
	to.y = 0
	var dist := to.length()
	if dist > float(def["range"]) + 0.55:
		var eff := RoomGraph.next_waypoint(Safe.gs().graph, global_position, target_body.global_position)
		var chase: Vector3 = eff - global_position
		chase.y = 0
		var dir := to.normalized() if chase.length() < 0.05 else chase.normalized()
		var speed := _effective_speed() * 1.15
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_face_toward(dir, dt)
	else:
		velocity.x = 0
		velocity.z = 0
		_face_toward(to.normalized(), dt)
		if attack_cd <= 0.0:
			var dealt := _effective_damage()
			var exploit_opening := false
			if type_id == "skitterer" and combat_target is Hero:
				var exposed := combat_target as Hero
				if exposed.is_guard_broken():
					exploit_opening = true
					dealt *= opening_damage_multiplier(type_id, true)
			attack_cd = 0.78 if exploit_opening else 1.1
			combat_target.take_damage(dealt, self)
			Safe.tel().hit(combat_target, dealt, self)
			# Skitterers are disruption specialists: they punish back-line
			# casting/channeling and exploit openings made by the Sovereign.
			if type_id == "skitterer" and combat_target is Hero:
				var hero := combat_target as Hero
				if exploit_opening:
					Safe.tel().ev("skitterer_exploit_guard_break", {
						"role": hero.role, "hero_id": hero.hero_id, "damage": dealt})
				if hero.role in ["wizard", "cleric"]:
					hero.stagger(0.20)
					if hero.is_working():
						hero.cancel_work()
					Safe.tel().ev("skitterer_interrupt", {"role": hero.role})
	if type_id == "brute" and dist < 1.35 and combat_target.has_method("add_pin_pressure"):
		combat_target.add_pin_pressure(dt)

func _do_interact(dt: float) -> void:
	if interact_task.is_empty():
		state = S.FOLLOW
		return
	var goal: Vector3 = interact_task["slot_pos"]
	var to := goal - global_position
	to.y = 0
	if to.length() > 0.7:
		var dir := to.normalized()
		var speed := _effective_speed()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_face_toward(dir, dt)
	else:
		velocity.x = 0
		velocity.z = 0
		interact_task["in_place"] = true

func _face_toward(dir: Vector3, dt: float) -> void:
	if dir.length_squared() < 0.001:
		return
	var yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, yaw, clampf(10.0 * dt, 0, 1))

func _separate() -> void:
	var push := Vector3.ZERO
	for other in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if other == self or not is_instance_valid(other):
			continue
		var other_body := other as Node3D
		var to: Vector3 = global_position - other_body.global_position
		to.y = 0
		var d := to.length()
		if d < SEPARATION_R and d > 0.01:
			push += to / d * (SEPARATION_R - d)

	# The Sovereign owns the center of the fight. This is intentionally a soft
	# force: minions can still reach a target beside him, but do not live under
	# his feet and obscure traversal/attacks.
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov != null and is_instance_valid(sov) and not (sov as Sovereign).dead 			and state != S.INTERACT:
		push += sovereign_clearance_force(global_position,
			(sov as Node3D).global_position, type_id)
	velocity += push * 6.0

static func sovereign_clearance_force(minion_pos: Vector3, sovereign_pos: Vector3,
		p_type: String) -> Vector3:
	var clearance := SOVEREIGN_CLEARANCE_OTHER
	if p_type == "brute":
		clearance = SOVEREIGN_CLEARANCE_BRUTE
	elif p_type == "skitterer":
		clearance = SOVEREIGN_CLEARANCE_SKITTERER
	var away := minion_pos - sovereign_pos
	away.y = 0
	var d := away.length()
	if d >= clearance or d <= 0.01:
		return Vector3.ZERO if d >= clearance else Vector3.RIGHT * clearance
	return away.normalized() * (clearance - d) * 0.65

# --------------------------------------------------------------- commands ----
func assign_slot(pos: Vector3) -> void:
	slot_pos = pos

func order_engage(target: Node) -> void:
	combat_target = target
	state = S.ENGAGE

func order_interact(task: Dictionary) -> void:
	interact_task = task
	state = S.INTERACT

func release_to_travel() -> void:
	interact_task = {}
	combat_target = null
	state = S.FOLLOW

func empower(duration: float) -> void:
	empower_left = maxf(empower_left, duration)

static func local_target_score(p_type: String, hero_role: String,
		guard_broken: bool, distance: float) -> float:
	var score := 10.0 - distance
	if p_type == "skitterer":
		if hero_role in ["wizard", "cleric"]:
			score += 8.0
		if guard_broken:
			score += 10.0
	elif p_type == "brute" and hero_role == "paladin":
		score += 3.0
	return score

static func opening_damage_multiplier(p_type: String, guard_broken: bool) -> float:
	return 1.45 if p_type == "skitterer" and guard_broken else 1.0

func find_local_enemy(space_state: PhysicsDirectSpaceState3D) -> Node:
	var hits := Combat.actors_in_radius(space_state, global_position + Vector3(0, 0.6, 0), AGGRO_RADIUS, Combat.MASK_HERO)
	var best: Node = null
	var best_score := -INF
	for candidate in hits:
		if Combat.target_spent(candidate) or not (candidate is Node3D):
			continue
		var actor := candidate as Node3D
		var d: float = actor.global_position.distance_to(global_position)
		var score := 10.0 - d
		if candidate is Hero:
			var hero := candidate as Hero
			score = local_target_score(type_id, hero.role, hero.is_guard_broken(), d)
		elif candidate is Grunt:
			var grunt := candidate as Grunt
			score = grunt_target_score(type_id, grunt.archetype, grunt.is_captain, d)
		else:
			continue
		if score > best_score:
			best_score = score
			best = candidate
	return best

static func grunt_target_score(p_type: String, archetype: String,
		is_captain: bool, distance: float) -> float:
	var score := 10.0 - distance
	if is_captain:
		score += 4.0
	if p_type == "skitterer" and archetype == "archer":
		score += 2.0
	elif p_type == "brute" and archetype == "shield":
		score += 2.0
	return score

# ---------------------------------------------------------------- damage -----
func take_damage(dmg: float, source: Node = null) -> void:
	hp -= dmg
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(1.25, 1.15, 1.25), 0.05)
	tw.tween_property(self, "scale", Vector3.ONE, 0.12)
	if hp <= 0.0:
		state = S.DEAD
		Safe.tel().death(self)
		corpse_timer = 4.0
		collision_layer = 0
		collision_mask = Combat.MASK_WORLD
		rotation_degrees = Vector3(90, randf_range(0, 360), 0)
		position.y = 0.35

func stagger(t: float) -> void:
	stun_left = maxf(stun_left, t)

func knockback_from(from: Vector3, force: float) -> void:
	var dir := global_position - from
	dir.y = 0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	global_position += dir * force * 0.18
