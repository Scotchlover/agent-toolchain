# WorldResponseSystem — turns strategic state into hostile projects.
# Preferred shape: WorldState → eligible rules → start/advance projects →
# expedition recipes. Deliberately NOT a magic Director.
extends RefCounted
class_name WorldResponseSystem

# Evaluate one-shot causal rules; starts projects on WorldState.
# Returns log lines describing what the world just decided to do.
static func evaluate(world: WorldState) -> Array:
	var out: Array = []

	# Generic authored provocations: each NEW raid can earn one corresponding
	# hostile cycle. Existing journeys keep the cycle locked until resolved.
	for region_id in Defs.REGIONS:
		var region: Dictionary = Defs.REGIONS[region_id]
		var raid: Dictionary = region.get("raid", {})
		var def_id := str(raid.get("provokes", ""))
		if def_id == "":
			continue
		var provocations := int(world.raid_counts.get(region_id, 0))
		var sent := int(world.project_counts.get(def_id, 0))
		if provocations > sent and not world.has_hostile_cycle(def_id):
			if not world.start_project(def_id).is_empty():
				out.append("%s project started: %s" % [
					str(Defs.ENEMY_PROJECTS[def_id]["faction"]).capitalize(),
					str(Defs.ENEMY_PROJECTS[def_id]["label"]).to_upper(),
				])
				_announce(world, def_id)

	# Capturing a named Church champion creates one rescue attempt for each
	# capture event. This is a tactical outcome generating strategic content.
	var captive := world.first_captive("church")
	if not captive.is_empty():
		var captures := int(captive.get("captures", 0))
		var rescues := int(world.project_counts.get("RESCUE_MARTYR", 0))
		var old_enough := world.time - float(captive.get("captured_at", world.time)) >= 8.0
		if captures > rescues and old_enough and not world.has_hostile_cycle("RESCUE_MARTYR"):
			if not world.start_project("RESCUE_MARTYR").is_empty():
				out.append("Church project started: RESCUE THE MARTYR")
				_announce(world, "RESCUE_MARTYR")

	# Guild contracts are dynamic rather than tied 1:1 to a raid. Keep a
	# strategic cooldown so a high-threat state cannot spam overlapping teams.
	var last_guild := float(world.project_last_started.get("GUILD_CONTRACT", -9999.0))
	if world.threat >= 40 and not world.has_hostile_cycle("GUILD_CONTRACT") 			and not world.active_projects.is_empty() and world.time - last_guild >= 120.0 			and world.rng.randf() < 0.005:
		if not world.start_project("GUILD_CONTRACT").is_empty():
			out.append("Guild project started: GUILD CONTRACT")
			_announce(world, "GUILD_CONTRACT")

	return out


## §24: the player must think "they come because of what I did".
## Big banner + telemetry with the CAUSE attached.
static func _announce(world: WorldState, def_id: String) -> void:
	var def: Dictionary = Defs.ENEMY_PROJECTS[def_id]
	var gs = Safe.gs()
	if gs != null:
		gs.banner.emit(
			"THE %s HAS TAKEN NOTICE" % str(def["faction"]).to_upper(),
			"%s PREPARING — %s" % [str(def["label"]).to_upper(), def["cause"]])
	var tel = Safe.tel()
	if tel != null:
		tel.ev("project_started", {"def_id": def_id, "cause": str(def["cause"])})

# Consume completed project def_ids → expedition recipes.
static func consume_completed(world: WorldState, domain: DomainState, done_def_ids: Array) -> Array:
	var recipes: Array = []
	for def_id in done_def_ids:
		recipes.append(Expedition.make_recipe(world, domain, def_id))
	return recipes
