# DreadWave — the Sovereign's supernatural authority made physical.
# AoE knockback + stagger with a readable shockwave ring.
extends RefCounted
class_name DreadWave

static func burst(tree: SceneTree, center: Vector3, radius: float, dmg: float, owner_node: Node = null) -> void:
	# Prefer the live Main scene root; fall back to current_scene.
	var world_root: Node3D = null
	if Safe.gs() != null and Safe.gs().main != null and is_instance_valid(Safe.gs().main):
		world_root = Safe.gs().main as Node3D
	elif tree.current_scene is Node3D:
		world_root = tree.current_scene as Node3D
	if world_root == null:
		return
	# Heroes are already semantic actors tracked by group. A group-distance
	# query avoids PhysicsServer registration races for freshly spawned bodies
	# while preserving the current non-occluded radial gameplay contract.
	for h in tree.get_nodes_in_group(Combat.GROUP_HEROES):
		if not is_instance_valid(h) or Combat.target_spent(h):
			continue
		var delta: Vector3 = (h as Node3D).global_position - center
		if absf(delta.y) > 2.5 or Vector2(delta.x, delta.z).length() > radius:
			continue
		h.take_damage(dmg, owner_node)
		Safe.tel().hit(h, dmg, owner_node)
		h.stagger(1.6)
		h.knockback_from(center, 9.0)
		# Authority pulls aggro: the wave's author becomes the threat.
		if owner_node != null and "threat" in h:
			h.threat.add(owner_node, 14.0)
	_spawn_ring(world_root, center, radius)

static func _spawn_ring(root: Node3D, center: Vector3, radius: float) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.4
	torus.outer_radius = 0.5
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.15, 0.25)
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.1, 0.2)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.7
	ring.material_override = mat
	ring.position = Vector3(center.x, 0.3, center.z)
	root.add_child(ring)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(radius * 2.2, 1.0, radius * 2.2), 0.45)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.chain().tween_callback(ring.queue_free)
