# HordeManager — the whole horde as one command surface for the Sovereign.
# No RTS selection: commands originate from the third-person protagonist.
extends Node
class_name HordeManager

var cohorts: Array = []
var sovereign: Sovereign
var fortress: FortressBuilder
var empower_left := 0.0

func setup(p_sovereign: Sovereign, p_fortress: FortressBuilder, root: Node3D) -> void:
	sovereign = p_sovereign
	fortress = p_fortress
	var idx := 0
	for cdef in Defs.COHORTS:
		var cc := CohortController.new(cdef["id"])
		cc.event_sink = func(msg: String): Safe.gs().el(msg)
		for i in range(int(cdef["count"])):
			var m := Minion.new()
			m.setup(cdef["type"], cdef["id"], i)
			root.add_child(m)
			m.global_position = Defs.HORDE_SPAWN + Vector3(randf_range(-2.5, 2.5) + idx * 0.3, 0.6, randf_range(-1.5, 1.5))
			if cdef.has("lieutenant") and i == 0:
				m.promote_lieutenant(cdef["lieutenant"])
				m.set_meta("lt_scale", float(cdef["lieutenant"].get("scale", 1.35)))
			cc.members.append(m)
			idx += 1
		cohorts.append(cc)
	refresh_alive_count()

func _physics_process(dt: float) -> void:
	if sovereign == null or not is_instance_valid(sovereign):
		return
	empower_left = maxf(0.0, empower_left - dt)
	for cc in cohorts:
		cc.update(sovereign, dt)
	refresh_alive_count()

# ------------------------------------------------------------- commands ------
func issue_follow() -> void:
	for cc in cohorts: cc.command_follow()
	Safe.main().play_sfx("follow", 0)
	Safe.main().spawn_marker(sovereign.global_position,
		Vector3(4.4, 0.05, 4.4), Color(0.5, 1.0, 0.6, 0.8), 0.8, true)
	Safe.gs().el("Horde: FOLLOW your shadow.")

func issue_hold(point: Vector3) -> void:
	for cc in cohorts: cc.command_hold(point)
	Safe.main().play_sfx("hold", 0)
	Safe.main().spawn_marker(point + Vector3(0, 0.02, 0),
		Vector3(7.0, 0.06, 7.0), Color(0.35, 0.55, 1.0, 0.75), 4.0, true)
	Safe.gs().el("Horde: HOLD this ground.")

func issue_hunt(target: Node) -> void:
	if target == null or Combat.target_spent(target):
		Safe.gs().el("The horde snarls — no prey in sight.")
		play_sfx_quiet("hold")
		return
	for cc in cohorts: cc.command_hunt(target)
	Safe.main().play_sfx("hunt", 0)
	var t3 := target as Node3D
	if t3 != null and Safe.main() != null:
		Safe.main().spawn_marker(t3.global_position + Vector3(0, 3.2, 0),
			Vector3(0.45, 6.5, 0.45), Color(1.0, 0.25, 0.2, 0.85), 2.5)
		Safe.main().spawn_marker(t3.global_position + Vector3(0, 0.03, 0),
			Vector3(2.6, 0.06, 2.6), Color(1.0, 0.25, 0.2, 0.8), 2.5, true)
	Safe.gs().el("Horde: HUNT it down!")

func empower(duration: float) -> void:
	empower_left = maxf(empower_left, duration)
	for cc in cohorts:
		for m in cc.alive():
			m.empower(duration)
	Safe.tel().ev("horde_empowered", {"duration": duration, "minions": total_alive()})
	if Safe.main() != null:
		Safe.main().spawn_marker(sovereign.global_position + Vector3(0, 0.05, 0),
			Vector3(8.0, 0.08, 8.0), Color(0.75, 0.12, 0.85, 0.75), 1.4, true)

func is_empowered() -> bool:
	return empower_left > 0.0

func play_sfx_quiet(cue: String) -> void:
	var m = Safe.main()
	if m != null:
		m.play_sfx(cue, 150)

func issue_portcullis_toggle() -> void:
	if Safe.gs().domain.is_raid_system_disabled("gate_controls"):
		Safe.gs().el("The gate controls are SABOTAGED — the winch will not answer.")
		Safe.tel().ev("lair_system_blocked_command", {"system": "gate_controls"})
		return
	var gate = fortress.interactables["gate_portcullis"]
	var lowering: bool = gate["target_y"] >= gate["raised_y"]
	var slots := _crank_slots(gate["pos"])
	var needed := 4
	var duration := 3.0
	if total_alive() < needed:
		Safe.gs().el("Not enough minions to work the winch (need %d)." % needed)
		return
	for cc in cohorts:
		cc.command_interact({
			"id": "portcullis", "pos": gate["pos"], "slots": slots,
			"needed": needed, "duration": duration, "progress": 0.0,
			"on_complete": func(): _finish_gate(lowering),
		})
	Safe.gs().el("The horde heaves the winch...")

func _finish_gate(lowering: bool) -> void:
	var gate = fortress.interactables["gate_portcullis"]
	gate["target_y"] = gate["lowered_y"] if lowering else gate["raised_y"]
	Safe.gs().domain.portcullis_open = not lowering
	Safe.gs().el("Portcullis %s." % ("LOWERED" if lowering else "RAISED"))

func _crank_slots(pos: Vector3) -> Array:
	var out: Array = []
	for i in range(4):
		var ang := deg_to_rad(-60.0 + i * 40.0)
		out.append(pos + Vector3(cos(ang), 0, sin(ang)) * 2.2)
	return out

# --------------------------------------------------------------- queries -----
func nearest_minion_dist_to(pos: Vector3) -> float:
	var best := 99999.0
	for cc in cohorts:
		for m in cc.alive():
			best = minf(best, m.global_position.distance_to(pos))
	return best

func refresh_alive_count() -> int:
	var n := total_alive()
	Safe.gs().minions_alive = n
	return n

func total_alive() -> int:
	var n := 0
	for cc in cohorts:
		n += cc.count_alive()
	return n

func cohort_summary() -> String:
	var parts: Array = []
	for cc in cohorts:
		parts.append("%s %d/%d" % [cc.id.capitalize(), cc.count_alive(), cc.members.size()])
	var suffix := " · DREAD" if is_empowered() else ""
	return " | ".join(parts) + suffix

func current_mode_name() -> String:
	if cohorts.is_empty():
		return "-"
	return CohortController.Mode.keys()[cohorts[0].mode].capitalize()

func get_pinned_heroes() -> Array:
	var out: Array = []
	for h in get_tree().get_nodes_in_group(Combat.GROUP_HEROES):
		if is_instance_valid(h) and h.pinned:
			out.append(h)
	return out

func remuster(root: Node3D) -> void:
	for cc in cohorts.duplicate():
		for m in cc.members:
			if is_instance_valid(m):
				m.queue_free()
		cohorts.erase(cc)
	var idx := 0
	for cdef in Defs.COHORTS:
		var cc := CohortController.new(cdef["id"])
		cc.event_sink = func(msg: String): Safe.gs().el(msg)
		for i in range(int(cdef["count"])):
			var m := Minion.new()
			m.setup(cdef["type"], cdef["id"], i)
			root.add_child(m)
			m.global_position = Defs.HORDE_SPAWN + Vector3(randf_range(-2.0, 2.0), 0.6, randf_range(-1.0, 2.0))
			if cdef.has("lieutenant") and i == 0:
				m.promote_lieutenant(cdef["lieutenant"])
				m.set_meta("lt_scale", float(cdef["lieutenant"].get("scale", 1.35)))
			cc.members.append(m)
			idx += 1
		cohorts.append(cc)
		cc.command_follow()
	refresh_alive_count()
	Safe.gs().el("The horde re-musters from the dark.")

func raise_risen(count: int, pos: Vector3, root: Node3D) -> void:
	var cc := CohortController.new("risen")
	cc.event_sink = func(msg: String): Safe.gs().el(msg)
	for i in range(count):
		var m := Minion.new()
		m.setup("skeleton", "risen", i)
		root.add_child(m)
		m.global_position = pos + Vector3(randf_range(-1.6, 1.6), 0.6, randf_range(-1.0, 1.6))
		cc.members.append(m)
	cc.command_follow()
	cohorts.append(cc)
	refresh_alive_count()

func return_home(spawn: Vector3) -> void:
	for cc in cohorts:
		var i := 0
		for m in cc.members:
			if is_instance_valid(m) and m.state != Minion.S.DEAD:
				m.global_position = spawn + Vector3(randf_range(-2.4, 2.4) + i * 0.15, 0.6, randf_range(-1.5, 1.5))
				i += 1
		cc.command_follow()
