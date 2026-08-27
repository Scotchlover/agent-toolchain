# Semantic room graph of the fortress. Pure data + BFS pathfinding.
# Doors expose semantic kind; passability is injected via a callable so this
# class stays scene-independent (headless-testable).
extends RefCounted
class_name RoomGraph

# doors: Array of Defs.DOORS-shaped dicts.
static func build(doors: Array) -> Dictionary:
	var g := {"adj": {}, "doors": {}}
	for room_id in Defs.ROOMS.keys():
		g["adj"][room_id] = []
	for d in doors:
		for endpoint in [d["a"], d["b"]]:
			if not g["adj"].has(endpoint):
				g["adj"][endpoint] = []   # pseudo-rooms like __outside__
		g["doors"][d["id"]] = d
		g["adj"][d["a"]].append(d["id"])
		g["adj"][d["b"]].append(d["id"])
	return g

# Returns array of door dicts forming a path from_room -> to_room (BFS).
# passable: Callable(door:Dictionary) -> bool. Empty array if none/unreachable.
static func path(g: Dictionary, from_room: String, to_room: String, passable: Callable) -> Array:
	if from_room == to_room:
		return []
	var prev := {from_room: ""}
	var queue: Array = [from_room]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for door_id in g["adj"][cur]:
			var door: Dictionary = g["doors"][door_id]
			if not passable.call(door):
				continue
			var nxt: String = door["b"] if door["a"] == cur else door["a"]
			if prev.has(nxt):
				continue
			prev[nxt] = door_id
			if nxt == to_room:
				var route: Array = []
				var walk: String = to_room
				while walk != from_room:
					route.push_front(g["doors"][prev[walk]])
					walk = (g["doors"][prev[walk]]["a"] if g["doors"][prev[walk]]["a"] != walk else g["doors"][prev[walk]]["b"])
				return route
			queue.append(nxt)
	return []

# Which room of the edge is on the other side.
static func other_side(door: Dictionary, room: String) -> String:
	return door["b"] if door["a"] == room else door["a"]

static func room_of_pos(pos: Vector3) -> String:
	for room_id in Defs.ROOMS.keys():
		var r := Defs.room_rect(room_id)
		if r.has_point(Vector2(pos.x, pos.z)):
			return room_id
	return "__outside__"

# Immediate steering target for cheap agents: the next doorway between here
# and the destination, or the destination itself once in the same room.
# Cheap mass units call this every tick; the graph is tiny so BFS is trivial.
static func next_waypoint(g: Dictionary, from_pos: Vector3, dest: Vector3) -> Vector3:
	var from_room := room_of_pos(from_pos)
	var to_room := room_of_pos(dest)
	if from_room == to_room:
		return dest
	var route := path(g, from_room, to_room, _default_passable)
	if route.is_empty():
		return dest   # no legal route: press on anyway (breach/crowding emerges)
	return Defs.door_pos(route[0])

static func _default_passable(_door: Dictionary) -> bool:
	return true
