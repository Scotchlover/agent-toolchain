# Frame-cost probe on the worst-case slice scenario (mandate §29):
# Sovereign + 14 minions + 4 heroes brawling inside the fortress.
extends Node

var main: Node3D
var t := 0.0
var frames := 0
var acc := 0.0
var hunt_t := 0.0
var _finishing := false

func _ready() -> void:
	Engine.time_scale = 1.0   # real-time cost measurement
	var packed: PackedScene = load("res://game/main.tscn")
	main = packed.instantiate()
	add_child(main)
	GS.new_game(999)
	print("BENCH booting...")

func _process(dt: float) -> void:
	t += dt
	if t > 40.0:
		print("BENCH safety exit")
		_request_exit()
		return
	if t < 1.0:
		return
	if frames == 0:
		main.sovereign.global_position = Vector3(0, 0.5, 8.5)
		var recipe := Expedition.make_recipe(GS.world, GS.domain, "HOLY_EXPEDITION")
		main._spawn_expedition(recipe)
		print("BENCH measuring...")
	hunt_t += dt
	if hunt_t > 1.0 and main.party != null:
		hunt_t = 0.0
		for h in main.party.live_members():
			main.horde.issue_hunt(h)
			break
	frames += 1
	acc += dt
	if frames >= 600:
		var avg_ms := acc / float(frames) * 1000.0
		print("BENCH frames=%d avg_frame=%.2fms (~%d fps) minions=%d" % [
			frames, avg_ms, int(1000.0 / maxf(avg_ms, 0.01)), GS.minions_alive])
		print("BENCH process=%.3fms physics=%.3fms" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
		_request_exit()

func _request_exit() -> void:
	if _finishing:
		return
	_finishing = true
	set_process(false)
	if main != null and is_instance_valid(main):
		main.shutdown_sfx()
	call_deferred("_quit_after_audio_release")

func _quit_after_audio_release() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)
