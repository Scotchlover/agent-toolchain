# DomainState — mutable systemic state of the fortress (data, not scene).
# The 3D fortress scene mirrors this; it never owns campaign truth.
extends RefCounted
class_name DomainState

var portcullis_open := true       # raised by minion crew via INTERACT
var traps_armed := {"great_hall_spikes": false}
var sally_sealed := false         # one-time seal of the crypt sally port
var upgrades := {}                # reserved for slice+ upgrades
# Tactical damage done by an active raid. These are deliberately transient:
# the next raid starts with repaired systems unless later progression makes
# repairs a strategic economy.
var raid_disabled_systems := {}

func toggle_trap(id: String) -> void:
	traps_armed[id] = not bool(traps_armed.get(id, false))

func seal_sally() -> void:
	sally_sealed = true

func upgrade_count() -> int:
	return upgrades.size()

func suppress_raid_system(id: String) -> void:
	raid_disabled_systems[id] = true

func is_raid_system_disabled(id: String) -> bool:
	return bool(raid_disabled_systems.get(id, false))

func reset_raid_systems() -> void:
	raid_disabled_systems.clear()

func to_dict() -> Dictionary:
	return {
		"portcullis_open": portcullis_open,
		"traps_armed": traps_armed.duplicate(true),
		"sally_sealed": sally_sealed,
		"upgrades": upgrades.duplicate(true),
	}

func from_dict(d: Dictionary) -> void:
	portcullis_open = bool(d.get("portcullis_open", true))
	traps_armed = d.get("traps_armed", {"great_hall_spikes": false}).duplicate(true)
	sally_sealed = bool(d.get("sally_sealed", false))
	upgrades = d.get("upgrades", {}).duplicate(true)
	raid_disabled_systems.clear()
