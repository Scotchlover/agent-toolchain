# Combat helpers shared by all actors. Static, stateless.
extends RefCounted
class_name Combat

const GROUP_SOVEREIGN := "sovereign"
const GROUP_MINIONS := "minions"
const GROUP_HEROES := "heroes"

static func actors_in_radius(space: PhysicsDirectSpaceState3D, center: Vector3, radius: float, mask: int) -> Array:
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	params.shape = shape
	params.transform = Transform3D(Basis(), center)
	params.collision_mask = mask
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var out: Array = []
	for hit in space.intersect_shape(params, 64):
		var col = hit["collider"]
		if col is Node and (col as Node).has_method("take_damage"):
			out.append(col)
	return out

# Wide melee arc: radius query then angle filter against facing dir.
static func actors_in_arc(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3, range_: float, deg: float, mask: int) -> Array:
	var hits := actors_in_radius(space, origin, range_, mask)
	var flat := Vector3(dir.x, 0, dir.z).normalized()
	var out: Array = []
	for a in hits:
		if not is_instance_valid(a):
			continue
		var node := a as Node3D
		var to: Vector3 = node.global_position - origin
		to.y = 0
		if to.length() < 0.6:
			out.append(a)
			continue
		var ang := absf(flat.angle_to(to.normalized()))
		if ang <= deg_to_rad(deg / 2.0):
			out.append(a)
	return out

const MASK_WORLD := 1
const MASK_SOVEREIGN := 2
const MASK_MINION := 4
const MASK_HERO := 8
const MASK_LOCKS := 64   # vault door blockers: stop heroes, not the owner's horde

# A combat target is spent if freed OR down/dead (corpse-hugging stall guard).
static func target_spent(t: Node) -> bool:
	if t == null or not is_instance_valid(t):
		return true
	if t.has_method("is_down") and t.is_down():
		return true
	if "dead" in t and t.dead:
		return true
	return false
