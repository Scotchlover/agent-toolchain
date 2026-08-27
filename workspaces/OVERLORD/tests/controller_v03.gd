# v0.3 controller/traversal regression checks.
# Run: Godot --headless -s res://tests/controller_v03.gd
extends SceneTree

var checks := 0
var fails := 0

func _initialize() -> void:
	test_camera_relative_axes()
	test_doorway_funnel()
	test_boss_capsule()
	print("---")
	print("CONTROLLER_V03 CHECKS=%d FAILS=%d" % [checks, fails])
	quit(1 if fails > 0 else 0)

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("PASS  " + label)
	else:
		fails += 1
		print("FAIL  " + label)

func test_camera_relative_axes() -> void:
	# Simulate a camera facing world +Z. Its screen-right is world -X.
	var fwd := Vector3(0, 0, 1)
	var right := Vector3(-1, 0, 0)
	var w := Sovereign.camera_relative_move(Vector2(0, 1), fwd, right).normalized()
	var s := Sovereign.camera_relative_move(Vector2(0, -1), fwd, right).normalized()
	var d := Sovereign.camera_relative_move(Vector2(1, 0), fwd, right).normalized()
	var a := Sovereign.camera_relative_move(Vector2(-1, 0), fwd, right).normalized()
	ok(w.dot(fwd) > 0.99, "movement: W is camera-forward")
	ok(s.dot(-fwd) > 0.99, "movement: S is camera-back")
	ok(d.dot(right) > 0.99, "movement: D is screen-right")
	ok(a.dot(-right) > 0.99, "movement: A is screen-left")

func test_doorway_funnel() -> void:
	var axis := Vector3(0, 0, 1)
	var actor := Vector3(1.05, 0, -1.6)
	var door := Vector3.ZERO
	var move := Vector3(1.4, 0, 4.0)
	var assisted := Sovereign.doorway_funnel_velocity(move, actor, door, axis)
	ok(assisted.z > 0.0, "door assist preserves travel direction")
	ok(absf(assisted.x) < absf(move.x), "door assist reduces lateral jamb drift")
	ok(absf(assisted.length() - move.length()) < 0.01, "door assist preserves requested speed")
	var sideways := Sovereign.doorway_funnel_velocity(Vector3(4, 0, 0), actor, door, axis)
	ok(sideways.is_equal_approx(Vector3(4, 0, 0)), "door assist does not hijack sideways movement")

func test_boss_capsule() -> void:
	ok(Sovereign.BODY_RADIUS <= 0.55, "traversal: gameplay capsule narrower than visual body")
	ok(Sovereign.DOOR_ASSIST_RANGE >= 3.0, "traversal: doorway assist engages before the jamb")
