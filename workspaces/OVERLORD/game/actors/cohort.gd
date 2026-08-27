# CohortController — one cohort's shared brain.
# CommandIntent -> AssignmentPolicy -> FormationEnvelope -> MinionAgents.
# Formation is an ENVELOPE of preferred positions, not parade slots: minions
# keep local freedom inside it.
extends RefCounted
class_name CohortController

const BUBBLE_RADIUS := 3.1
const TRAIL_NEAR := 3.8
const TRAIL_FAR := 7.2

enum Mode { FOLLOW, HOLD, HUNT, INTERACT }

var id := ""
var members: Array = []          # Minion nodes
var mode: int = Mode.FOLLOW
var hold_point := Vector3.ZERO
var hunt_target: Node = null
var interact_task: Dictionary = {}   # {id, pos, slots:[Vector3], needed:int, progress, duration, on_complete:Callable}
var _work_started := false
# Headless-safe logging: HordeManager injects a sink; cohorts never touch
# autoloads directly (keeps them compilable in -s test contexts).
var event_sink: Callable = Callable()

func log_event(msg: String) -> void:
	if event_sink.is_valid():
		event_sink.call(msg)

func _init(p_id: String) -> void:
	id = p_id

func alive() -> Array:
	var out: Array = []
	for m in members:
		if is_instance_valid(m) and m.state != Minion.S.DEAD:
			out.append(m)
	return out

func count_alive() -> int:
	return alive().size()

# ------------------------------------------------------------- commands ------
func command_follow() -> void:
	mode = Mode.FOLLOW
	hunt_target = null
	interact_task = {}
	_release_workers()

func command_hold(point: Vector3) -> void:
	mode = Mode.HOLD
	hold_point = point
	hunt_target = null
	interact_task = {}
	_release_workers()

func command_hunt(target: Node) -> void:
	if target == null:
		return
	mode = Mode.HUNT
	hunt_target = target
	interact_task = {}
	for m in alive():
		m.order_engage(target)

func command_interact(task: Dictionary) -> void:
	mode = Mode.INTERACT
	interact_task = task
	_work_started = false
	var free := alive()
	free.sort_custom(func(a, b): return a.global_position.distance_to(task["pos"]) < b.global_position.distance_to(task["pos"]))
	var workers := mini(interact_task["needed"], free.size())
	for i in range(free.size()):
		if i < workers:
			var t := {
				"id": task["id"], "pos": task["pos"],
				"slot_pos": task["slots"][i % task["slots"].size()],
				"in_place": false,
			}
			free[i].order_interact(t)
		else:
			free[i].release_to_travel()

func _release_workers() -> void:
	for m in members:
		if is_instance_valid(m):
			m.release_to_travel()

# --------------------------------------------------------------- update ------
func update(sovereign: Node3D, dt: float) -> void:
	inject_delta(dt)
	var crew := alive()
	if crew.is_empty():
		return
	match mode:
		Mode.FOLLOW:
			_envelope_follow(crew, sovereign)
			_local_aggro(crew, sovereign)
		Mode.HOLD:
			_envelope_hold(crew)
			_local_aggro(crew, sovereign, true)
		Mode.HUNT:
			_envelope_hunt(crew)
		Mode.INTERACT:
			_envelope_interact(crew, dt)

func _envelope_follow(crew: Array, sovereign: Node3D) -> void:
	# v0.2 follow policy: the Sovereign owns an untouched personal bubble;
	# the horde trails BEHIND him in a soft staggered wedge. Minions never
	# occupy the bubble in FOLLOW and never overtake him (that is HUNT's job).
	var fwd := -sovereign.global_transform.basis.z   # where he FACES
	fwd.y = 0
	fwd = fwd.normalized()
	var back := -fwd
	var anchor: Vector3 = sovereign.global_position
	for i in range(crew.size()):
		var m = crew[i]
		var slot_angle := deg_to_rad(lerpf(-55.0, 55.0, fmod(float(i), 6.0) / 5.0))
		var arc := float(int(i / 6))                  # 0 near arc, 1 far arc
		var type_bias := 0.35 if m.type_id == "brute" else 0.0
		var radius := TRAIL_NEAR + type_bias + arc * 1.8 + 0.18 * float(i % 3)
		var dir := back.rotated(Vector3.UP, slot_angle)
		m.assign_slot(anchor + dir * radius)


## Testable invariant: every FOLLOW slot lies BEHIND the Sovereign and outside
## his personal bubble. Guards the v0.2 follow redesign in unit tests.
static func follow_slot_is_valid(slot: Vector3, sovereign_pos: Vector3, sovereign_fwd: Vector3) -> bool:
	var offset: Vector3 = slot - sovereign_pos
	offset.y = 0
	if offset.length() < BUBBLE_RADIUS + 0.2:
		return false
	var flat_fwd := Vector3(sovereign_fwd.x, 0, sovereign_fwd.z).normalized()
	return Vector3(offset.x, 0, offset.z).normalized().dot(flat_fwd) < 0.25

func _envelope_hold(crew: Array) -> void:
	for i in range(crew.size()):
		var m = crew[i]
		# Golden-angle spiral disc: organic cluster, not a grid.
		var ang := float(i) * 2.39996
		var r := 0.9 + sqrt(float(i)) * 0.85
		m.assign_slot(hold_point + Vector3(cos(ang) * r, 0, sin(ang) * r))

func _envelope_hunt(crew: Array) -> void:
	if hunt_target == null or Combat.target_spent(hunt_target):
		command_follow()
		return
	for i in range(crew.size()):
		var m = crew[i]
		var ang := float(i) * TAU / float(maxi(crew.size(), 1))
		var r := 1.7 + 0.14 * float(i % 3)
		m.assign_slot(hunt_target.global_position + Vector3(cos(ang) * r, 0, sin(ang) * r))
		# Stun/interrupt recovery: a hunter who dropped out re-locks the prey.
		if m.state != Minion.S.ENGAGE and m.state != Minion.S.INTERACT:
			m.order_engage(hunt_target)

func _envelope_interact(crew: Array, dt: float) -> void:
	if interact_task.is_empty():
		command_follow()
		return
	# Crew casualties abort the task instead of freezing the winch forever.
	if crew.size() < int(interact_task["needed"]):
		log_event("Crew lost — the %s work halts." % str(interact_task.get("id", "task")))
		interact_task = {}
		mode = Mode.FOLLOW
		_release_workers()
		return
	var ready_count := 0
	for m in crew:
		if m.state == Minion.S.INTERACT and m.interact_task.get("in_place", false):
			ready_count += 1
	if ready_count >= mini(int(interact_task["needed"]), crew.size()):
		if not _work_started:
			_work_started = true
			interact_task["progress"] = 0.0
		interact_task["progress"] += dt
		if interact_task["progress"] >= float(interact_task["duration"]):
			var cb: Callable = interact_task["on_complete"]
			interact_task = {}
			mode = Mode.FOLLOW
			_release_workers()
			cb.call()
	else:
		_work_started = false

func inject_delta(_dt: float) -> void:
	pass

func _local_aggro(crew: Array, sovereign: Node3D, leash_to_hold: bool = false) -> void:
	var space_state: PhysicsDirectSpaceState3D = (crew[0] as Node3D).get_world_3d().direct_space_state
	for m in crew:
		if m.state == Minion.S.INTERACT or m.state == Minion.S.STUNNED:
			continue
		if m.state != Minion.S.ENGAGE:
			var e = m.find_local_enemy(space_state)
			if e != null and (e.global_position.distance_to(m.global_position) < Minion.AGGRO_RADIUS \
					or e.global_position.distance_to(sovereign.global_position) < Minion.AGGRO_RADIUS):
				m.order_engage(e)
		else:
			var target_dist: float = 0.0
			if not Combat.target_spent(m.combat_target):
				var duty_anchor := hold_point if leash_to_hold else sovereign.global_position
				target_dist = m.combat_target.global_position.distance_to(duty_anchor)
			if Combat.target_spent(m.combat_target) \
					or target_dist > Minion.DISENGAGE_RADIUS + (0.0 if leash_to_hold else 3.0):
				m.release_to_travel()
