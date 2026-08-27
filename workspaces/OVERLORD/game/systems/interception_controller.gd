# InterceptionController — physical border contact with THE SAME expedition.
# Heroes try to break through toward the fortress; wounds and finite resources
# are snapshotted back into the strategic journey if they survive.
extends Node
class_name InterceptionController

signal resolved(expedition_id: String, outcome: String, survivors: Array)

var expedition: Dictionary
var heroes: Array = []
var breakthrough_pos := Vector3.ZERO
var elapsed := 0.0
var finished := false
var _crossed: Array = []

func setup(e: Dictionary, root: Node3D, spawn: Vector3, p_breakthrough: Vector3) -> void:
	expedition = e
	breakthrough_pos = p_breakthrough
	var recipe: Dictionary = e["recipe"]
	var roles: Array = recipe.get("roles", [])
	for i in range(roles.size()):
		var r: Dictionary = roles[i]
		var h := Hero.new()
		h.setup(str(r["role"]), float(r.get("quality", 1.0)), r)
		if r.has("resources"):
			h.restore_resources(r["resources"])
		if r.has("hp_frac"):
			h.hp = clampf(float(r["hp_frac"]), 0.05, 1.0) * h.max_hp
		root.add_child(h)
		h.global_position = spawn + Vector3((float(i) - float(roles.size() - 1) / 2.0) * 1.4, 0, randf_range(-1.2, 1.2))
		h.has_goal = true
		h.move_goal = breakthrough_pos
		h.path_pts = [breakthrough_pos]
		heroes.append(h)
	Safe.tel().ev("interception_started", {"id": e["id"], "heroes": heroes.size()})

func _physics_process(dt: float) -> void:
	if finished:
		return
	elapsed += dt
	var live := _live()
	if live.is_empty():
		_finish("broken", [])
		return

	# Keep the expedition's strategic intention legible: get THROUGH the line.
	for h in live:
		if not h.has_goal or h.path_pts.is_empty():
			h.has_goal = true
			h.move_goal = breakthrough_pos
			h.path_pts = [breakthrough_pos]
		if h.global_position.distance_to(breakthrough_pos) < 2.4 and not _crossed.has(h):
			_crossed.append(h)

	# Everyone who can still move broke through: carry their current state onward.
	# Do not compare array sizes: a hero who crossed and then died must not make
	# an uncrossed survivor count as having crossed.
	var all_live_crossed := true
	for h in live:
		if not _crossed.has(h):
			all_live_crossed = false
			break
	if all_live_crossed:
		var survivors := _snapshots(live)
		_finish("continued" if survivors.size() >= 2 else "aborted", survivors)
		return

	# A border fight should not become an endless arena. After 55s, survivors
	# disengage; severely depleted expeditions turn home instead of suiciding.
	if elapsed >= 55.0:
		var survivors := _snapshots(live)
		var avg_hp := _avg_hp(live)
		var avg_res := _avg_resources(live)
		var outcome := "aborted" if survivors.size() <= 1 or avg_hp < 0.30 or avg_res < 0.18 else "continued"
		_finish(outcome, survivors)

func force_sovereign_defeat() -> void:
	if finished:
		return
	_finish("continued", _snapshots(_live()))

func _live() -> Array:
	var out: Array = []
	for h in heroes:
		if is_instance_valid(h) and not h.down and not h.is_queued_for_deletion():
			out.append(h)
	return out

func _snapshots(group: Array) -> Array:
	var out: Array = []
	for h in group:
		var snap: Dictionary = h.identity_snapshot()
		snap["hp_frac"] = clampf(h.hp / h.max_hp, 0.05, 1.0)
		snap["resources"] = h.resource_snapshot()
		out.append(snap)
	return out

func _avg_hp(group: Array) -> float:
	if group.is_empty(): return 0.0
	var total := 0.0
	for h in group: total += h.hp / h.max_hp
	return total / float(group.size())

func _avg_resources(group: Array) -> float:
	if group.is_empty(): return 0.0
	var total := 0.0
	for h in group: total += h.resource_fraction()
	return total / float(group.size())

func _finish(outcome: String, survivors: Array) -> void:
	if finished:
		return
	finished = true
	Safe.tel().ev("interception_result", {"id": expedition["id"], "outcome": outcome,
		"survivors": survivors.size(), "elapsed": elapsed})
	for h in heroes:
		if is_instance_valid(h):
			h.set_physics_process(false)
			h.velocity = Vector3.ZERO
			h.queue_free()
	resolved.emit(str(expedition["id"]), outcome, survivors)
