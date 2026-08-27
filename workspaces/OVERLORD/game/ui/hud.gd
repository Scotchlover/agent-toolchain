# HUD — only what matters during play: Sovereign vitals, horde command state,
# world pressure readout, event log, context prompts. No RTS dashboard.
extends CanvasLayer
class_name HUD

var log_label: Label
var hp_bar: ColorRect
var hp_back: ColorRect
var hp_text: Label
var cmd_label: Label
var stats_label: Label
var prompt_label: Label
var project_label: Label
var objective_label: Label
var raid_back: ColorRect
var raid_label: Label
var banner_title: Label
var banner_sub: Label
var _banner_queue: Array = []
var _banner_t := 0.0

func build() -> void:
	log_label = _label(14, Color(0.9, 0.88, 0.8), Vector2(16, 12))
	log_label.size = Vector2(560, 200)

	hp_back = ColorRect.new()
	hp_back.color = Color(0, 0, 0, 0.55)
	hp_back.position = Vector2(16, 810)
	hp_back.size = Vector2(320, 26)
	add_child(hp_back)
	hp_bar = ColorRect.new()
	hp_bar.color = Color(0.62, 0.1, 0.14)
	hp_bar.position = Vector2(18, 812)
	hp_bar.size = Vector2(316, 22)
	add_child(hp_bar)
	hp_text = _label(13, Color.WHITE, Vector2(24, 813))

	cmd_label = _label(15, Color(0.95, 0.85, 0.4), Vector2(500, 775))
	cmd_label.size = Vector2(820, 96)
	stats_label = _label(15, Color(0.8, 0.85, 0.95), Vector2(1360, 12))
	project_label = _label(15, Color(0.95, 0.6, 0.4), Vector2(1305, 168))
	project_label.size = Vector2(280, 150)

	objective_label = _label(20, Color(1.0, 0.9, 0.55), Vector2(560, 46))
	objective_label.size = Vector2(480, 60)
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	raid_back = ColorRect.new()
	raid_back.position = Vector2(420, 92)
	raid_back.size = Vector2(760, 154)
	raid_back.color = Color(0.18, 0.015, 0.01, 0.74)
	raid_back.visible = false
	raid_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(raid_back)

	raid_label = _label(17, Color(1.0, 0.72, 0.38), Vector2(445, 104))
	raid_label.size = Vector2(710, 134)
	raid_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	raid_label.visible = false

	banner_title = _label(34, Color(1.0, 0.85, 0.3), Vector2(300, 220))
	banner_title.size = Vector2(1000, 60)
	banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_title.visible = false
	banner_sub = _label(17, Color(0.92, 0.92, 0.97), Vector2(300, 254))
	banner_sub.size = Vector2(1000, 60)
	banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_sub.visible = false

	prompt_label = _label(19, Color(1.0, 0.95, 0.7), Vector2(700, 480))
	var dot := ColorRect.new()
	dot.color = Color(1, 1, 1, 0.75)
	dot.position = Vector2(797, 447)
	dot.size = Vector2(5, 5)
	add_child(dot)
	enforce_passive_mouse_filter(self)

static func enforce_passive_mouse_filter(root: Node) -> void:
	for c in root.find_children("*", "Control", true, false):
		var ctrl := c as Control
		if ctrl is Button or ctrl is BaseButton:
			continue
		ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_objective(text: String) -> void:
	objective_label.text = text

func queue_banner(title: String, sub: String = "") -> void:
	_banner_queue.append([title, sub])

static func nearest_expedition(expeditions: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_eta: float = INF
	for item in expeditions:
		var e: Dictionary = item
		var eta: float = ExpeditionJourney.eta_seconds(e)
		if eta < best_eta:
			best_eta = eta
			best = e
	return best

static func expedition_alert_text(e: Dictionary) -> String:
	if e.is_empty():
		return ""
	var stage := str(e.get("stage", "travelling"))
	var eta: int = ceili(ExpeditionJourney.eta_seconds(e))
	var label := str(e.get("label", "Expedition")).to_upper()
	if stage == "intercepting":
		return "⚠ %s — INTERCEPTION IN PROGRESS\nTHE BORDER BATTLE DECIDES WHO REACHES THE GATES" % label
	if stage == "approach":
		return "⚠⚠ %s — INSIDE YOUR DOMAIN\nFORTRESS CONTACT IN %ds · INTERCEPT NOW" % [label, eta]
	return "⚠ %s — EN ROUTE\nFORTRESS ETA %ds · TRACK ON WAR TABLE" % [label, eta]

func _process(dt: float) -> void:
	if _banner_queue.is_empty() and _banner_t <= 0.0:
		banner_title.visible = false
		banner_sub.visible = false
		return
	if _banner_t <= 0.0 and not _banner_queue.is_empty():
		var b: Array = _banner_queue.pop_front()
		banner_title.text = str(b[0])
		banner_sub.text = str(b[1])
		banner_title.visible = true
		banner_sub.visible = true
		banner_title.modulate.a = 1.0
		banner_sub.modulate.a = 1.0
		_banner_t = 4.2
	elif _banner_t > 0.0:
		_banner_t -= dt
		if _banner_t < 1.0:
			var a := clampf(_banner_t, 0.0, 1.0)
			banner_title.modulate.a = a
			banner_sub.modulate.a = a

func _label(sz: int, col: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.position = pos
	add_child(l)
	return l

func update_hud(sovereign: Sovereign, horde: HordeManager) -> void:
	var frac := sovereign.hp / sovereign.max_hp
	hp_bar.size.x = 316.0 * clampf(frac, 0.0, 1.0)
	hp_bar.color = Color(0.62, 0.1, 0.14) if frac > 0.35 else Color(0.9, 0.2, 0.1)
	hp_text.text = "SOVEREIGN %d / %d   ·   DOMINION %d / %d" % [
		ceili(sovereign.hp), int(sovereign.max_hp), int(sovereign.dominion), int(Sovereign.DOMINION_MAX)]
	cmd_label.text = "[%s]  %s\n1 FOLLOW · 2 HOLD · 3 HUNT   |   Q HEAVY · SPACE BRACE · RMB DREAD · R DREAD COMMAND\nBRUTES PIN · SKITTERERS INTERRUPT · HEAVY → EXPOSED → [3] HUNT" % [
		horde.current_mode_name(), horde.cohort_summary()]
	var w: WorldState = Safe.gs().world
	stats_label.text = "POWER %d\nFEAR %d\nTHREAT %d\nGOLD %d\nMinions %d" % [
		w.power, w.fear, w.threat, w.gold, Safe.gs().minions_alive]
	var lines: Array = Safe.gs().log.lines(9)
	log_label.text = "\n".join(lines)

	var main = Safe.main()
	if main != null and main.party != null and is_instance_valid(main.party) and not main.party.resolved:
		raid_back.visible = true
		raid_label.visible = true
		raid_label.text = "⚔ %s\n%s" % [str(main.party.label).to_upper(), main.party.player_status_line()]
		match main.party.confidence_band():
			"CONFIDENT":
				raid_label.modulate = Color(1.0, 0.78, 0.45)
				raid_back.color = Color(0.16, 0.035, 0.01, 0.76)
			"PRESSURED":
				raid_label.modulate = Color(1.0, 0.55, 0.28)
				raid_back.color = Color(0.22, 0.025, 0.01, 0.80)
			_:
				raid_label.modulate = Color(1.0, 0.28, 0.22)
				raid_back.color = Color(0.30, 0.01, 0.01, 0.86)
	elif not w.active_expeditions.is_empty():
		var incoming: Dictionary = nearest_expedition(w.active_expeditions)
		raid_back.visible = true
		raid_label.visible = true
		raid_label.text = expedition_alert_text(incoming)
		var urgent := str(incoming.get("stage", "")) in ["approach", "intercepting"]
		var pulse := 0.76 + 0.12 * sin(float(Time.get_ticks_msec()) * 0.008)
		raid_back.color = Color(0.32 if urgent else 0.18, 0.012, 0.01, pulse)
		raid_label.modulate = Color(1.0, 0.28, 0.16) if urgent else Color(1.0, 0.62, 0.28)
	else:
		raid_back.visible = false
		raid_label.visible = false
		raid_label.text = ""

	if w.active_projects.is_empty():
		project_label.text = ""
	else:
		var parts: Array = []
		for p in w.active_projects:
			var pct := int(100.0 * float(p["progress"]) / float(p["duration"]))
			parts.append("%s\n%d%%" % [Defs.ENEMY_PROJECTS[p["def_id"]]["label"], pct])
		project_label.text = "\n".join(parts)

func set_prompt(text: String) -> void:
	prompt_label.text = text
