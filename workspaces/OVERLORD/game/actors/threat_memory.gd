# ThreatMemory — tiny aggro scoring for enemies (NOT utility AI).
# Sources that recently HURT this enemy — or are the Sovereign looming
# nearby — accumulate heat; targeting picks the hottest candidate so the
# Dark Lord personally pulling into a pack actually pulls aggro.
class_name ThreatMemory

const DECAY := 1.6          # heat per second
const SOVEREIGN_LOOM := 3.0 # passive heat/s while he is within loom radius

var heat: Dictionary = {}   # instance_id -> {node, value}

func add(node: Node, amount: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var id := node.get_instance_id()
	var e = heat.get(id)
	if e == null:
		heat[id] = {"node": node, "v": amount}
	else:
		e["v"] = minf(float(e["v"]) + amount, 60.0)

func tick(dt: float, loom_target: Node = null) -> void:
	for id in heat.keys():
		var e = heat[id]
		e["v"] = maxf(0.0, float(e["v"]) - DECAY * dt)
	# purge dead/expired
	var dead_ids: Array = []
	for id in heat.keys():
		var e = heat[id]
		if not is_instance_valid(e["node"]):
			dead_ids.append(id)
			continue
		if e["node"] == loom_target and is_instance_valid(loom_target):
			e["v"] = minf(float(e["v"]) + 2.2 * dt, 40.0)
		elif float(e["v"]) <= 0.01:
			dead_ids.append(id)
	for id in dead_ids:
		heat.erase(id)

## Pick from candidates: hottest remembered threat beats raw proximity.
func pick(candidates: Array, self_pos: Vector3) -> Node:
	var best: Node = null
	var best_score := -INF
	for c in candidates:
		if not is_instance_valid(c):
			continue
		if "dead" in c and c.dead:
			continue
		if c.has_method("is_down") and c.is_down():
			continue
		var h := 0.0
		var e = heat.get(c.get_instance_id())
		if e != null:
			h = float(e["v"])
		var d: float = (c as Node3D).global_position.distance_to(self_pos)
		var score: float = h * 2.0 - d * 0.8 + 10.0
		if score > best_score:
			best_score = score
			best = c
	return best
