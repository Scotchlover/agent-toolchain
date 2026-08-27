# ExpeditionJourney — strategic travel for a hostile expedition.
# A completed enemy project no longer teleports actors to the fortress: it
# creates a persistent journey over the authored region graph first.
extends RefCounted
class_name ExpeditionJourney

const LEG_DURATION := 11.0
const DOMAIN_APPROACH_DURATION := 9.0

static func faction_origin(faction: String) -> String:
	match faction:
		"church": return "holy_see"
		"crown": return "barony"
		"guild": return "guild"
		_: return "village"

static func route_for_faction(faction: String) -> Array:
	return route_between(faction_origin(faction), "dark_domain")

static func route_between(start: String, goal: String) -> Array:
	if start == goal:
		return [start]
	var adj := _adjacency()
	if not adj.has(start) or not adj.has(goal):
		return [start, goal]
	var queue: Array = [start]
	var prev := {start: ""}
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		if cur == goal:
			break
		for nxt in adj.get(cur, []):
			if not prev.has(nxt):
				prev[nxt] = cur
				queue.append(nxt)
	if not prev.has(goal):
		return [start, goal]
	var out: Array = []
	var at := goal
	while at != "":
		out.push_front(at)
		at = str(prev.get(at, ""))
	return out

static func _adjacency() -> Dictionary:
	var adj := {}
	for id in Defs.REGIONS:
		adj[id] = []
	for id in Defs.REGIONS:
		for linked in Defs.REGIONS[id].get("links", []):
			if not adj[id].has(linked):
				adj[id].append(linked)
			if adj.has(linked) and not adj[linked].has(id):
				adj[linked].append(id)
	return adj

static func eta_seconds(state: Dictionary) -> float:
	if str(state.get("stage", "")) == "approach":
		return maxf(0.0, float(state.get("approach_left", 0.0)))
	var route: Array = state.get("route", [])
	var idx := int(state.get("leg_index", 0))
	var leg_left := maxf(0.0, float(state.get("leg_duration", LEG_DURATION)) - float(state.get("leg_progress", 0.0)))
	var remaining_legs := maxi(0, route.size() - idx - 2)
	return leg_left + remaining_legs * float(state.get("leg_duration", LEG_DURATION)) + DOMAIN_APPROACH_DURATION

static func map_fraction(state: Dictionary) -> float:
	var route: Array = state.get("route", [])
	if route.size() <= 1:
		return 1.0
	if str(state.get("stage", "")) == "approach":
		return 1.0
	var idx := clampi(int(state.get("leg_index", 0)), 0, route.size() - 2)
	var dur := maxf(0.001, float(state.get("leg_duration", LEG_DURATION)))
	var leg_t := clampf(float(state.get("leg_progress", 0.0)) / dur, 0.0, 1.0)
	return (float(idx) + leg_t) / float(route.size() - 1)
