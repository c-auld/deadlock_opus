extends SceneTree
## Regenerates the README screenshots. Run windowed (needs a renderer):
##   godot --path . --script tools/capture_screenshots.gd
## Writes PNGs to docs/screenshots/.

const OUT := "res://docs/screenshots/"
var main: Node


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	# Never capture the desktop mouse, and ignore real mouse motion while shots are staged.
	load("res://scripts/main.gd").grab_mouse = false
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	_run.call_deferred()


func _run() -> void:
	await _settle(1.0)
	var p = main.player
	p.enabled = false
	for z in main.zombies:
		z.set_physics_process(false)
	var worker = main.zombies[1]  # storage guard
	var hazmat = main.riser  # lies "dead" until it rises
	var scientist = main.zombies[0]  # closet lurker
	hazmat.body.rotation.x = 0.0
	hazmat.body.position.y = 0.0

	# 1. Opening corridor with the controls hint and the USP in hand.
	_view(Vector3(0, 0.05, -0.5), Vector3(0, 1.3, -20))
	main.show_msg("Find a way out.  [LMB] shoot  [R] reload  [Tab] items  [E] use  [F] light", 99)
	await _snap("01_corridor")
	main.show_msg("", 0)

	# 2. Hero shot: the hard-hatted worker in the flashlight.
	_stand(worker, Vector3(0, 0, -6.2), Vector3(0, 0, 0))
	_view(Vector3(0.1, 0.05, -4.9), worker.global_position + Vector3(0, 1.5, 0))
	await _snap("02_zombie")

	# 3. All three outfits side by side.
	_stand(scientist, Vector3(-0.75, 0, -14.6), Vector3(-0.75, 0, -10))
	_stand(worker, Vector3(0.0, 0, -14.6), Vector3(0, 0, -10))
	_stand(hazmat, Vector3(0.75, 0, -14.6), Vector3(0.75, 0, -10))
	_view(Vector3(0, 0.05, -11.6), Vector3(0, 1.0, -14.6))
	await _snap("03_outfits")

	# 4. Rearing back to scream before the lunge.
	_stand(scientist, Vector3(-1.2, 0, -30), Vector3(0, 0, 0))
	_stand(hazmat, Vector3(1.2, 0, -30), Vector3(0, 0, 0))
	_stand(worker, Vector3(0, 0, -15.3), Vector3(0, 0, -12))
	_view(Vector3(0.3, 0.05, -12.2), worker.global_position + Vector3(0, 1.3, 0))
	worker.mode = worker.CHASE
	worker.lunge_t = 0.4
	worker._scream_anim(0.016)
	await _snap("04_lunge")

	# 5. Shot into the zombie: muzzle flash sprite, muzzle light, blood puff.
	_pose_idle(worker)
	_view(Vector3(0.3, 0.05, -12.2), worker.global_position + Vector3(0, 1.2, 0))
	await _settle(0.5)
	p.enabled = true
	p.fire_cd = 0.0
	p.try_fire()
	p.enabled = false
	await physics_frame
	await RenderingServer.frame_post_draw
	_save("05_muzzle_flash")
	worker.hp = worker.MAX_HP
	worker.stagger = 0.0

	# 6. Empty reload mid-swap: the empty mag drops out of the grip.
	_stand(worker, Vector3(12.0, 0, -25.0), Vector3(11.0, 0, -30.0))
	_view(Vector3(0, 0.05, -3), Vector3(0, 1.4, -20))
	p.mag = 0
	p.chambered = false
	p.slide_locked = true
	p.reserve = 15
	await _settle(0.3)
	p.start_reload()
	await _settle(0.32)
	await RenderingServer.frame_post_draw
	_save("06_reload")
	await _settle(1.5)

	# 7. Storage room: the guard and the glinting keycard.
	_view(Vector3(10.6, 0.05, -29.6), Vector3(10.4, 0.9, -24.8))
	await _snap("07_storage")

	# 8. Door room: terminal glow and the red keycard reader on the EXIT door.
	_view(Vector3(21.0, 0.05, -29.0), Vector3(27.5, 1.3, -33.0))
	await _snap("08_door_room")

	# 11. A walk-over med kit hopping at the end of corridor B.
	_view(Vector3(17.5, 0.05, -31.3), Vector3(18.8, 0.25, -32.3))
	await _snap("11_medkit")

	# 12. Storage lockers: the grey one swung open, its med kit hopping inside.
	var locker: Dictionary = main.lockers[3]
	main._toggle_locker(locker)
	_view(Vector3(11.6, 0.05, -27.5), Vector3(13.6, 0.8, -26.5))
	await _settle(1.0)
	await _snap("12_locker")

	# 13. Reading the IBM 5155: zoomed into the screen with the log typed out.
	_view(Vector3(24.0, 0.05, -34.9), Vector3(24.0, 1.05, -36.4))
	await _settle(0.2)
	main._open_terminal()
	await _settle(main.TERMINAL_ZOOM_TIME + 0.5)
	main.term_shown = main.term_full.length()
	main.term_typing = false
	await _snap("13_terminal")
	main._close_terminal(true)

	# 9. Item screen with the 3D handgun in the viewer.
	p.reserve = 5
	p.mag = 3
	p.chambered = true
	main.heal_count = 1
	main.has_key = true
	p.health = 55
	_view(Vector3(0, 0.05, -12), Vector3(0, 1.3, -30))
	main._open_inventory()
	main.preview_idle = -99.0  # hold the starting angle
	await _snap("09_items")
	main._close_inventory()

	# 10. Death screen.
	p.health = 0
	worker.global_position = Vector3(0, 0, -13.2)
	_view(Vector3(0, 0.05, -12), Vector3(0, 1.3, -30))
	main._lose(worker)
	await _settle(2.5)
	await _snap("10_death")
	quit()


## Plants a zombie upright at `pos`, facing `look`, in its idle pose.
func _stand(z: Node3D, pos: Vector3, look: Vector3) -> void:
	z.global_position = pos
	var d := look - pos
	z.rotation.y = atan2(-d.x, -d.z)
	z.mode = z.DORMANT
	z.lunge_t = -1.0
	_pose_idle(z)


func _pose_idle(z: Node3D) -> void:
	z._pose_idle()
	z.torso.rotation = Vector3(-0.35, 0, 0)


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
	_save(name)


func _save(name: String) -> void:
	root.get_texture().get_image().save_png(OUT + name + ".png")
	print("saved ", name)
