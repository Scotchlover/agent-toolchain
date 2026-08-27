# OVERLORD — canonical static definitions (immutable data).
# Pattern: DEFINITION ≠ RUNTIME STATE. These are Def tables; mutable state lives
# in WorldState / DomainState / actor runtime objects.
extends RefCounted
class_name Defs

# ---------------------------------------------------------------- fortress ---
# Rooms are axis-aligned rects on XZ plane: [cx, cz, half_w, half_d].
# Adjacent rooms SHARE boundary edges; doors sit exactly on those lines.
# z grows SOUTH (heroes approach from south). y up.
const ROOMS := {
	"courtyard":  {"rect": [0, 42, 11, 12],    "tags": ["exterior"]},
	"gatehouse":  {"rect": [0, 23.5, 7, 6.5],  "tags": ["entry", "chokepoint"]},
	"great_hall": {"rect": [0, 8.5, 9, 8.5],   "tags": ["central", "trappable"]},
	"crypt":      {"rect": [-16, 5.5, 7, 8.5], "tags": ["side_wing", "dark"]},
	"chapel":     {"rect": [16, 5.5, 7, 8.5],  "tags": ["side_wing", "desecrated"]},
	"treasury":   {"rect": [0, -10, 19, 7],    "tags": ["objective", "vault"]},
	"throne":     {"rect": [0, -24, 9, 7],     "tags": ["heart", "spawn"]},
}

# Edges: doors between rooms. pos = doorway world position (x,z) ON the shared
# wall line. kind: "door" | "portcullis" | "sally". w = opening width.
const DOORS := [
	{"id": "gate_portcullis", "a": "courtyard",  "b": "gatehouse",  "pos": [0, 30],    "kind": "portcullis", "w": 5},
	{"id": "gate_inner",      "a": "gatehouse",  "b": "great_hall", "pos": [0, 17],    "kind": "door",       "w": 3},
	{"id": "hall_crypt",      "a": "great_hall", "b": "crypt",      "pos": [-9, 6],    "kind": "door",       "w": 3},
	{"id": "hall_chapel",     "a": "great_hall", "b": "chapel",     "pos": [9, 6],     "kind": "door",       "w": 3},
	{"id": "crypt_treasury",  "a": "crypt",      "b": "treasury",   "pos": [-14, -3],  "kind": "door",       "w": 3},
	{"id": "chapel_treasury", "a": "chapel",     "b": "treasury",   "pos": [14, -3],   "kind": "door",       "w": 3},
	{"id": "treasury_throne", "a": "treasury",   "b": "throne",     "pos": [0, -17],   "kind": "door",       "w": 3},
	# Hidden sally port: exterior -> crypt. Used by parties whose scout learned it.
	{"id": "sally_port",      "a": "__outside__","b": "crypt",      "pos": [-23, 10],  "kind": "sally",      "w": 2.5},
]

# Defensive sockets (authored space + systemic state; NOT minecraft).
const TRAP_SOCKETS := {
	"great_hall_spikes": {"room": "great_hall", "pos": [0, 8.5], "radius": 2.6, "dmg": 35.0},
}

const PORTCULLIS_ID := "gate_portcullis"
const OBJECTIVE_ROOM := "treasury"
const OBJECTIVE_POS := Vector3(0, 1.0, -10)
const SOVEREIGN_SPAWN := Vector3(0, 0.5, -24)
const HORDE_SPAWN := Vector3(-3, 0.5, -22)

# Reverse-raid infrastructure. Heroes can attack these systems instead of
# treating the fortress as one long HP corridor.
const LAIR_SYSTEMS := {
	"soul_bell": {"label": "Soul Bell", "room": "crypt", "pos": Vector3(-16, 1.0, 5.5)},
	"gate_controls": {"label": "Gate Controls", "room": "gatehouse", "pos": Vector3(3.8, 0.8, 23.5)},
	"prison": {"label": "Iron Prison", "room": "chapel", "pos": Vector3(16, 0.9, 5.5)},
}

# Small persistent hero roster. This is intentionally NOT a Nemesis system.
# Traits must come from events, not random generation.
const NAMED_HEROES := {
	"sir_aldric": {
		"name": "Sir Aldric Vane",
		"role": "paladin",
		"faction": "church",
		"traits": [],
	},
}

static func room_rect(room_id: String) -> Rect2:
	var r: Array = ROOMS[room_id]["rect"]
	return Rect2(r[0] - r[2], r[1] - r[3], r[2] * 2.0, r[3] * 2.0)

static func room_center(room_id: String) -> Vector3:
	var r: Array = ROOMS[room_id]["rect"]
	return Vector3(r[0], 0, r[1])

static func door_pos(door: Dictionary) -> Vector3:
	return Vector3(door["pos"][0], 0, door["pos"][1])

# ------------------------------------------------------------------- world ---
# Strategic map: 7 nodes. Actions available depend on fear/threat gates.
# reward keys map to WorldState mutators. provocation feeds WorldResponseSystem.
const REGIONS := {
	"dark_domain": {"label": "Dark Domain",   "pos": [0.5, 0.85], "links": ["mines", "village"],                 "home": true},
	"mines":       {"label": "Mines",         "pos": [0.2, 0.62], "links": ["dark_domain"],                      "raid": {"gold": 30, "fear": 5,  "threat": 5}, "played": true},
	"village":     {"label": "Village",       "pos": [0.45, 0.55],"links": ["monastery", "barony"],              "raid": {"gold": 15, "fear": 10, "threat": 10}, "played": true},
	"monastery":   {"label": "Monastery",     "pos": [0.72, 0.42],"links": ["village", "holy_see"],              "raid": {"gold": 25, "fear": 15, "threat": 20, "provokes": "HOLY_EXPEDITION"}, "played": true},
	"barony":      {"label": "Barony",        "pos": [0.18, 0.32],"links": ["village"],                          "raid": {"gold": 45, "fear": 20, "threat": 25, "provokes": "CROWN_REPRISAL"}, "req_fear": 40},
	"guild":       {"label": "Adventurers' Guild", "pos": [0.82, 0.68], "links": ["holy_see"],                   "raid": {"gold": 30, "threat": 15, "guild_quality_hit": true}, "played": true},
	"holy_see":    {"label": "Holy See",      "pos": [0.85, 0.15],"links": ["monastery", "guild"],               "raid": {"gold": 60, "fear": 25, "threat": 40, "provokes": "GRAND_CONSECRATION"}, "req_threat": 80},
}

const FACTIONS := ["church", "crown", "guild"]

# ---------------------------------------------------------- enemy projects ---
# OpenXcom-style Rule/Runtime split: immutable Def here; live instances in WorldState.
const ENEMY_PROJECTS := {
	"HOLY_EXPEDITION": {
		"label": "Holy Expedition",
		"faction": "church", "duration": 60.0, "doctrine": "purge",
		"party": {"roles": ["paladin", "cleric", "rogue", "wizard"]},
		"objective": "consecrate_crypt",
		"objectives": ["consecrate_crypt", "steal_relic"],
		"cause": "The Monastery tithe was seized. The Church demands sanctification.",
	},
	"CROWN_REPRISAL": {
		"label": "Crown Reprisal",
		"faction": "crown", "duration": 80.0, "doctrine": "strike",
		"party": {"roles": ["paladin", "paladin", "cleric", "rogue", "wizard"]},
		"objective": "disable_gate",
		"objectives": ["disable_gate", "steal_relic"],
		"cause": "The Barony raises levies against the Sovereign's shadow.",
	},
	"GUILD_CONTRACT": {
		"label": "Guild Contract",
		"faction": "guild", "duration": 70.0, "doctrine": "retrieval",
		"party": {"roles": ["rogue", "rogue", "cleric", "wizard"]},
		"objective": "steal_relic",
		"objectives": ["steal_relic"],
		"cause": "A bounty on the Dark Sovereign's crown is posted at the Guild.",
	},
	"GRAND_CONSECRATION": {
		"label": "Grand Consecration",
		"faction": "church", "duration": 90.0, "doctrine": "purge",
		"party": {"roles": ["paladin", "cleric", "cleric", "rogue", "wizard", "wizard"]},
		"objective": "kill_sovereign",
		"objectives": ["consecrate_crypt", "kill_sovereign"],
		"cause": "The Holy See declares the Sovereign anathema.",
	},
	"RESCUE_MARTYR": {
		"label": "Rescue the Martyr",
		"faction": "church", "duration": 45.0, "doctrine": "rescue",
		"party": {"roles": ["paladin", "cleric", "rogue", "wizard"]},
		"objective": "free_prisoner",
		"objectives": ["free_prisoner"],
		"cause": "A sworn champion of the Church languishes in the Dark Sovereign's prison.",
	},
}

# -------------------------------------------------------------------- hero ---
const HERO_DEFS := {
	"paladin": {"label": "Paladin", "hp": 160.0, "speed": 4.2, "dmg": 16.0, "range": 1.9, "color": Color(0.85, 0.78, 0.45)},
	"cleric":  {"label": "Cleric",  "hp": 90.0,  "speed": 4.0, "dmg": 8.0,  "range": 1.6, "heal": 22.0, "heal_range": 6.0, "color": Color(0.95, 0.95, 0.98)},
	"rogue":   {"label": "Rogue",   "hp": 80.0,  "speed": 5.4, "dmg": 12.0, "range": 1.6, "color": Color(0.35, 0.5, 0.4)},
	"wizard":  {"label": "Wizard",  "hp": 70.0,  "speed": 3.8, "dmg": 14.0, "range": 9.0, "color": Color(0.45, 0.35, 0.75)},
}

# ------------------------------------------------------------------ minions ---
const MINION_TYPES := {
	"brute":     {"label": "Brute",     "hp": 60.0, "speed": 4.6, "dmg": 9.0, "range": 1.5, "color": Color(0.55, 0.28, 0.2)},
	"skitterer": {"label": "Skitterer", "hp": 34.0, "speed": 6.0, "dmg": 5.0, "range": 1.3, "color": Color(0.45, 0.45, 0.2)},
	"skeleton":  {"label": "Risen",     "hp": 26.0, "speed": 6.4, "dmg": 6.0, "range": 1.3, "color": Color(0.82, 0.82, 0.75)},
}

const COHORTS := [
	{"id": "bruisers",    "type": "brute",     "count": 8,
		"lieutenant": {"name": "Grashnak the Hammer", "hp_mult": 2.5, "dmg_mult": 1.6, "scale": 1.35}},
	{"id": "skitterers",  "type": "skitterer", "count": 6},
]

# ------------------------------------------------------- outdoor raids -------
# Played assaults (mandate §18.2): one builder, per-region authored sites.
# Open fields: straight steering suffices, so no room graph outdoors.
const SITES := {
	"village": {
		"origin": Vector3(0, 0, 320),
		"huts": [[-14, -8], [-15, 4], [14, -6], [13, 8], [-4, 16], [5, -14]],
		"hut_color": Color(0.32, 0.24, 0.16),
		"ground_color": Color(0.2, 0.22, 0.14),
		"fence_half": 24,
		"entry": Vector3(0, 0.6, 22),
		"objective_pos": Vector3(0, 0, 0),
		"defender_label": "Militia",
		"captain_label": "Militia Captain",
		"defender_hp": 45.0, "defender_dmg": 7.0, "defender_speed": 4.3,
		"defender_color": Color(0.6, 0.55, 0.4),
		"captain_hp": 150.0, "captain_dmg": 14.0, "captain_scale": 1.25,
		"spawns": [[0, 6], [-8, 2], [8, 2], [-4, 12], [4, 12], [-12, -2], [12, -2], [0, -4]],
		"captain_spawn": [0, -2],
	},
	"monastery": {
		"origin": Vector3(400, 0, 320),
		"huts": [[-16, 0], [-10, 12], [12, 10], [8, -12], [0, 18]],
		"hut_color": Color(0.5, 0.48, 0.42),
		"ground_color": Color(0.24, 0.23, 0.2),
		"fence_half": 26,
		"entry": Vector3(0, 0.6, 22),
		"objective_pos": Vector3(0, 0, -2),
		"defender_label": "Brother-at-Arms",
		"captain_label": "Prior Anselm",
		"defender_hp": 55.0, "defender_dmg": 9.0, "defender_speed": 4.1,
		"defender_color": Color(0.75, 0.72, 0.6),
		"captain_hp": 190.0, "captain_dmg": 16.0, "captain_scale": 1.3,
		"spawns": [[-6, 4], [6, 4], [-10, -4], [10, -4], [0, 10], [-14, 6], [14, 6], [4, -8], [-4, -8]],
		"captain_spawn": [0, -8],
	},
	"guild": {
		"origin": Vector3(800, 0, 320),
		"huts": [[-12, -4], [10, 6], [-6, 14], [16, -8]],
		"hut_color": Color(0.25, 0.28, 0.34),
		"ground_color": Color(0.17, 0.17, 0.19),
		"fence_half": 22,
		"entry": Vector3(0, 0.6, 20),
		"objective_pos": Vector3(0, 0, -4),
		"defender_label": "Guild Blade",
		"captain_label": "Guildmaster Vey",
		"defender_hp": 40.0, "defender_dmg": 11.0, "defender_speed": 5.2,
		"defender_color": Color(0.35, 0.45, 0.55),
		"captain_hp": 160.0, "captain_dmg": 15.0, "captain_scale": 1.2,
		"spawns": [[0, 4], [-7, 0], [7, 0], [-3, 10], [3, 10], [0, -6], [-9, -6], [9, -6]],
		"captain_spawn": [0, -10],
	},
	"mines": {
		"origin": Vector3(1200, 0, 320),
		"huts": [[-10, -2], [12, 4], [-4, 12], [6, 14], [16, -6], [-16, -10]],
		"hut_color": Color(0.3, 0.26, 0.2),
		"ground_color": Color(0.19, 0.17, 0.15),
		"fence_half": 24,
		"entry": Vector3(0, 0.6, 21),
		"objective_pos": Vector3(0, 0, -2),
		"defender_label": "Kobold Digger",
		"captain_label": "Overseer Skarn",
		"defender_hp": 30.0, "defender_dmg": 6.0, "defender_speed": 5.6,
		"defender_color": Color(0.5, 0.4, 0.25),
		"captain_hp": 170.0, "captain_dmg": 13.0, "captain_scale": 1.3,
		"spawns": [[-5, 2], [5, 2], [-9, 8], [9, 8], [0, 8], [-12, -4], [12, -4], [3, -6], [-3, -6], [8, -10]],
		"captain_spawn": [0, -8],
	},
}

# ------------------------------------------------------------ upgrades ------
# v0.2 economy contract: GOLD is the only spendable; every purchase must be
# physically visible and change real gameplay. First Mines raid (30g) should
# put ONE upgrade immediately in reach.
const UPGRADES := {
	"soul_bell": {"label": "Soul Bell of the Crypt", "cost": 35,
		"desc": "Three Risen claw free of the crypt whenever raiders descend.",
		"skeletons": 3},
	"gate_reinforcement": {"label": "Reinforced Gate", "cost": 25,
		"desc": "Iron-shod portcullis: raiders take twice as long to force it.",
		"breach_mult": 2.0},
}

# Onboarding beat chain for the first 10 minutes (Exposition→Validation→Challenge).
const OBJECTIVE_CHAIN := [
	{"id": "rally",       "text": "RALLY YOUR HORDE — they await your command [1]"},
	{"id": "war_table",   "text": "CONSULT THE WAR TABLE — approach the dark map in the throne hall [E]"},
	{"id": "raid_mines",  "text": "FIRST DECREE: SEIZE THE MINES — tribute withheld"},
	{"id": "spend",       "text": "SPEND THE SPOILS — open the War Table and claim an upgrade [TAB/E]"},
	{"id": "grow",        "text": "GROW YOUR DOMINION — the world is watching"},
]

# ------------------------------------------------------- world tuning ---
const THREAT_MONASTERY_TRIGGER := 50.0   # passive rule: church reacts to sustained threat
const FEAR_PASSIVE_PROJECT := 45.0       # guild posts contract at high fear
