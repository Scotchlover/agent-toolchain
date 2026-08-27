# Ring-buffer event log: debug + QA + future After Action Report.
extends RefCounted
class_name EventLog

var entries: Array = []   # [{t: float, msg: String}]
var _t := 0.0
const MAX_ENTRIES := 400

func tick(dt: float) -> void:
	_t += dt

func stamp() -> String:
	var m := int(_t) / 60
	var s := fmod(_t, 60.0)
	return "%02d:%04.1f" % [m, s]

func add(msg: String) -> void:
	entries.append({"t": _t, "msg": msg})
	if entries.size() > MAX_ENTRIES:
		entries.pop_front()

func lines(n: int = 8) -> Array:
	var out: Array = []
	var start: int = maxi(0, entries.size() - n)
	for i in range(start, entries.size()):
		var e: Dictionary = entries[i]
		var m := int(e["t"]) / 60
		var s := fmod(float(e["t"]), 60.0)
		out.append("%02d:%04.1f %s" % [m, s, e["msg"]])
	return out

func to_dict() -> Dictionary:
	return {"t": _t, "entries": entries.duplicate(true)}

func from_dict(d: Dictionary) -> void:
	_t = float(d.get("t", 0.0))
	entries = d.get("entries", []).duplicate(true)
