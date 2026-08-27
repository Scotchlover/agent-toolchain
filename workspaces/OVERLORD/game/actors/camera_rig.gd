# Third-person camera rig: yaw pivot -> pitch -> spring arm -> camera.
# v0.3: gameplay look is handled before GUI, yaw is wrapped to avoid unbounded
# rotations, and camera collision/impact recovery uses frame-rate independent
# smoothing instead of high-frequency random jitter.
extends Node3D
class_name CameraRig

const LOOK_SENS_X := 0.00245
const LOOK_SENS_Y := 0.00215
const INVERT_Y := false
const FOLLOW_HEIGHT := 1.9
const FOLLOW_RESPONSE := 14.0
const ZOOM_RESPONSE := 12.0
const SHAKE_FREQ := 23.0

var cam: Camera3D
var spring: SpringArm3D
var yaw := 0.0
var pitch := -0.32
var arm_length := 6.5
var follow_target: Node3D
var shake := 0.0
var look_motion_events := 0
var _shake_phase := 0.0

func setup(p_target: Node3D, initial_yaw: float = 0.0) -> void:
	follow_target = p_target
	yaw = wrapf(initial_yaw, -PI, PI)
	spring = SpringArm3D.new()
	spring.spring_length = arm_length
	spring.collision_mask = Combat.MASK_WORLD
	spring.margin = 0.22
	add_child(spring)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.current = true
	spring.add_child(cam)
	_apply_rotation(0.0)

func _input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		# Godot yaw sign: subtracting positive mouse X turns view to screen-right.
		yaw = wrapf(yaw - event.relative.x * LOOK_SENS_X, -PI, PI)
		var dy: float = event.relative.y if not INVERT_Y else -event.relative.y
		pitch = clampf(pitch - dy * LOOK_SENS_Y, -1.08, 0.22)
		look_motion_events += 1
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			arm_length = clampf(arm_length - 0.7, 3.5, 10.0)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			arm_length = clampf(arm_length + 0.7, 3.5, 10.0)
			get_viewport().set_input_as_handled()

func _physics_process(dt: float) -> void:
	if follow_target != null and is_instance_valid(follow_target):
		var wanted := follow_target.global_position + Vector3(0, FOLLOW_HEIGHT, 0)
		var follow_alpha := 1.0 - exp(-FOLLOW_RESPONSE * dt)
		global_position = global_position.lerp(wanted, follow_alpha)
	if spring != null:
		var zoom_alpha := 1.0 - exp(-ZOOM_RESPONSE * dt)
		spring.spring_length = lerpf(spring.spring_length, arm_length, zoom_alpha)
	shake = maxf(0.0, shake - dt * 2.8)
	_shake_phase += dt * SHAKE_FREQ
	_apply_rotation(dt)

func _apply_rotation(_dt: float) -> void:
	# Smooth deterministic impact impulse. Random-per-frame shake caused visible
	# micro-jitter near walls/doors and made collision recovery look unstable.
	var amp := shake * shake * 0.045
	var sx := sin(_shake_phase * 1.31) * amp
	var sy := sin(_shake_phase * 0.83 + 1.7) * amp * 0.75
	rotation = Vector3(pitch + sx, yaw + sy, 0)

func flat_forward() -> Vector3:
	var b := cam.global_transform.basis if cam != null and is_instance_valid(cam) else global_transform.basis
	var out := -b.z
	out.y = 0
	return out.normalized() if out.length_squared() > 0.0001 else Vector3(0, 0, -1)

func flat_right() -> Vector3:
	var b := cam.global_transform.basis if cam != null and is_instance_valid(cam) else global_transform.basis
	var out := b.x
	out.y = 0
	return out.normalized() if out.length_squared() > 0.0001 else Vector3.RIGHT

func center_ray() -> Dictionary:
	var vp := get_viewport()
	var origin := cam.project_ray_origin(vp.get_visible_rect().size / 2.0)
	var dir := cam.project_ray_normal(vp.get_visible_rect().size / 2.0)
	return {"origin": origin, "dir": dir}

func crosshair_point(max_dist: float = 40.0) -> Vector3:
	var r := center_ray()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(r["origin"], r["origin"] + r["dir"] * max_dist, Combat.MASK_WORLD)
	var hit := space.intersect_ray(q)
	return hit["position"] if hit.has("position") else Vector3(r["origin"]) + Vector3(r["dir"]) * max_dist

func crosshair_actor(mask: int, max_dist: float = 45.0) -> Node:
	var r := center_ray()
	var ray_origin: Vector3 = r["origin"]
	var ray_dir: Vector3 = r["dir"]
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * max_dist, mask)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.has("collider"):
		var col := hit["collider"] as Node
		if col.is_in_group(Combat.GROUP_HEROES) or col.is_in_group("militia"):
			return col
	# Fallback: closest hostile actor to the ray within a cone (heroes + militia).
	var best: Node = null
	var best_d := max_dist
	var candidates: Array = []
	candidates.append_array(get_tree().get_nodes_in_group(Combat.GROUP_HEROES))
	candidates.append_array(get_tree().get_nodes_in_group("militia"))
	for h in candidates:
		if not is_instance_valid(h):
			continue
		if "dead" in h and h.dead:
			continue
		if h.has_method("is_down") and h.is_down():
			continue
		var body := h as Node3D
		var to_h: Vector3 = body.global_position + Vector3(0, 1, 0) - ray_origin
		var proj := to_h.dot(ray_dir)
		if proj < 0:
			continue
		var perp := (to_h - ray_dir * proj).length()
		if perp < 1.4 and proj < best_d:
			best_d = proj
			best = h
	return best
