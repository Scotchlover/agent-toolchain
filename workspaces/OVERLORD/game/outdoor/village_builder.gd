# VillageBuilder — authored greybox sites for played raids (mandate §18.2).
# One builder, per-region data from Defs.SITES. Open field: straight steering
# works, so no room graph here; huts are the only obstacles.
extends Node3D
class_name VillageBuilder

var chest_pos := Vector3.ZERO
var entry_pos := Vector3.ZERO

func build(site_id: String) -> void:
	var v: Dictionary = Defs.SITES[site_id]
	var o: Vector3 = v["origin"]
	chest_pos = o + v["objective_pos"]
	entry_pos = o + v["entry"]

	var ground := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(64, 0.4, 64)
	ground.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = v["ground_color"]
	ground.material_override = gmat
	ground.position = o + Vector3(0, -0.21, 0)
	add_child(ground)
	var gbody := StaticBody3D.new()
	gbody.collision_layer = Combat.MASK_WORLD
	var gcs := CollisionShape3D.new()
	var gsh := BoxShape3D.new()
	gsh.size = gm.size
	gcs.shape = gsh
	gbody.add_child(gcs)
	ground.add_child(gbody)

	for hut in v["huts"]:
		_hut(o + Vector3(hut[0], 0, hut[1]), Vector3(6, 3.2, 5), v["hut_color"])

	# Palisade: north wall with a gate gap; west/east walls; south open.
	var half: float = v["fence_half"]
	_fence_run(o + Vector3(0, 0, -half), half * 2.0, true)     # north + gate
	_fence_run(o + Vector3(-half, 0, 0), half * 2.0, false)    # west
	_fence_run(o + Vector3(half, 0, 0), half * 2.0, false)     # east

	# Tribute chest — the raid objective.
	var chest := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(1.6, 1.0, 1.0)
	chest.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.45, 0.32, 0.12)
	cmat.emission_enabled = true
	cmat.emission = Color(0.35, 0.22, 0.05)
	chest.material_override = cmat
	chest.position = chest_pos + Vector3(0, 0.5, 0)
	add_child(chest)

func _hut(pos: Vector3, size: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mi.material_override = mat
	mi.position = pos + Vector3(0, size.y / 2.0, 0)
	add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = Combat.MASK_WORLD
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	body.add_child(cs)
	mi.add_child(body)

func _fence_run(center: Vector3, length: float, horizontal: bool) -> void:
	# Palisade posts (visual) + one or two colliders. The NORTH run leaves a
	# gate gap in the middle; the horde enters from the SOUTH side (open).
	var post_count := int(length / 1.2)
	for i in range(post_count):
		var along := -length / 2.0 + 0.6 + float(i) * 1.2
		if horizontal and absf(along) < 2.6:
			continue   # gate gap
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.7, 2.6, 0.7)
		post.mesh = pm
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.28, 0.2, 0.13)
		post.material_override = pmat
		post.position = center + (Vector3(along, 1.3, 0) if horizontal else Vector3(0, 1.3, along))
		add_child(post)
	var body := StaticBody3D.new()
	body.collision_layer = Combat.MASK_WORLD
	body.position = center + Vector3(0, 1.3, 0)
	if horizontal:
		# Two collider halves flanking the gate gap.
		var half_len := (length - 5.2) / 2.0
		for sign_dir in [-1.0, 1.0]:
			var cs := CollisionShape3D.new()
			var sh := BoxShape3D.new()
			sh.size = Vector3(half_len, 2.6, 0.8)
			cs.shape = sh
			cs.position = Vector3(sign_dir * (half_len / 2.0 + 2.6), 0, 0)
			body.add_child(cs)
	else:
		var cs2 := CollisionShape3D.new()
		var sh2 := BoxShape3D.new()
		sh2.size = Vector3(0.8, 2.6, length)
		cs2.shape = sh2
		body.add_child(cs2)
	add_child(body)
