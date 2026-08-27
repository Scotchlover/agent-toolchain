# PerimeterBuilder — one compact authored interception strip between the strategic
# map and fortress. Not an open world: a readable road/choke where an incoming
# expedition can be physically weakened before it reaches the gates.
extends Node3D
class_name PerimeterBuilder

const ORIGIN := Vector3(1200, 0, 0)
var sovereign_spawn := ORIGIN + Vector3(0, 0.6, -12)
var horde_spawn := ORIGIN + Vector3(0, 0.6, -8)
var expedition_spawn := ORIGIN + Vector3(0, 0.6, 18)
var breakthrough_pos := ORIGIN + Vector3(0, 0.6, -20)

func build() -> void:
	var ground := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(34, 0.5, 52)
	ground.mesh = gm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.13, 0.10)
	mat.roughness = 1.0
	ground.material_override = mat
	ground.position = ORIGIN + Vector3(0, -0.25, 0)
	add_child(ground)
	var body := StaticBody3D.new()
	body.collision_layer = Combat.MASK_WORLD
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = gm.size
	cs.shape = sh
	body.add_child(cs)
	ground.add_child(body)

	# A broken road and two rock shoulders create a readable but broad choke.
	for x in [-10.0, 10.0]:
		for z in [-8.0, 4.0, 15.0]:
			_make_rock(ORIGIN + Vector3(x + randf_range(-1.5, 1.5), 1.1, z), Vector3(3.8, 2.2, 4.5))
	_make_beacon(expedition_spawn + Vector3(0, 0, 2), Color(0.95, 0.82, 0.42))
	_make_beacon(breakthrough_pos, Color(0.55, 0.12, 0.65))

func _make_rock(pos: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.22, 0.21, 0.18)
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	var body := StaticBody3D.new(); body.collision_layer = Combat.MASK_WORLD
	var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = size
	cs.shape = sh; body.add_child(cs); mi.add_child(body)

func _make_beacon(pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new(); cm.top_radius = 0.12; cm.bottom_radius = 0.35; cm.height = 3.5
	mi.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color; mat.emission_enabled = true; mat.emission = color; mat.emission_energy_multiplier = 1.7
	mi.material_override = mat
	mi.position = pos + Vector3(0, 1.75, 0)
	add_child(mi)
