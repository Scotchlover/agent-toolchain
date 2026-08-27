# FortressBuilder — constructs the authored greybox fortress + semantic nodes
# from Defs data. The scene mirrors DomainState; it never owns campaign truth.
extends Node3D
class_name FortressBuilder

const WALL_H := 4.0
const WALL_T := 0.5
const DOOR_W := 3.0

var interactables := {}   # registry consumed by main/horde/heroes
var _mat_floor: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_dark: StandardMaterial3D
var _room_idx := 0

func build() -> void:
	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_color = Color(0.16, 0.14, 0.13)
	_mat_floor.roughness = 1.0
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_color = Color(0.23, 0.21, 0.2)
	_mat_wall.roughness = 1.0
	_mat_dark = StandardMaterial3D.new()
	_mat_dark.albedo_color = Color(0.09, 0.08, 0.08)

	for room_id in Defs.ROOMS.keys():
		_build_room(room_id)
	for door in Defs.DOORS:
		_build_door(door)
	_build_traps()
	_build_objective()
	_build_lights()

# ------------------------------------------------------------------ rooms ----
func _build_room(room_id: String) -> void:
	var r := Defs.room_rect(room_id)
	var cx := r.position.x + r.size.x / 2.0
	var cz := r.position.y + r.size.y / 2.0
	var floor_mesh := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(r.size.x, 0.4, r.size.y)
	floor_mesh.mesh = fm
	floor_mesh.material_override = _mat_floor
	floor_mesh.position = Vector3(cx, -0.2, cz)
	add_child(floor_mesh)
	var static_floor := StaticBody3D.new()
	static_floor.collision_layer = 1
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = fm.size
	fshape.shape = fbox
	static_floor.add_child(fshape)
	floor_mesh.add_child(static_floor)

	# Walls: four sides, split around doors lying on that side.
	var doors_on := func(side: String) -> Array:
		var out: Array = []
		for door in Defs.DOORS:
			if _door_on_side(door, room_id, side, r):
				out.append(door)
		return out
	_room_idx += 1
	var eps := 0.006 * (_room_idx % 3)   # avoid coplanar z-fight on shared walls
	_build_wall_side(r, "north", Vector3(cx, WALL_H / 2.0, r.position.y - eps), r.size.x, doors_on.call("north"))
	_build_wall_side(r, "south", Vector3(cx, WALL_H / 2.0, r.end.y + eps), r.size.x, doors_on.call("south"))
	_build_wall_side(r, "west", Vector3(r.position.x - eps, WALL_H / 2.0, cz), r.size.y, doors_on.call("west"))
	_build_wall_side(r, "east", Vector3(r.end.x + eps, WALL_H / 2.0, cz), r.size.y, doors_on.call("east"))

func _door_on_side(door: Dictionary, room_id: String, side: String, r: Rect2) -> bool:
	if door["a"] != room_id and door["b"] != room_id:
		return false
	var p := Defs.door_pos(door)
	match side:
		"north": return absf(p.z - r.position.y) < 0.35 and p.x >= r.position.x - 0.1 and p.x <= r.end.x + 0.1
		"south": return absf(p.z - r.end.y) < 0.35 and p.x >= r.position.x - 0.1 and p.x <= r.end.x + 0.1
		"west":  return absf(p.x - r.position.x) < 0.35 and p.z >= r.position.y - 0.1 and p.z <= r.end.y + 0.1
		"east":  return absf(p.x - r.end.x) < 0.35 and p.z >= r.position.y - 0.1 and p.z <= r.end.y + 0.1
	return false

# Builds a wall along an axis with gaps for doors; lintel above each gap.
func _build_wall_side(r: Rect2, side: String, center: Vector3, length: float, doors: Array) -> void:
	var horizontal := side in ["north", "south"]
	var cuts: Array = []   # {c: float (center along wall), w: float (opening width)}
	for door in doors:
		var p := Defs.door_pos(door)
		cuts.append({"c": p.x if horizontal else p.z, "w": float(door.get("w", DOOR_W))})
	cuts.sort_custom(func(a, b): return a["c"] < b["c"])
	var seg_start := (r.position.x if horizontal else r.position.y)
	var seg_end := seg_start + length
	var cursor := seg_start
	for cut in cuts:
		var half: float = cut["w"] / 2.0
		var mid: float = cut["c"]
		_wall_segment(cursor, mid - half, center, horizontal, side == "east")
		# lintel over the opening
		var lintel_len := half * 2.0
		var lc := Vector3(center.x, center.y, center.z)
		if horizontal: lc.x = mid
		else: lc.z = mid
		var lm := MeshInstance3D.new()
		var lmesh := BoxMesh.new()
		lmesh.size = Vector3(lintel_len, WALL_H - 3.0, WALL_T) if horizontal else Vector3(WALL_T, WALL_H - 3.0, lintel_len)
		lm.mesh = lmesh
		lm.material_override = _mat_wall
		lm.position = Vector3(lc.x, 3.0 + (WALL_H - 3.0) / 2.0, lc.z)
		add_child(lm)
		cursor = mid + half
	_wall_segment(cursor, seg_end, center, horizontal, side == "east")

func _wall_segment(from_along: float, to_along: float, center: Vector3, horizontal: bool, east: bool) -> void:
	var len := to_along - from_along
	if len <= 0.05:
		return
	var mid := (from_along + to_along) / 2.0
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(len, WALL_H, WALL_T) if horizontal else Vector3(WALL_T, WALL_H, len)
	mi.mesh = mesh
	mi.material_override = _mat_wall
	var pos := Vector3(center.x, center.y, center.z)
	if horizontal: pos.x = mid
	else: pos.z = mid
	mi.position = pos
	add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = mesh.size
	cs.shape = sh
	body.add_child(cs)
	mi.add_child(body)

# ------------------------------------------------------------------ doors ----
func _build_door(door: Dictionary) -> void:
	var p := Defs.door_pos(door)
	match door["kind"]:
		"portcullis":
			_build_portcullis(door, p)
		"sally":
			_build_sally(door, p)
		_:
			# Interior door: frame posts + lockable blocker (treasury wing locked).
			var locked: bool = door["id"] in ["crypt_treasury", "chapel_treasury", "treasury_throne"]
			_door_frame(p, door["w"])
			interactables[door["id"]] = {"pos": p, "kind": "door", "locked": locked, "door": door}
			if locked:
				interactables[door["id"]]["body"] = _make_blocker(p, door["w"])

func _door_frame(p: Vector3, w: float) -> void:
	for off in [-w / 2.0 - 0.25, w / 2.0 + 0.25]:
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.5, 4.0, 0.7)
		mi.mesh = mesh
		mi.material_override = _mat_dark
		mi.position = Vector3(p.x + off, 2.0, p.z)
		add_child(mi)

func _make_blocker(p: Vector3, w: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	# Owner's locks stop raiders only; the Sovereign and his horde pass freely.
	body.collision_layer = Combat.MASK_LOCKS
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(w, 3.0, 0.6)
	cs.shape = sh
	body.position = Vector3(p.x, 1.5, p.z)
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = sh.size
	mi.mesh = mesh
	mi.material_override = _mat_dark
	body.add_child(mi)
	add_child(body)
	return body

func _build_portcullis(door: Dictionary, p: Vector3) -> void:
	var body := AnimatableBody3D.new()
	body.collision_layer = 1
	body.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(door["w"], 3.0, 0.4)
	cs.shape = sh
	body.add_child(cs)
	# Bars visual (recolors to iron-blue when the Reinforced Gate is bought).
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.16, 0.14, 0.12)
	for i in range(int(door["w"]) * 2):
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.16, 3.0, 0.16)
		bar.mesh = bm
		bar.material_override = bar_mat
		bar.position = Vector3(-door["w"] / 2.0 + 0.35 + i * 0.42, 0, 0)
		body.add_child(bar)
	body.position = Vector3(p.x, 1.5, p.z)
	add_child(body)
	interactables["gate_portcullis"] = {
		"pos": p, "kind": "portcullis", "body": body,
		"raised_y": 4.2, "lowered_y": 1.5, "target_y": 4.2,
		"crew_task": null, "door": door, "bar_mat": bar_mat,
	}

func apply_gate_reinforcement() -> void:
	var gate = interactables["gate_portcullis"]
	var mat: StandardMaterial3D = gate["bar_mat"]
	mat.albedo_color = Color(0.25, 0.35, 0.5)
	mat.metallic = 0.85

func _build_sally(door: Dictionary, p: Vector3) -> void:
	var rubble := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(2.8, 1.6, 1.4)
	rubble.mesh = rm
	rubble.material_override = _mat_dark
	rubble.position = Vector3(p.x, 0.8, p.z)
	add_child(rubble)
	var seal_body := StaticBody3D.new()
	seal_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(2.8, 3.0, 1.6)
	cs.shape = sh
	cs.disabled = true   # sealing flips this on
	seal_body.add_child(cs)
	seal_body.position = Vector3(p.x, 1.5, p.z)
	add_child(seal_body)
	interactables["sally_port"] = {"pos": p, "kind": "sally", "sealed": false,
		"visual": rubble, "seal_shape": cs, "door": door}

# ------------------------------------------------------------------ traps ----
func _build_traps() -> void:
	for id in Defs.TRAP_SOCKETS.keys():
		var t: Dictionary = Defs.TRAP_SOCKETS[id]
		var area := Area3D.new()
		area.collision_layer = 16
		area.collision_mask = 8   # heroes
		area.monitoring = true
		var cs := CollisionShape3D.new()
		var sh := CylinderShape3D.new()
		sh.radius = t["radius"]
		sh.height = 1.2
		cs.shape = sh
		area.position = Vector3(t["pos"][0], 0.6, t["pos"][1])
		area.add_child(cs)
		# spikes visual (hidden until armed)
		var vis := MeshInstance3D.new()
		var vm := BoxMesh.new()
		vm.size = Vector3(t["radius"] * 1.6, 0.12, t["radius"] * 1.6)
		vis.mesh = vm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.6, 0.15, 0.1)
		vis.material_override = m
		vis.visible = false
		area.add_child(vis)
		area.set_meta("trap_id", id)
		add_child(area)
		interactables[id] = {"pos": Vector3(t["pos"][0], 0, t["pos"][1]), "kind": "trap",
			"socket_id": id, "area": area, "radius": t["radius"], "dmg": t["dmg"], "visual": vis}

func set_trap_armed(id: String, armed: bool) -> void:
	if interactables.has(id):
		interactables[id]["visual"].visible = armed

# After an expedition resolves: relock vault doors, restore the objective.
# Traps stay disarmed — re-arming them is a player preparation choice.
func reset_defenses() -> void:
	for door_id in ["crypt_treasury", "chapel_treasury", "treasury_throne"]:
		var it = interactables[door_id]
		it["locked"] = true
		it["being_worked"] = false
		if not is_instance_valid(it.get("body", null)):
			it["body"] = _make_blocker(it["pos"], it["door"]["w"])
	var relic = interactables["relic"]
	relic["taken"] = false
	relic["carrier"] = null
	relic["visual"].visible = true
	relic["visual"].position = Defs.OBJECTIVE_POS

# -------------------------------------------------------------- objective ----
func _build_objective() -> void:
	var ped := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.5
	pm.bottom_radius = 0.7
	pm.height = 1.2
	ped.mesh = pm
	ped.material_override = _mat_dark
	ped.position = Defs.OBJECTIVE_POS + Vector3(0, -0.4, 0)
	add_child(ped)
	var gem := MeshInstance3D.new()
	var gm := SphereMesh.new()
	gm.radius = 0.35
	gm.height = 0.7
	gem.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.5, 0.85, 1.0)
	gmat.emission_enabled = true
	gmat.emission = Color(0.3, 0.6, 0.9)
	gem.material_override = gmat
	gem.position = Defs.OBJECTIVE_POS
	add_child(gem)
	interactables["relic"] = {"pos": Defs.OBJECTIVE_POS, "kind": "objective", "taken": false, "carrier": null, "visual": gem}


# ------------------------------------------------------- lair identity -------
# v0.2: the fortress becomes a PLACE — throne dais, War Table, treasury gold
# that visibly grows, a Soul Bell that physically appears in the crypt.
var gold_piles: Array = []
var soul_bell_visual: Node3D = null
var gate_controls_visual: Node3D = null
var prison_root: Node3D = null
var room_lights := {}
var alarm_beacons: Array = []
var compromised_rooms: Array = []
var invasion_alarm_level := 0
var prison_label: Label3D = null
var prisoner_visual: MeshInstance3D = null

func build_lair_identity() -> void:
	# Throne dais + chair in the heart of the hall.
	var dais := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = 3.4; dm.bottom_radius = 4.0; dm.height = 0.5
	dais.mesh = dm
	dais.material_override = _mat_dark
	dais.position = Defs.SOVEREIGN_SPAWN + Vector3(0, 0.24, 0)
	add_child(dais)
	var throne := MeshInstance3D.new()
	var tm := BoxMesh.new(); tm.size = Vector3(1.6, 2.6, 0.9)
	throne.mesh = tm
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.14, 0.08, 0.12)
	tmat.emission_enabled = true
	tmat.emission = Color(0.35, 0.06, 0.1); tmat.emission_energy_multiplier = 0.5
	throne.material_override = tmat
	throne.position = Defs.SOVEREIGN_SPAWN + Vector3(0, 1.8, 1.6)
	throne.rotation_degrees = Vector3(0, 180, 0)
	add_child(throne)

	# WAR TABLE — diegetic anchor for the strategic map.
	var table := MeshInstance3D.new()
	var tbm := BoxMesh.new(); tbm.size = Vector3(3.4, 0.25, 2.2)
	table.mesh = tbm
	var tbmat := StandardMaterial3D.new()
	tbmat.albedo_color = Color(0.24, 0.16, 0.1)
	table.material_override = tbmat
	table.position = Defs.SOVEREIGN_SPAWN + Vector3(4.5, 1.0, 2.0)
	add_child(table)
	for leg_off in [Vector3(-1.4, 0, -0.8), Vector3(1.4, 0, -0.8), Vector3(-1.4, 0, 0.8), Vector3(1.4, 0, 0.8)]:
		var leg := MeshInstance3D.new()
		var lm := BoxMesh.new(); lm.size = Vector3(0.18, 1.0, 0.18)
		leg.mesh = lm
		leg.material_override = _mat_dark
		leg.position = table.position + leg_off + Vector3(0, -0.55, 0)
		add_child(leg)
	# A faint green glow marks the table as interactive.
	var tl := OmniLight3D.new()
	tl.omni_range = 3.2; tl.light_energy = 1.1
	tl.light_color = Color(0.4, 1.0, 0.55)
	tl.position = table.position + Vector3(0, 1.2, 0)
	add_child(tl)
	interactables["war_table"] = {"pos": table.position, "kind": "war_table"}

	# Treasury gold piles — scale tier by tier as GOLD accumulates.
	for i in range(3):
		var pile := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = 0.7 + 0.15 * i
		pm.height = 0.9
		pile.mesh = pm
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.85, 0.65, 0.15)
		pmat.metallic = 0.85
		pmat.roughness = 0.35
		pile.material_override = pmat
		pile.position = Defs.room_center("treasury") + Vector3(-6.0 + i * 2.2, 0.3, -3.0 + (i % 2) * 1.4)
		pile.visible = false
		add_child(pile)
		gold_piles.append(pile)

	# Soul Bell — hidden until purchased; then it HANGS in the crypt.
	soul_bell_visual = MeshInstance3D.new()
	var bell := CylinderMesh.new()
	bell.top_radius = 0.12; bell.bottom_radius = 0.55; bell.height = 1.0
	soul_bell_visual.mesh = bell
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.15, 0.2, 0.28)
	bmat.metallic = 0.9
	bmat.emission_enabled = true
	bmat.emission = Color(0.1, 0.25, 0.4)
	soul_bell_visual.material_override = bmat
	soul_bell_visual.position = Defs.room_center("crypt") + Vector3(0, 2.6, 0)
	soul_bell_visual.visible = false
	add_child(soul_bell_visual)
	interactables["soul_bell"] = {
		"pos": Defs.LAIR_SYSTEMS["soul_bell"]["pos"], "kind": "lair_system",
		"system_id": "soul_bell", "visual": soul_bell_visual,
	}

	# Gate controls — a physical mechanism Crown/Guild specialists can sabotage.
	gate_controls_visual = MeshInstance3D.new()
	var gcm := BoxMesh.new(); gcm.size = Vector3(0.7, 1.3, 0.45)
	gate_controls_visual.mesh = gcm
	var gmat2 := StandardMaterial3D.new()
	gmat2.albedo_color = Color(0.38, 0.28, 0.16)
	gmat2.metallic = 0.65
	gmat2.emission_enabled = true
	gmat2.emission = Color(0.35, 0.12, 0.04)
	gate_controls_visual.material_override = gmat2
	gate_controls_visual.position = Defs.LAIR_SYSTEMS["gate_controls"]["pos"]
	add_child(gate_controls_visual)
	interactables["gate_controls"] = {
		"pos": Defs.LAIR_SYSTEMS["gate_controls"]["pos"], "kind": "lair_system",
		"system_id": "gate_controls", "visual": gate_controls_visual,
	}

	# Iron Prison — a deliberately small persistence proof inside the existing
	# chapel wing. No new construction system is introduced.
	prison_root = Node3D.new()
	prison_root.position = Defs.LAIR_SYSTEMS["prison"]["pos"]
	add_child(prison_root)
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.18, 0.2, 0.22)
	iron.metallic = 0.9
	for x in [-1.4, -0.7, 0.0, 0.7, 1.4]:
		var bar := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(0.12, 2.6, 0.12)
		bar.mesh = bmesh; bar.material_override = iron
		bar.position = Vector3(x, 1.3, 0)
		prison_root.add_child(bar)
	var top := MeshInstance3D.new()
	var topm := BoxMesh.new(); topm.size = Vector3(3.0, 0.16, 0.3)
	top.mesh = topm; top.material_override = iron
	top.position = Vector3(0, 2.6, 0)
	prison_root.add_child(top)
	prison_label = Label3D.new()
	prison_label.text = "IRON PRISON — EMPTY"
	prison_label.font_size = 34
	prison_label.pixel_size = 0.005
	prison_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	prison_label.position = Vector3(0, 3.25, 0)
	prison_root.add_child(prison_label)
	prisoner_visual = MeshInstance3D.new()
	var prisoner_mesh := CapsuleMesh.new()
	prisoner_mesh.radius = 0.34
	prisoner_mesh.height = 1.5
	prisoner_visual.mesh = prisoner_mesh
	var prisoner_mat := StandardMaterial3D.new()
	prisoner_mat.albedo_color = Color(0.72, 0.67, 0.46)
	prisoner_visual.material_override = prisoner_mat
	prisoner_visual.position = Vector3(0, 0.78, -0.35)
	prisoner_visual.visible = false
	prison_root.add_child(prisoner_visual)
	interactables["prison"] = {
		"pos": Defs.LAIR_SYSTEMS["prison"]["pos"], "kind": "prison",
		"system_id": "prison", "visual": prison_root,
	}

	# Muster banner near the horde spawn so the warband reads as a PLACE.
	var banner := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(1.6, 2.6, 0.08)
	banner.mesh = bm
	var bmt := StandardMaterial3D.new()
	bmt.albedo_color = Color(0.45, 0.08, 0.1)
	banner.material_override = bmt
	banner.position = Defs.HORDE_SPAWN + Vector3(2.5, 2.2, 0)
	add_child(banner)


## Physical progression mirrors (§19): call whenever economy/domain changes.
func refresh_domain_visuals(gold: int, upgrades: Dictionary) -> void:
	var tiers := [30, 60, 100]
	for i in range(gold_piles.size()):
		gold_piles[i].visible = gold >= int(tiers[i])
	if soul_bell_visual != null:
		soul_bell_visual.visible = upgrades.has("soul_bell") 			and not Safe.gs().domain.is_raid_system_disabled("soul_bell")

func refresh_prison_visual() -> void:
	if prison_label == null:
		return
	var captive: Dictionary = Safe.gs().world.first_captive()
	if captive.is_empty():
		prison_label.text = "IRON PRISON — EMPTY"
		if prisoner_visual != null:
			prisoner_visual.visible = false
	else:
		prison_label.text = "PRISONER — %s" % str(captive.get("name", "UNKNOWN"))
		if prisoner_visual != null:
			prisoner_visual.visible = true
	Safe.tel().ev("prison_visual", {"captives": Safe.gs().world.captives.size()})

func set_lair_system_disabled(id: String, disabled: bool) -> void:
	var it = interactables.get(id, null)
	if it == null:
		return
	var vis: Node3D = it.get("visual", null)
	if vis == null or not is_instance_valid(vis):
		return
	if id == "soul_bell":
		vis.visible = Safe.gs().domain.upgrades.has("soul_bell") and not disabled
	else:
		vis.scale = Vector3.ONE * (0.55 if disabled else 1.0)
	Safe.tel().ev("lair_system_visual", {"id": id, "disabled": disabled})

func reset_lair_system_visuals() -> void:
	set_lair_system_disabled("soul_bell", false)
	set_lair_system_disabled("gate_controls", false)

# ---------------------------------------------------------------- lights -----
func _build_lights() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_energy = 0.7
	sun.light_color = Color(0.9, 0.75, 0.6)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.04, 0.06)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.35, 0.32, 0.38)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	for room_id in Defs.ROOMS.keys():
		if room_id == "courtyard":
			continue
		var lamp := OmniLight3D.new()
		lamp.position = Defs.room_center(room_id) + Vector3(0, 3.4, 0)
		lamp.omni_range = maxf(Defs.room_rect(room_id).size.x, Defs.room_rect(room_id).size.y) * 0.9
		lamp.light_energy = 0.9
		lamp.light_color = _base_room_light_color(room_id)
		add_child(lamp)
		room_lights[room_id] = lamp
	for x in [-4.0, 4.0]:
		var beacon := OmniLight3D.new()
		beacon.position = Vector3(x, 3.2, 28.0)
		beacon.omni_range = 11.0
		beacon.light_color = Color(1.0, 0.08, 0.03)
		beacon.light_energy = 0.0
		beacon.visible = false
		add_child(beacon)
		alarm_beacons.append(beacon)


static func alarm_energy(level: int) -> float:
	if level >= 2:
		return 4.2
	if level == 1:
		return 2.2
	return 0.0

func _base_room_light_color(room_id: String) -> Color:
	return Color(0.4, 0.5, 0.8) if room_id == "crypt" else Color(1.0, 0.75, 0.45)

func set_invasion_alarm(level: int) -> void:
	level = clampi(level, 0, 2)
	if invasion_alarm_level == level:
		return
	invasion_alarm_level = level
	for b in alarm_beacons:
		var beacon := b as OmniLight3D
		beacon.visible = level > 0
		beacon.light_energy = alarm_energy(level)
	if room_lights.has("gatehouse") and not compromised_rooms.has("gatehouse"):
		var gate_light := room_lights["gatehouse"] as OmniLight3D
		if level >= 2:
			gate_light.light_color = Color(1.0, 0.18, 0.08)
			gate_light.light_energy = 1.4
		else:
			gate_light.light_color = _base_room_light_color("gatehouse")
			gate_light.light_energy = 0.9

func mark_room_compromised(room_id: String) -> void:
	if not Defs.ROOMS.has(room_id):
		return
	if not compromised_rooms.has(room_id):
		compromised_rooms.append(room_id)
	if room_lights.has(room_id):
		var lamp := room_lights[room_id] as OmniLight3D
		lamp.light_color = Color(0.95, 0.12, 0.055)
		lamp.light_energy = 1.55

func reset_raid_progress_visuals() -> void:
	compromised_rooms.clear()
	for room_id in room_lights:
		var lamp := room_lights[room_id] as OmniLight3D
		lamp.light_color = _base_room_light_color(str(room_id))
		lamp.light_energy = 0.9
	invasion_alarm_level = -1
	set_invasion_alarm(0)
