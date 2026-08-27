# World map overlay: regions, hostile projects and persistent expedition tokens.
# v0.3 adds an explicit INTERCEPT decision once a force enters the Dark Domain.
extends CanvasLayer
class_name WorldMap

signal closed
signal raid_requested(region_id: String)
signal upgrade_requested(upgrade_id: String)
signal intercept_requested(expedition_id: String)

var panel: Control
var open := false
var info_label: Label
var _region_buttons := {}
var _upgrade_button: Button
var _intercept_button: Button
var _expedition_tokens: Array = []
const TOKEN_COUNT := 4

func build() -> void:
	panel = Control.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.01, 0.03, 0.92)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(dim)
	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.position = Vector2(40, 40)
	info_label.size = Vector2(770, 410)
	panel.add_child(info_label)
	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	hint.text = "Raid for power. Track hostile expeditions before they reach your gates. TAB to return."
	hint.position = Vector2(40, 850)
	panel.add_child(hint)

	_intercept_button = Button.new()
	_intercept_button.add_theme_font_size_override("font_size", 18)
	_intercept_button.position = Vector2(1120, 690)
	_intercept_button.size = Vector2(400, 78)
	_intercept_button.visible = false
	_intercept_button.pressed.connect(_on_intercept_pressed)
	panel.add_child(_intercept_button)

	_upgrade_button = Button.new()
	_upgrade_button.add_theme_font_size_override("font_size", 15)
	_upgrade_button.position = Vector2(1180, 800)
	_upgrade_button.pressed.connect(func():
		if not Safe.gs().domain.upgrades.has("soul_bell"):
			upgrade_requested.emit("soul_bell")
	)
	panel.add_child(_upgrade_button)
	for i in range(TOKEN_COUNT):
		var token := Label.new()
		token.add_theme_font_size_override("font_size", 18)
		token.add_theme_color_override("font_color", Color(1.0, 0.28, 0.18))
		token.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		token.add_theme_constant_override("shadow_offset_x", 2)
		token.add_theme_constant_override("shadow_offset_y", 2)
		token.size = Vector2(240, 58)
		token.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		token.visible = false
		panel.add_child(token)
		_expedition_tokens.append(token)
	add_child(panel)
	panel.visible = false
	_build_regions()

func _build_regions() -> void:
	for id in Defs.REGIONS.keys():
		var r: Dictionary = Defs.REGIONS[id]
		if r.has("home"):
			var home := Label.new()
			home.text = "♛ DARK DOMAIN"
			home.add_theme_font_size_override("font_size", 19)
			home.add_theme_color_override("font_color", Color(0.65, 0.3, 0.75))
			home.position = _region_screen_pos(id) - Vector2(70, 12)
			panel.add_child(home)
			continue
		var b := Button.new()
		b.text = r["label"]
		b.add_theme_font_size_override("font_size", 17)
		b.position = _region_screen_pos(id)
		b.pressed.connect(_on_region_pressed.bind(id))
		panel.add_child(b)
		_region_buttons[id] = b

func _region_screen_pos(id: String) -> Vector2:
	var p: Array = Defs.REGIONS[id]["pos"]
	return Vector2(float(p[0]) * 1500.0, float(p[1]) * 800.0)

func _on_region_pressed(id: String) -> void:
	if not Safe.gs().world.can_raid(id):
		return
	if Defs.REGIONS[id].get("played", false):
		toggle(false)
		raid_requested.emit(id)
	else:
		Safe.gs().raid_and_respond(id)
		toggle(false)

func _on_intercept_pressed() -> void:
	for e in Safe.gs().world.active_expeditions:
		if str(e.get("stage", "")) == "approach" and not bool(e.get("intercepted", false)):
			var id := str(e["id"])
			toggle(false)
			intercept_requested.emit(id)
			return

func toggle(force_open: Variant = null) -> void:
	var want: bool = force_open if force_open != null else not open
	open = want
	panel.visible = open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	Safe.tel().ev("world_map_open" if open else "world_map_close", {})
	if open:
		refresh()

func refresh() -> void:
	var w: WorldState = Safe.gs().world
	var lines: Array = []
	lines.append("DARK DOMAIN — seat of the Sovereign")
	lines.append("Power %d   Fear %d   Threat %d   Gold %d" % [w.power, w.fear, w.threat, w.gold])
	if not w.captives.is_empty():
		var captive := w.first_captive()
		lines.append("⛓ CAPTIVE — %s" % str(captive.get("name", "Unknown Hero")).to_upper())
	var notable: Array = []
	for hero_id in w.hero_roster:
		var hs: Dictionary = w.hero_roster[hero_id]
		if int(hs.get("encounters", 0)) > 0:
			notable.append("%s — %s · encounters %d · escapes %d" % [
				str(hs.get("name", hero_id)),
				str(hs.get("status", "unknown")).to_upper(),
				int(hs.get("encounters", 0)),
				int(hs.get("escapes", 0)),
			])
	if not notable.is_empty():
		lines.append("NOTABLE HEROES:")
		for line in notable:
			lines.append("  • " + line)
	lines.append("")
	if w.active_projects.is_empty():
		lines.append("No faction is currently mustering a new force.")
	else:
		lines.append("ENEMY PROJECTS — MUSTERING:")
		for p in w.active_projects:
			var pct := int(100.0 * float(p["progress"]) / float(p["duration"]))
			lines.append("  • %s — %d%% (%s)" % [Defs.ENEMY_PROJECTS[p["def_id"]]["label"], pct, p["faction"]])
			lines.append("    CAUSE: %s" % Defs.ENEMY_PROJECTS[p["def_id"]]["cause"])
	if not w.active_expeditions.is_empty():
		lines.append("")
		lines.append("⚠ EXPEDITIONS IN THE FIELD:")
		for e in w.active_expeditions:
			var route_labels: Array = []
			for id in e.get("route", []):
				route_labels.append(Defs.REGIONS[str(id)]["label"])
			lines.append("  ⚔ %s — %s — ETA %ds" % [e["label"], str(e["stage"]).to_upper(), ceili(ExpeditionJourney.eta_seconds(e))])
			lines.append("    %s" % " → ".join(route_labels))
	if not w.knowledge.is_empty():
		lines.append("")
		lines.append("Enemy knowledge of your domain:")
		if w.knowledge.get("route", "") == "sally_port":
			lines.append("  • A scout escaped knowing the crypt sally port")
		for t in w.knowledge.get("trap_seen", []):
			lines.append("  • They know about the %s" % t.replace("_", " "))
	info_label.text = "\n".join(lines)

	for id in _region_buttons.keys():
		var r: Dictionary = Defs.REGIONS[id]
		var btn: Button = _region_buttons[id]
		var req := ""
		if r.has("req_fear") and w.fear < int(r["req_fear"]):
			req = "\n(needs Fear %d)" % int(r["req_fear"])
		elif r.has("req_threat") and w.threat < int(r["req_threat"]):
			req = "\n(needs Threat %d)" % int(r["req_threat"])
		elif r.get("played", false):
			req = "\n(personal assault)"
		btn.text = r["label"] + req
		btn.disabled = not w.can_raid(id)

	var interceptable: Dictionary = {}
	for e in w.active_expeditions:
		if str(e.get("stage", "")) == "approach" and not bool(e.get("intercepted", false)):
			interceptable = e
			break
	_intercept_button.visible = not interceptable.is_empty() and not Safe.gs().expedition_active
	if not interceptable.is_empty():
		_intercept_button.text = "⚔ INTERCEPT %s\nStrike at the Domain perimeter before the gates" % str(interceptable["label"]).to_upper()

	var bell: Dictionary = Defs.UPGRADES["soul_bell"]
	if Safe.gs().domain.upgrades.has("soul_bell"):
		_upgrade_button.text = "Soul Bell: INSTALLED"
		_upgrade_button.disabled = true
	else:
		_upgrade_button.text = "Raise the Soul Bell (%dg)\nRisen defend the crypt" % int(bell["cost"])
		_upgrade_button.disabled = w.gold < int(bell["cost"]) or Safe.gs().expedition_active
	_refresh_expedition_tokens(w.active_expeditions)

func _refresh_expedition_tokens(expeditions: Array) -> void:
	for i in range(_expedition_tokens.size()):
		var token: Label = _expedition_tokens[i]
		if i >= expeditions.size():
			token.visible = false
			continue
		var e: Dictionary = expeditions[i]
		var route: Array = e.get("route", [])
		if route.is_empty():
			token.visible = false
			continue
		var pos := _region_screen_pos(str(route[0]))
		if str(e.get("stage", "")) in ["approach", "intercepting"]:
			pos = _region_screen_pos("dark_domain")
		else:
			var idx := clampi(int(e.get("leg_index", 0)), 0, maxi(0, route.size() - 2))
			var a := _region_screen_pos(str(route[idx]))
			var b := _region_screen_pos(str(route[mini(idx + 1, route.size() - 1)]))
			var dur := maxf(0.001, float(e.get("leg_duration", ExpeditionJourney.LEG_DURATION)))
			var t := clampf(float(e.get("leg_progress", 0.0)) / dur, 0.0, 1.0)
			pos = a.lerp(b, t)
		token.position = pos - Vector2(110, 62)
		token.text = "⚔ %s\n%s" % [str(e["label"]).to_upper(), "INTERCEPTED" if str(e.get("stage", "")) == "intercepting" else "ETA %ds" % ceili(ExpeditionJourney.eta_seconds(e))]
		token.visible = true

func _process(_dt: float) -> void:
	if open:
		refresh()
