# v0.3 gameplay-depth regression checks.
# Run: Godot --headless -s res://tests/depth_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_expedition_doctrines()
	test_transient_lair_damage()
	test_physical_lair_identity()
	test_militia_archetypes()
	print("---")
	print("DEPTH_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_expedition_doctrines() -> void:
	var w := WorldState.new(404)
	var d := DomainState.new()
	var holy := Expedition.make_recipe(w, d, "HOLY_EXPEDITION")
	var crown := Expedition.make_recipe(w, d, "CROWN_REPRISAL")
	var guild := Expedition.make_recipe(w, d, "GUILD_CONTRACT")
	ok(holy["doctrine"] == "purge", "depth: Church uses purge doctrine")
	ok(holy["objectives"] == ["consecrate_crypt", "steal_relic"],
		"depth: Church disables lair system before theft")
	ok(crown["doctrine"] == "strike", "depth: Crown uses strike doctrine")
	ok(crown["objectives"] == ["disable_gate", "steal_relic"],
		"depth: Crown sabotages gate before deeper objective")
	ok(guild["doctrine"] == "retrieval" and guild["objectives"] == ["steal_relic"],
		"depth: Guild remains a focused retrieval team")

func test_transient_lair_damage() -> void:
	var d := DomainState.new()
	d.upgrades["soul_bell"] = true
	d.suppress_raid_system("soul_bell")
	d.suppress_raid_system("gate_controls")
	ok(d.is_raid_system_disabled("soul_bell"), "depth: Soul Bell can be suppressed")
	ok(d.is_raid_system_disabled("gate_controls"), "depth: gate controls can be sabotaged")
	var saved := d.to_dict()
	var restored := DomainState.new()
	restored.from_dict(saved)
	ok(not restored.is_raid_system_disabled("soul_bell"),
		"depth: tactical sabotage is not serialized as permanent damage")
	d.reset_raid_systems()
	ok(not d.is_raid_system_disabled("soul_bell") and not d.is_raid_system_disabled("gate_controls"),
		"depth: raid systems reset between expeditions")

func test_physical_lair_identity() -> void:
	var f := FortressBuilder.new()
	get_root().add_child(f)
	f.build()
	f.build_lair_identity()
	ok(f.interactables.has("war_table"), "depth: physical War Table is registered")
	ok(f.interactables.has("soul_bell"), "depth: Soul Bell is a semantic lair system")
	ok(f.interactables.has("gate_controls"), "depth: gate controls are a semantic lair system")
	ok(f.interactables["soul_bell"]["kind"] == "lair_system",
		"depth: reverse-raid targets are semantic, not decoration")
	f.free()

func test_militia_archetypes() -> void:
	var site: Dictionary = Defs.SITES["village"]
	var shield := Grunt.new(); shield.setup(site, false, "shield")
	var spear := Grunt.new(); spear.setup(site, false, "spearman")
	var archer := Grunt.new(); archer.setup(site, false, "archer")
	ok(shield.max_hp > spear.max_hp, "depth: shield is the durable frontline role")
	ok(spear.def_range() > shield.def_range(), "depth: spear controls more melee space")
	ok(spear.dmg > shield.dmg, "depth: spear trades defense for damage")
	ok(archer.def_range() >= 8.0, "depth: archer is genuinely ranged")
	ok(archer.max_hp < shield.max_hp, "depth: archer pays durability for range")
	shield.free(); spear.free(); archer.free()
