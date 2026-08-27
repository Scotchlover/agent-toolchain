# Expedition recipe builder: Definition → Runtime plan for a hero raid.
# Adapts composition quality to faction state and route to enemy knowledge —
# the transparent "world learns" proof of the slice.
extends RefCounted
class_name Expedition

# Build a runtime recipe dict consumed by PartyController spawner.
static func make_recipe(world: WorldState, domain: DomainState, def_id: String) -> Dictionary:
	var def: Dictionary = Defs.ENEMY_PROJECTS[def_id]
	var fac: String = def["faction"]
	var quality: float = float(world.factions[fac].get("quality", 1.0))
	quality *= 1.0 + float(world.factions[fac]["hostility"]) / 200.0   # angrier → stronger
	quality = clampf(quality, 0.5, 2.0)

	var roles: Array = []
	for r in def["party"]["roles"]:
		roles.append({"role": r, "quality": quality})

	# At most one persistent named hero is embedded in a party for the slice.
	# Identity rides the same role snapshot used by interception and fortress.
	var named := world.available_named_hero(fac)
	if not named.is_empty():
		for rr in roles:
			if str(rr["role"]) == str(named["role"]):
				rr["hero_id"] = str(named["id"])
				rr["name"] = str(named["name"])
				rr["traits"] = named.get("traits", []).duplicate(true)
				break

	var objectives: Array = def.get("objectives", [def.get("objective", "steal_relic")]).duplicate(true)
	var rescue_target := ""
	if objectives.has("free_prisoner"):
		var captive := world.first_captive(fac)
		if not captive.is_empty():
			rescue_target = str(captive["id"])

	var route := pick_route(world, domain)
	return {
		"def_id": def_id,
		"label": def["label"],
		"objective": def.get("objective", "steal_relic"),
		"objectives": objectives,
		"doctrine": def.get("doctrine", "balanced"),
		"rescue_target": rescue_target,
		"roles": roles,
		"entry_door": route["door"],
		"route_rooms": route["rooms"],
		"knowledge": world.knowledge.duplicate(true),
	}

# Route selection honors knowledge facts recorded from escaped scouts.
# Raid 1: no info → main gate. If a scout escaped having used the sally port,
# later parties enter through it — unless the player sealed it (counter-play).
static func pick_route(world: WorldState, domain: DomainState) -> Dictionary:
	var know: Dictionary = world.knowledge
	if know.get("route", "") == "sally_port" and not domain.sally_sealed:
		return {"door": "sally_port", "rooms": ["crypt", "treasury"]}
	return {"door": "gate_portcullis", "rooms": ["gatehouse", "great_hall", "treasury"]}

# Called when an expedition resolves: record what survivors learned.
static func record_knowledge(world: WorldState, escaped_roles: Array, saw_trap_socket: String, used_sally: bool) -> void:
	for role in escaped_roles:
		if role == "rogue":
			if saw_trap_socket != "":
				var seen: Array = world.knowledge.get("trap_seen", [])
				if not seen.has(saw_trap_socket):
					seen.append(saw_trap_socket)
				world.knowledge["trap_seen"] = seen
			if used_sally:
				world.knowledge["route"] = "sally_port"
