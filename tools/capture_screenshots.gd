extends SceneTree
## Regenerates the README screenshots. Run windowed (needs a renderer):
##   godot --path . --script tools/capture_screenshots.gd
## Writes PNGs to docs/screenshots/.

const OUT := "res://docs/screenshots/"
var main: Node


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	_run.call_deferred()


func _run() -> void:
	await _settle(1.0)
	# Release the mouse: the game only applies mouse-look while captured, so the real
	# mouse can't swing the camera while shots are being staged.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.player.enabled = false
	for z in main.zombies:
		z.set_physics_process(false)

	# 1. Opening corridor with the controls hint.
	_view(Vector3(0, 0.05, -0.5), Vector3(0, 1.3, -20))
	main.show_msg("Find a way out.  [LMB] shoot  [R] reload  [Tab] items  [E] use  [F] light", 99)
	await _snap("01_corridor")
	main.show_msg("", 0)

	# 2. Zombie close-up in the flashlight.
	var z = main.zombies[1]
	z.global_position = Vector3(0, 0, -6.4)
	z.rotation.y = PI
	_view(Vector3(0, 0.05, -4.0), z.global_position + Vector3(0, 1.15, 0))
	await _snap("02_zombie")

	# 3. Lunging attack, seen from the side.
	z.mode = z.CHASE
	main.player.global_position = Vector3(0, 0.05, -5.3)
	z.attack_t = 0.5
	z._physics_process(0.03)
	z.rotation.y = PI
	_view(Vector3(-1.0, 0.05, -4.4), z.global_position + Vector3(0, 1.2, 0))
	await _snap("03_attack")
	z.global_position = Vector3(12.0, 0, -25.0)
	z.mode = z.DORMANT
	z._pose_idle()
	var d: Vector3 = Vector3(11.0, 0, -30.0) - z.global_position
	z.rotation.y = atan2(-d.x, -d.z)

	# 4. Storage room: the guard and the glinting keycard.
	_view(Vector3(10.6, 0.05, -29.6), Vector3(10.4, 0.9, -24.8))
	await _snap("04_storage")

	# 5. Door room: terminal glow and the red keycard reader.
	_view(Vector3(21.0, 0.05, -29.0), Vector3(27.5, 1.3, -33.0))
	await _snap("05_door_room")

	# 6. Item screen.
	main.player.reserve = 5
	main.player.mag = 3
	main.heal_count = 1
	main.has_key = true
	main.player.health = 55
	_view(Vector3(0, 0.05, -12), Vector3(0, 1.3, -30))
	main._open_inventory()
	await _snap("06_items")
	main._close_inventory()

	# 7. Death screen.
	main.player.health = 0
	z.global_position = Vector3(0, 0, -13.2)
	_view(Vector3(0, 0.05, -12), Vector3(0, 1.3, -30))
	main._lose(z)
	await _settle(2.5)
	await _snap("07_death")
	quit()


func _view(pos: Vector3, look: Vector3) -> void:
	var p = main.player
	p.global_position = pos
	var d := look - (pos + Vector3(0, p.EYE, 0))
	p.rotation.y = atan2(-d.x, -d.z)
	p.cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())


func _settle(sec: float) -> void:
	for i in int(sec * Engine.physics_ticks_per_second):
		await physics_frame


func _snap(name: String) -> void:
	await _settle(0.8)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(OUT + name + ".png")
	print("saved ", name)
