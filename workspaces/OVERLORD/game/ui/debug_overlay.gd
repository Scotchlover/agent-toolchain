# Debug overlays F1/F2/F3: horde / party / world introspection.
extends CanvasLayer
class_name DebugOverlay

var label: Label
var mode := 0   # 0=off 1=horde 2=party 3=world

func build() -> void:
	label = Label.new()
	label.add_theme_font_size_override("font_size", 13)
	label.position = Vector2(600, 60)
	label.size = Vector2(900, 500)
	label.visible = false
	add_child(label)

func cycle(mode_id: int) -> void:
	mode = mode_id if mode != mode_id else 0
	label.visible = mode != 0

func _process(_dt: float) -> void:
	if mode == 0 or Safe.gs().main == null:
		return
	match mode:
		1: label.text = _horde_text()
		2: label.text = _party_text()
		3: label.text = _world_text()

func _horde_text() -> String:
	var horde = Safe.gs().main.horde
	var out := "== HORDE DEBUG ==\n"
	for cc in horde.cohorts:
		out += "[%s] mode=%s\n" % [cc.id, CohortController.Mode.keys()[cc.mode]]
		for m in cc.members:
			if not is_instance_valid(m):
				continue
			if m.state == Minion.S.DEAD:
				out += "  #%d DEAD\n" % m.cohort_slot
				continue
			var tgt := "-"
			if m.combat_target != null and is_instance_valid(m.combat_target):
				tgt = m.combat_target.def["label"] if m.combat_target is Hero else "Sovereign"
			var task := ""
			if not m.interact_task.is_empty():
				task = str(m.interact_task["id"])
			out += "  #%d %s slot=(%.1f,%.1f) tgt=%s task=%s\n" % [
				m.cohort_slot, Minion.S.keys()[m.state], m.slot_pos.x, m.slot_pos.z, tgt, task]
	return out

func _party_text() -> String:
	var pc = Safe.gs().main.party
	if pc == null:
		return "== PARTY DEBUG ==\n(no expedition)"
	var out := "== PARTY DEBUG ==\nOBJECTIVE: %s\nSTATE: %s\nCONFIDENCE: %d (%s)\nROUTE LEFT: %d legs\n" % [
		pc.objective, PartyController.P.keys()[pc.state], int(pc.confidence),
		PartyController.Conf.keys()[_conf_idx(pc)], pc.route.size()]
	for h in pc.members:
		if not is_instance_valid(h):
			continue
		out += "  %s hp=%.0f/%.0f %s%s\n" % [h.def["label"], h.hp, h.max_hp,
			("WORK:" + h.work_label + " ") if h.is_working() else "",
			"PINNED" if h.pinned else ("DOWN" if h.down else "")]
	return out

func _conf_idx(pc) -> int:
	if pc.confidence <= 30.0: return 2
	if pc.confidence <= 60.0: return 1
	return 0

func _world_text() -> String:
	var w: WorldState = Safe.gs().world
	var out := "== WORLD DEBUG ==\nseed=%d t=%.1f\nPower=%d Fear=%d Threat=%d Gold=%d\n" % [
		w.seed_value, w.time, w.power, w.fear, w.threat, w.gold]
	for f in w.factions.keys():
		out += "%s: hostility=%.0f quality=%.2f\n" % [f, w.factions[f]["hostility"], w.factions[f]["quality"]]
	for p in w.active_projects:
		out += "PROJECT %s %.0f/%.0fs\n" % [p["def_id"], float(p["progress"]), float(p["duration"])]
	out += "knowledge=%s\nraids=%s\nexpeditions_resolved=%d\nlast=%s\nportcullis_open=%s sally_sealed=%s traps=%s\n" % [
		str(w.knowledge), str(w.raid_counts), w.expeditions_resolved, w.last_result,
		str(Safe.gs().domain.portcullis_open), str(Safe.gs().domain.sally_sealed), str(Safe.gs().domain.traps_armed)]
	return out
