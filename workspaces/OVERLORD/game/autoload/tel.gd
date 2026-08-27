# TEL — full-session local telemetry for the AI co-dev loop (mandate §25/§26).
# Writes one JSON object per line to user://telemetry/session_<unix>.jsonl:
# player inputs, command usage, damage/death flows, macro actions, expedition
# lifecycle, and performance samples. No network. The agent reads the files.
extends Node

var dir_override := ""          # tests redirect here (e.g. "user://tel_test/")
var enabled := true
var _file: FileAccess = null
var _path := ""
var _sim_accum := 0.0
var _move_accum := 0.0
var _perf_accum := 0.0

func _ready() -> void:
	var win := DisplayServer.window_get_size()
	ev("session_start", {"godot": Engine.get_version_info()["string"],
		"screen": "%dx%d" % [win.x, win.y]})


func _dir() -> String:
	return dir_override if dir_override != "" else "user://telemetry/"


func _ensure_file() -> bool:
	if not enabled:
		return false
	if _file != null and _file.is_open():
		return true
	var d := _dir()
	DirAccess.make_dir_recursive_absolute(d)
	var stamp := int(Time.get_unix_time_from_system())
	_path = d + "session_%d.jsonl" % stamp
	_file = FileAccess.open(_path, FileAccess.WRITE_READ)
	if _file == null:
		enabled = false
		return false
	_file.seek_end()
	return true


func ev(type: String, fields: Dictionary = {}) -> void:
	if not _ensure_file():
		return
	var rec := {"t_s": _sim_time(), "wall": Time.get_unix_time_from_system(), "type": type}
	for k in fields:
		rec[k] = fields[k]
	_file.store_line(JSON.stringify(rec))


func _sim_time() -> float:
	return GS.world.time if GS != null and GS.world != null else Time.get_ticks_msec() / 1000.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _file != null and _file.is_open():
			ev("session_end", {})
			_file.close()


# ------------------------------------------------------------- samplers ------
func _physics_process(dt: float) -> void:
	_move_accum += dt
	_sim_accum += dt
	_perf_accum += dt
	if _move_accum >= 0.25:
		_move_accum = 0.0
		_sample_movement()
	if _sim_accum >= 0.5:
		_sim_accum = 0.0
		_sample_state()
	if _perf_accum >= 1.0:
		_perf_accum = 0.0
		ev("perf", {"fps": Engine.get_frames_per_second(),
			"proc_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
			"phys_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01)})


func _sample_movement() -> void:
	if _map_open():
		return
	var v := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if v.length_squared() < 0.01:
		return
	ev("input_move", {"x": snappedf(v.x, 0.01), "z": snappedf(v.y, 0.01),
		"sprint": Input.is_action_pressed("sprint")})


func _sample_state() -> void:
	if GS == null or GS.main == null or not is_instance_valid(GS.main):
		return
	var m = GS.main
	var rec := {
		"sov_hp_frac": snappedf(m.sovereign.hp / m.sovereign.max_hp, 0.01),
		"sov_z": snappedf(m.sovereign.global_position.z, 0.1),
		"minions": GS.minions_alive,
		"cmd": m.horde.current_mode_name(),
		"fear": GS.world.fear, "threat": GS.world.threat, "gold": GS.world.gold,
		"outdoor": m.outdoor_region,
	}
	# §36 horde spacing + camera telemetry.
	var sov_pos: Vector3 = m.sovereign.global_position
	var fwd: Vector3 = (m.sovereign.facing if "facing" in m.sovereign else Vector3(0, 0, -1))
	var dists: Array = []
	var bubble := 0
	var ahead := 0
	var behind := 0
	for cc in m.horde.cohorts:
		for mm in cc.alive():
			var d3: Vector3 = (mm as Node3D).global_position - sov_pos
			dists.append(Vector2(d3.x, d3.z).length())
			var flat := Vector3(d3.x, 0, d3.z)
			if flat.length() < CohortController.BUBBLE_RADIUS:
				bubble += 1
			if Vector3(fwd.x, 0, fwd.z).normalized().dot(flat.normalized()) > 0.2:
				ahead += 1
			else:
				behind += 1
	dists.sort()
	if not dists.is_empty():
		rec["minion_nearest"] = snappedf(dists[0], 0.1)
		rec["minion_median"] = snappedf(dists[int(dists.size() / 2)], 0.1)
	rec["bubble_violations"] = bubble
	rec["ahead"] = ahead
	rec["behind"] = behind
	if m.cam_rig != null and is_instance_valid(m.cam_rig):
		rec["cam_yaw"] = snappedf(m.cam_rig.yaw, 0.01)
		rec["cam_pitch"] = snappedf(m.cam_rig.pitch, 0.01)
		rec["look_events"] = m.cam_rig.look_motion_events
	if m.party != null and is_instance_valid(m.party):
		rec["party_state"] = PartyController.P.keys()[m.party.state]
		rec["party_conf"] = int(m.party.confidence)
		rec["party_alive"] = m.party.live_members().size()
	ev("state", rec)

func _map_open() -> bool:
	return GS != null and GS.main != null and is_instance_valid(GS.main) \
		and GS.main.world_map.open

# ------------------------------------------------------------ game events ----
static func kind_of(n: Node) -> String:
	if n == null or not is_instance_valid(n):
		return "?"
	if n.is_in_group(Combat.GROUP_SOVEREIGN):
		return "sovereign"
	if n.is_in_group(Combat.GROUP_HEROES):
		return "hero:" + str(n.def["label"]) if "def" in n else "hero"
	if n.is_in_group("militia"):
		return ("captain" if n.is_captain else "militia")
	if n.is_in_group(Combat.GROUP_MINIONS):
		return "minion:" + str(n.type_id) + (":LT" if n.is_lieutenant else "")
	return n.get_class()


func hit(target: Node, amount: float, source: Node) -> void:
	ev("damage", {"to": kind_of(target), "from": kind_of(source),
		"dmg": snappedf(amount, 0.1)})


func heal(target: Node, amount: float, source: Node) -> void:
	ev("heal", {"to": kind_of(target), "from": kind_of(source),
		"amount": snappedf(amount, 0.1)})


func death(target: Node) -> void:
	ev("death", {"who": kind_of(target)})
