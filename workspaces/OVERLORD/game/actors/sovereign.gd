# The Dark Sovereign — heavy third-person warrior-king.
# v0.3 combat grammar: committed attacks, active brace, Dominion and horde synergy.
extends CharacterBody3D
class_name Sovereign

signal died
signal hp_changed(hp: float, max_hp: float)
signal hit_landed(victim_count: int)
signal dominion_changed(value: float, max_value: float)

var max_hp := 300.0
var hp := 300.0
var walk_speed := 4.4
var march_speed := 6.2

var attack_cd := 0.0
var ability_cd := 0.0
const ABILITY_CD_TIME := 7.0

var poise := 100.0
const POISE_MAX := 100.0
var staggered := 0.0
var hit_slow := 0.0
var dead := false

# Dominion is earned by coordinated pressure and spent on command authority.
var dominion := 25.0
const DOMINION_MAX := 100.0
const DREAD_COMMAND_COST := 35.0

var facing := Vector3(0, 0, -1)
var _windup_left := 0.0
var _recover_left := 0.0
var _pending_attack: Dictionary = {}
var _brace_left := 0.0
var _brace_cd := 0.0

var cam_rig: Node3D

const STANDARD_ATTACK := {
	"id": "sweep", "windup": 0.38, "recover": 0.52,
	"dmg": 52.0, "arc": 145.0, "range": 3.15, "knockback": 6.5,
	"stagger": 0.15, "lunge": 0.28, "dominion": 3.0,
}
const HEAVY_ATTACK := {
	"id": "committed_heavy", "windup": 0.76, "recover": 0.86,
	"dmg": 92.0, "arc": 82.0, "range": 3.55, "knockback": 10.5,
	"stagger": 1.05, "lunge": 0.48, "dominion": 7.0,
}

const BODY_RADIUS := 0.52
const BODY_HEIGHT := 2.35
const DOOR_ASSIST_RANGE := 3.4
const DOOR_ASSIST_MIN_ALIGN := 0.42
var door_assist_active := false

func _init() -> void:
	collision_layer = Combat.MASK_SOVEREIGN
	collision_mask = Combat.MASK_WORLD | Combat.MASK_HERO

func _ready() -> void:
	add_to_group(Combat.GROUP_SOVEREIGN)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_RADIUS
	cap.height = BODY_HEIGHT
	cs.shape = cap
	add_child(cs)
	var mesh := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.62
	m.height = 2.3
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.09, 0.12)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.05, 0.1)
	mat.emission_energy_multiplier = 0.35
	mesh.material_override = mat
	mesh.position.y = 1.15
	add_child(mesh)
	var crown := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.42
	cm.height = 0.5
	crown.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.5, 0.42, 0.18)
	cmat.metallic = 0.8
	crown.material_override = cmat
	crown.position.y = 2.45
	add_child(crown)
	blade = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.14, 2.0, 0.34)
	blade.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.55, 0.58, 0.62)
	bmat.metallic = 0.9
	bmat.emission_enabled = true
	bmat.emission = Color(0.12, 0.03, 0.02)
	bmat.emission_energy_multiplier = 0.25
	blade.material_override = bmat
	blade.position = Vector3(0.85, 1.2, -0.2)
	add_child(blade)
	dominion_changed.emit(dominion, DOMINION_MAX)

var blade: MeshInstance3D

func _physics_process(dt: float) -> void:
	if dead:
		return
	attack_cd = maxf(0.0, attack_cd - dt)
	ability_cd = maxf(0.0, ability_cd - dt)
	_brace_cd = maxf(0.0, _brace_cd - dt)
	_brace_left = maxf(0.0, _brace_left - dt)
	staggered = maxf(0.0, staggered - dt)
	hit_slow = maxf(0.0, hit_slow - dt)
	poise = minf(POISE_MAX, poise + 22.0 * dt)

	var map_open: bool = Safe.gs().main != null and Safe.gs().main.world_map.open
	if not map_open and Input.is_action_just_pressed("attack"):
		try_attack()
	if not map_open and Input.is_action_just_pressed("heavy_attack"):
		try_heavy_attack()
	if not map_open and Input.is_action_just_pressed("brace"):
		try_brace()
	if not map_open and Input.is_action_just_pressed("dominion_command"):
		try_dread_command()
	if not map_open and Input.is_action_just_pressed("ability"):
		try_ability()

	var move := Vector3.ZERO
	door_assist_active = false
	if _windup_left > 0.0 or _recover_left > 0.0 or staggered > 0.0 or _brace_left > 0.0:
		move = Vector3.ZERO
	elif map_open:
		move = Vector3.ZERO
	else:
		var input_vec := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
		var cam_fwd: Vector3 = cam_rig.flat_forward() if cam_rig != null and cam_rig.has_method("flat_forward") else Vector3(0, 0, -1)
		var cam_right: Vector3 = cam_rig.flat_right() if cam_rig != null and cam_rig.has_method("flat_right") else Vector3.RIGHT
		move = camera_relative_move(input_vec, cam_fwd, cam_right)
		var sprinting := Input.is_action_pressed("sprint")
		var speed := march_speed if sprinting else walk_speed
		if hit_slow > 0.0:
			speed *= 0.35
		if move.length() > 1.0:
			move = move.normalized()
		move *= speed
		move = _doorway_assisted(move)
		if move.length() > 0.1:
			facing = Vector3(move.x, 0, move.z).normalized()

	var turn_rate := 10.0 if _recover_left <= 0.0 else 4.0
	var flat_facing := Vector3(facing.x, 0, facing.z)
	if flat_facing.length() > 0.01:
		var target_yaw := atan2(-flat_facing.x, -flat_facing.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_rate * dt, 0.0, 1.0))

	velocity.x = move.x
	velocity.z = move.z
	if not is_on_floor():
		velocity.y -= 22.0 * dt
	else:
		velocity.y = -1.0
	move_and_slide()

	if _brace_left > 0.0:
		blade.rotation.x = lerpf(blade.rotation.x, -0.75, 15.0 * dt)
	elif _windup_left > 0.0:
		_windup_left -= dt
		var heavy := str(_pending_attack.get("id", "")) == "committed_heavy"
		blade.rotation.x = lerpf(blade.rotation.x, -2.65 if heavy else -2.2, (8.0 if heavy else 12.0) * dt)
		if _windup_left <= 0.0 and not _pending_attack.is_empty():
			_resolve_pending_attack()
	elif _recover_left > 0.0:
		_recover_left -= dt
		blade.rotation.x = lerpf(blade.rotation.x, 1.05, 8.0 * dt)
	else:
		blade.rotation.x = lerpf(blade.rotation.x, 0.0, 6.0 * dt)
	_update_blade_telegraph()

func _update_blade_telegraph() -> void:
	var mat := blade.material_override as StandardMaterial3D
	if mat == null:
		return
	if _brace_left > 0.0:
		mat.emission = Color(0.18, 0.38, 0.9)
		mat.emission_energy_multiplier = 1.15
	elif _windup_left > 0.0 and str(_pending_attack.get("id", "")) == "committed_heavy":
		mat.emission = Color(1.0, 0.16, 0.035)
		mat.emission_energy_multiplier = 2.35
	elif _windup_left > 0.0:
		mat.emission = Color(0.9, 0.42, 0.08)
		mat.emission_energy_multiplier = 0.85
	else:
		mat.emission = Color(0.12, 0.03, 0.02)
		mat.emission_energy_multiplier = 0.25

static func camera_relative_move(input_vec: Vector2, cam_fwd: Vector3, cam_right: Vector3) -> Vector3:
	var fwd := Vector3(cam_fwd.x, 0, cam_fwd.z)
	var right := Vector3(cam_right.x, 0, cam_right.z)
	fwd = fwd.normalized() if fwd.length_squared() >= 0.0001 else Vector3(0, 0, -1)
	right = right.normalized() if right.length_squared() >= 0.0001 else fwd.cross(Vector3.UP).normalized()
	return right * input_vec.x + fwd * input_vec.y

func _doorway_assisted(move: Vector3) -> Vector3:
	if move.length_squared() < 0.01:
		return move
	var nearest: Dictionary = {}
	var best := DOOR_ASSIST_RANGE
	for door in Defs.DOORS:
		var p := Defs.door_pos(door)
		var d := Vector2(global_position.x - p.x, global_position.z - p.z).length()
		if d < best:
			best = d
			nearest = door
	if nearest.is_empty():
		return move
	var assisted := doorway_funnel_velocity(move, global_position, Defs.door_pos(nearest), _door_axis(nearest))
	door_assist_active = assisted.distance_to(move) > 0.01
	return assisted

static func _door_axis(door: Dictionary) -> Vector3:
	var a := str(door["a"])
	var b := str(door["b"])
	var p := Defs.door_pos(door)
	var axis := Vector3.ZERO
	if a != "__outside__" and b != "__outside__":
		axis = Defs.room_center(b) - Defs.room_center(a)
	elif b != "__outside__":
		axis = Defs.room_center(b) - p
	elif a != "__outside__":
		axis = p - Defs.room_center(a)
	axis.y = 0
	return axis.normalized() if axis.length_squared() > 0.0001 else Vector3(0, 0, -1)

static func doorway_funnel_velocity(move: Vector3, actor_pos: Vector3, door_pos: Vector3, axis: Vector3) -> Vector3:
	var speed := move.length()
	if speed < 0.01:
		return move
	var flat_axis := Vector3(axis.x, 0, axis.z)
	if flat_axis.length_squared() < 0.0001:
		return move
	flat_axis = flat_axis.normalized()
	var along := move.dot(flat_axis)
	if absf(along) / speed < DOOR_ASSIST_MIN_ALIGN:
		return move
	var offset := actor_pos - door_pos
	offset.y = 0
	var lateral := offset - flat_axis * offset.dot(flat_axis)
	var lateral_len := lateral.length()
	if lateral_len < 0.12:
		return move
	var lateral_move := move - flat_axis * along
	var correction_mag := minf(speed * 0.48, lateral_len * 2.8)
	var desired_lateral := -lateral.normalized() * correction_mag
	var blend := clampf((lateral_len - 0.12) / 1.15, 0.0, 0.78)
	var out := flat_axis * along + lateral_move.lerp(desired_lateral, blend)
	return out.normalized() * speed if out.length_squared() > 0.0001 else move

# --------------------------------------------------------------- combat ------
func try_attack() -> void:
	_start_attack(STANDARD_ATTACK)

func try_heavy_attack() -> void:
	_start_attack(HEAVY_ATTACK)

func _start_attack(spec: Dictionary) -> void:
	if attack_cd > 0.0 or _windup_left > 0.0 or _recover_left > 0.0 or staggered > 0.0 or _brace_left > 0.0:
		return
	_pending_attack = spec.duplicate()
	_windup_left = float(spec["windup"])
	_recover_left = float(spec["recover"])
	attack_cd = _windup_left + _recover_left + 0.08
	Safe.tel().ev("attack_used", {"id": spec["id"]})
	var m = Safe.main()
	if m != null:
		m.play_sfx("swing", 50)

func _resolve_pending_attack() -> void:
	var spec := _pending_attack.duplicate()
	_pending_attack = {}
	var space := get_world_3d().direct_space_state
	var hits := Combat.actors_in_arc(space, global_position + Vector3(0, 1, 0), facing,
		float(spec["range"]), float(spec["arc"]), Combat.MASK_HERO)
	var victims := 0
	for h in hits:
		if Combat.target_spent(h):
			continue
		var pinned_bonus: bool = bool("pinned" in h and h.pinned)
		var dmg := float(spec["dmg"]) * (1.45 if pinned_bonus else 1.0)
		h.take_damage(dmg, self)
		Safe.tel().hit(h, dmg, self)
		if str(spec["id"]) == "committed_heavy" and not Combat.target_spent(h) 				and h.has_method("break_guard"):
			h.break_guard(3.5)
		if h.has_method("stagger"):
			h.stagger(float(spec["stagger"]) + (0.35 if pinned_bonus else 0.0))
		if h.has_method("knockback_from"):
			h.knockback_from(global_position, float(spec["knockback"]))
		add_dominion(float(spec["dominion"]) + (5.0 if pinned_bonus else 0.0), "attack_hit")
		var m = Safe.main()
		if m != null:
			m.spawn_impact((h as Node3D).global_position, Color(1.0, 0.55, 0.22) if spec["id"] == "committed_heavy" else Color(1.0, 0.45, 0.25))
		victims += 1
	if victims > 0:
		poise = minf(POISE_MAX, poise + 12.0 + victims * 3.0)
		hit_landed.emit(victims)
		Safe.tel().ev("attack_hit", {"id": spec["id"], "victims": victims})
	else:
		Safe.tel().ev("attack_whiff", {"id": spec["id"]})
	global_position += facing * float(spec["lunge"])

func do_arc_damage() -> void:
	if _pending_attack.is_empty():
		_pending_attack = STANDARD_ATTACK.duplicate()
	_resolve_pending_attack()

# Fair enemy reactions need to read the same telegraph the player sees.
# This exposes intent, not future hit results.
func attack_intent_id() -> String:
	if _windup_left <= 0.0 or _pending_attack.is_empty():
		return ""
	return str(_pending_attack.get("id", ""))

func is_winding_attack() -> bool:
	return _windup_left > 0.0 and not _pending_attack.is_empty()

func attack_threatens(point: Vector3) -> bool:
	if not is_winding_attack():
		return false
	return attack_spec_threatens(global_position, facing, _pending_attack, point)

static func attack_spec_threatens(origin: Vector3, facing_dir: Vector3,
		spec: Dictionary, point: Vector3) -> bool:
	var to := point - origin
	to.y = 0.0
	var dist := to.length()
	if dist > float(spec.get("range", 0.0)) + 0.55 or dist < 0.01:
		return false
	var flat_facing := Vector3(facing_dir.x, 0, facing_dir.z).normalized()
	if flat_facing.length_squared() < 0.01:
		return false
	var ang := absf(flat_facing.angle_to(to.normalized()))
	return ang <= deg_to_rad(float(spec.get("arc", 90.0)) * 0.5 + 7.0)

func try_brace() -> void:
	if _brace_cd > 0.0 or staggered > 0.0 or _windup_left > 0.0 or _recover_left > 0.0:
		return
	_brace_left = 0.58
	_brace_cd = 1.45
	Safe.tel().ev("brace_started", {})
	var m = Safe.main()
	if m != null:
		m.play_sfx("hold", 80)

func is_bracing() -> bool:
	return _brace_left > 0.0

func try_dread_command() -> void:
	if not spend_dominion(DREAD_COMMAND_COST, "dread_command"):
		Safe.gs().el("Dominion is too weak for a Dread Command.")
		return
	var m = Safe.main()
	if m != null and m.horde != null:
		m.horde.empower(6.0)
		m.cam_rig.shake = maxf(m.cam_rig.shake, 0.35)
		m.play_sfx("dread", 0)
	Safe.gs().el("DREAD COMMAND — the horde surges with your will.")

func try_ability() -> void:
	if ability_cd > 0.0 or staggered > 0.0 or _brace_left > 0.0:
		return
	ability_cd = ABILITY_CD_TIME
	var m = Safe.main()
	if m != null:
		m.play_sfx("dread", 0)
		m.cam_rig.shake = maxf(m.cam_rig.shake, 0.65)
	DreadWave.burst(get_tree(), global_position, 7.0, 25.0, self)

func add_dominion(amount: float, reason: String) -> void:
	if amount <= 0.0:
		return
	var before := dominion
	dominion = minf(DOMINION_MAX, dominion + amount)
	var gained := dominion - before
	if gained > 0.0:
		Safe.tel().ev("dominion_gain", {"amount": gained, "reason": reason, "after": dominion})
		dominion_changed.emit(dominion, DOMINION_MAX)

func spend_dominion(amount: float, reason: String) -> bool:
	if dominion + 0.001 < amount:
		return false
	dominion -= amount
	Safe.tel().ev("dominion_spend", {"amount": amount, "reason": reason, "after": dominion})
	dominion_changed.emit(dominion, DOMINION_MAX)
	return true

# ---------------------------------------------------------------- damage -----
func take_damage(dmg: float, source: Node = null) -> void:
	if dead:
		return
	var final_dmg := dmg
	if is_bracing():
		final_dmg *= 0.35
		poise = minf(POISE_MAX, poise + 8.0)
		add_dominion(8.0, "brace")
		Safe.tel().ev("block_success", {"raw": dmg, "taken": final_dmg})
		var m = Safe.main()
		if m != null:
			m.spawn_impact(global_position + Vector3(0, 1.2, 0), Color(0.65, 0.75, 1.0))
			m.cam_rig.shake = maxf(m.cam_rig.shake, 0.25)
	hp -= final_dmg
	hp_changed.emit(hp, max_hp)
	poise -= final_dmg * (0.35 if is_bracing() else 0.9)
	if final_dmg >= 20.0:
		hit_slow = 0.26
	if poise <= 0.0:
		staggered = 0.85
		poise = POISE_MAX * 0.5
	if hp <= 0.0:
		die()

func die() -> void:
	dead = true
	Safe.tel().death(self)
	died.emit()
	visible = false
	set_physics_process(false)

func revive(at: Vector3) -> void:
	dead = false
	hp = max_hp
	dominion = maxf(0.0, dominion * 0.35)
	global_position = at
	visible = true
	set_physics_process(true)
	hp_changed.emit(hp, max_hp)
	dominion_changed.emit(dominion, DOMINION_MAX)

func knockback_from(_from: Vector3, _force: float) -> void:
	pass

func stagger(t: float) -> void:
	if is_bracing():
		return
	staggered = maxf(staggered, t * 0.5)
