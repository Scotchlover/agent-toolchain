# Grunt — village militia. Cheap enemy-of-the-horde actor for played raids:
# seeks the nearest horde body in aggro range, swings a pitchfork, dies.
# Deliberately NOT a Hero: no roles, no party brain, just numbers + nerve.
extends CharacterBody3D
class_name Grunt

var hp := 45.0
var max_hp := 45.0
var dmg := 7.0
var speed := 4.3
var attack_cd := 0.0
var is_captain := false
var archetype := "shield"
var unit_label := "Militia"
var dead := false
var home := Vector3.ZERO     # post to hold when no foe is in sight
var threat := ThreatMemory.new()

const AGGRO := 16.0

func setup(site: Dictionary, p_captain: bool, p_archetype: String = "shield") -> void:
	is_captain = p_captain
	archetype = "captain" if p_captain else p_archetype
	unit_label = str(site["captain_label"] if p_captain else site["defender_label"])
	if p_captain:
		max_hp = site["captain_hp"]
		hp = max_hp
		dmg = site["captain_dmg"]
		speed = site["defender_speed"] + 0.3
	else:
		max_hp = site["defender_hp"]
		dmg = site["defender_dmg"]
		speed = site["defender_speed"]
		match archetype:
			"shield":
				max_hp *= 1.25
				speed *= 0.88
			"spearman":
				dmg *= 1.15
			"archer":
				max_hp *= 0.78
				dmg *= 0.9
				speed *= 0.95
		hp = max_hp

func _ready() -> void:
	add_to_group("militia")
	collision_layer = Combat.MASK_HERO      # horde targeting scans this mask
	collision_mask = Combat.MASK_WORLD | Combat.MASK_MINION | Combat.MASK_SOVEREIGN | Combat.MASK_HERO
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.36
	cap.height = 1.5
	cs.shape = cap
	add_child(cs)
	var mesh := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.34
	m.height = 1.45
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	match archetype:
		"shield": mat.albedo_color = Color(0.45, 0.5, 0.62)
		"spearman": mat.albedo_color = Color(0.56, 0.5, 0.34)
		"archer": mat.albedo_color = Color(0.34, 0.48, 0.31)
		_: mat.albedo_color = Color(0.6, 0.55, 0.4)
	if is_captain:
		mat.albedo_color = Color(0.75, 0.4, 0.2)
		mesh.scale = Vector3(1.25, 1.15, 1.25)
	mesh.material_override = mat
	mesh.position.y = 0.75
	add_child(mesh)
	var label := Label3D.new()
	label.text = unit_label if is_captain else "%s %s" % [unit_label, archetype.capitalize()]
	label.font_size = 34
	label.pixel_size = 0.005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 2.0
	add_child(label)
	match archetype:
		"shield":
			_add_prop(Vector3(0.12, 0.9, 0.72), Vector3(0.48, 0.9, 0.0), Color(0.3, 0.36, 0.48))
		"spearman":
			_add_prop(Vector3(0.09, 2.7, 0.09), Vector3(0.48, 1.3, -0.1), Color(0.42, 0.34, 0.2))
		"archer":
			_add_prop(Vector3(0.08, 1.4, 0.42), Vector3(0.5, 1.0, 0.05), Color(0.3, 0.42, 0.25))

func _add_prop(size: Vector3, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = color
	mi.material_override = mat
	mi.position = pos
	add_child(mi)

func _physics_process(dt: float) -> void:
	if dead:
		return
	if global_position.y < -15.0:
		take_damage(99999.0)   # fell off the world
		return
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	threat.tick(dt, sov if (sov != null and is_instance_valid(sov)
		and (sov as Node3D).global_position.distance_to(global_position) < 6.0) else null)
	attack_cd = maxf(0.0, attack_cd - dt)
	var target := _nearest_foe(AGGRO)
	if target == null:
		# Return to post so scattered defenders come back into the fight.
		var back := home - global_position
		back.y = 0
		if back.length() > 1.5:
			var dir := back.normalized()
			velocity.x = dir.x * speed * 0.6
			velocity.z = dir.z * speed * 0.6
			_face(dir)
		else:
			velocity.x = 0
			velocity.z = 0
		move_and_slide()
		return
	var to: Vector3 = (target as Node3D).global_position - global_position
	to.y = 0
	var dist := to.length()
	if archetype == "archer" and dist < 4.2:
		var away := -to.normalized()
		velocity.x = away.x * speed
		velocity.z = away.z * speed
		_face(-away)
	elif dist > def_range():
		var dir := to.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_face(dir)
	else:
		velocity.x = 0
		velocity.z = 0
		_face(to.normalized())
		if attack_cd <= 0.0:
			attack_cd = 1.0 if (not is_captain and _captain_nearby()) else 1.25
			var strike := dmg
			if archetype == "spearman" and target is Minion and target.type_id == "brute":
				strike *= 1.45
			target.take_damage(strike, self)
			Safe.tel().hit(target, strike, self)
			if archetype == "archer" and Safe.main() != null:
				Safe.main().spawn_impact((target as Node3D).global_position, Color(0.75, 0.85, 0.45))
	_separate_militia()
	if not is_on_floor():
		velocity.y -= 22.0 * dt
	else:
		velocity.y = -1.0
	move_and_slide()

func def_range() -> float:
	match archetype:
		"archer": return 8.5
		"spearman": return 2.45
		_: return 1.7

func _captain_nearby() -> bool:
	for other in get_tree().get_nodes_in_group("militia"):
		if other == self or not is_instance_valid(other) or other.dead:
			continue
		if other.is_captain and (other as Node3D).global_position.distance_to(global_position) < 8.5:
			return true
	return false

func _nearest_foe(radius: float) -> Node:
	var candidates: Array = []
	for n in get_tree().get_nodes_in_group(Combat.GROUP_MINIONS):
		if is_instance_valid(n) and n.state != Minion.S.DEAD \
				and (n as Node3D).global_position.distance_to(global_position) < radius:
			candidates.append(n)
	var sov := get_tree().get_first_node_in_group(Combat.GROUP_SOVEREIGN)
	if sov != null and is_instance_valid(sov) and not sov.dead \
			and (sov as Node3D).global_position.distance_to(global_position) < radius * 1.4:
		candidates.append(sov)
	return threat.pick(candidates, global_position)

func _separate_militia() -> void:
	var push := Vector3.ZERO
	for other in get_tree().get_nodes_in_group("militia"):
		if other == self or not is_instance_valid(other):
			continue
		var to: Vector3 = global_position - (other as Node3D).global_position
		to.y = 0
		var d := to.length()
		if d < 1.0 and d > 0.01:
			push += to / d * (1.0 - d)
	velocity += push * 5.0

func _face(dir: Vector3) -> void:
	if dir.length_squared() > 0.001:
		rotation.y = atan2(-dir.x, -dir.z)

func take_damage(dmg_amount: float, source: Node = null) -> void:
	if dead:
		return
	if archetype == "shield":
		dmg_amount *= 0.78
	hp -= dmg_amount
	if source != null:
		threat.add(source, 8.0 + dmg_amount * 0.15)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(1.15, 1.1, 1.15), 0.05)
	tw.tween_property(self, "scale", Vector3.ONE, 0.12)
	if hp <= 0.0:
		dead = true
		Safe.tel().death(self)
		collision_layer = 0
		remove_from_group("militia")   # victory checks count the living only
		rotation_degrees = Vector3(90, randf_range(0, 360), 0)
		position.y = 0.35
		if is_captain:
			Safe.gs().el("%s FALLS! The defenders waver!" % unit_label)
		else:
			Safe.gs().el("A %s %s drops." % [unit_label.to_lower(), archetype])
		get_tree().create_timer(5.0).timeout.connect(func():
			if is_instance_valid(self):
				queue_free()
		)

func stagger(_t: float) -> void:
	pass   # pitchfork line does not stagger, but must exist for callers

func knockback_from(from: Vector3, force: float) -> void:
	var dir := global_position - from
	dir.y = 0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	global_position += dir * force * 0.14

func alive_count() -> bool:
	return not dead and is_instance_valid(self)
