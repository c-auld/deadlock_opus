extends SceneTree
## Scripted playtest: drives the real game through injected keyboard/mouse events.
## Run windowed (mouse capture + rendering):  godot --path . --script tests/playtest.gd
## Optional screenshot dir as user arg:       ... -- /some/dir/

var main: Node
var results: Array = []
var shot_dir := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		shot_dir = args[0]
	_run.call_deferred()


func _run() -> void:
	await _t_movement()
	await _t_shoot_reload()
	await _t_zombie_combat()
	await _t_zombie_attack_and_heal()
	await _t_pickups_inventory()
	await _t_door_and_win()
	await _t_defeat_and_restart()
	var fails := results.filter(func(r): return not r[1]).size()
	print("\n==== %d checks, %d failed ====" % [results.size(), fails])
	for r in results:
		print("%s  %s  %s" % ["PASS" if r[1] else "FAIL", r[0], r[2]])
	quit(1 if fails > 0 else 0)


# --- helpers -----------------------------------------------------------------

func check(name: String, ok: bool, detail := "") -> void:
	results.append([name, ok, detail])


## Waits in simulated time (physics ticks), so a throttled background window can't skew results.
func wait(sec: float) -> void:
	for i in int(sec * Engine.physics_ticks_per_second):
		await physics_frame


func fresh() -> void:
	paused = false
	if main:
		main.queue_free()
		await process_frame
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await wait(0.2)


func key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)


func tap(code: Key) -> void:
	key(code, true)
	await process_frame
	key(code, false)
	await process_frame


## Holds keys for `sec` of simulated time. Re-sends the press every tick because the OS
## releases held keys whenever the (background) test window loses focus.
func hold(code: Key, sec: float, extra: Array = []) -> void:
	for i in int(sec * Engine.physics_ticks_per_second):
		for k in [code] + extra:
			key(k, true)
		await physics_frame
	for k in [code] + extra:
		key(k, false)
	await process_frame


func click() -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = Vector2(640, 360)
		Input.parse_input_event(e)
		await process_frame


func place(pos: Vector3, look_at_pos: Vector3) -> void:
	var p = main.player
	p.global_position = pos
	p.velocity = Vector3.ZERO
	aim(look_at_pos)


func aim(target: Vector3) -> void:
	var p = main.player
	var cam: Vector3 = p.global_position + Vector3(0, p.EYE, 0)
	var d := target - cam
	p.rotation.y = atan2(-d.x, -d.z)
	p.cam.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())


func snap(name: String) -> void:
	if shot_dir == "":
		return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(shot_dir + name + ".png")


func park_zombies() -> void:
	for z in main.zombies:
		z.set_physics_process(false)


# --- tests -------------------------------------------------------------------

func _t_movement() -> void:
	await fresh()
	park_zombies()
	check("mouse captured at start", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "mode=%d" % Input.mouse_mode)
	var p = main.player
	var start: Vector3 = p.global_position
	await hold(KEY_W, 1.0)
	var walked: float = start.z - p.global_position.z
	check("W moves forward", walked > 1.5, "moved %.2fm in 1s" % walked)
	var x0: float = p.global_position.x
	await hold(KEY_D, 0.5)
	check("D strafes right", p.global_position.x - x0 > 0.5, "dx=%.2f" % (p.global_position.x - x0))
	var z0: float = p.global_position.z
	await hold(KEY_W, 1.0, [KEY_SHIFT])
	check("Shift sprints faster than walking", z0 - p.global_position.z > walked + 0.8, "sprint %.2fm vs walk %.2fm" % [z0 - p.global_position.z, walked])
	place(Vector3(0, 0.05, -10), Vector3(0, 1.6, -30))
	await hold(KEY_A, 1.5)
	check("walls block movement", p.global_position.x > -1.4, "x=%.2f after pushing into wall" % p.global_position.x)


func _t_shoot_reload() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	place(Vector3(0, 0.05, -3), Vector3(0, 1.5, -20))
	check("starts with 6 loaded, 0 spare", p.mag == 6 and p.reserve == 0, "%d|%d" % [p.mag, p.reserve])
	await click()
	await process_frame
	check("click fires (mag 6->5)", p.mag == 5, "mag=%d" % p.mag)
	check("muzzle flash shown", p.muzzle_flash.visible or p.flash_t > -0.1, "")
	await snap("shoot_flash")
	await click()
	check("fire-rate limit (instant 2nd click ignored)", p.mag == 5, "mag=%d" % p.mag)
	await wait(0.35)
	await click()
	check("second shot after delay", p.mag == 4, "mag=%d" % p.mag)
	await tap(KEY_R)
	check("R with no spare ammo does not reload", p.reloading == 0.0 and main.msg_label.text.contains("No spare"), main.msg_label.text)
	p.reserve = 10
	await tap(KEY_R)
	check("R starts reload", p.reloading > 0.0, "")
	await wait(0.3)
	await click()
	check("can't fire while reloading", p.mag == 4, "mag=%d" % p.mag)
	await wait(1.3)
	check("reload fills mag from reserve", p.mag == 8 and p.reserve == 6, "%d|%d" % [p.mag, p.reserve])
	check("HUD shows ammo", main.ammo_label.text.strip_edges() == "8 | 6", main.ammo_label.text)
	p.mag = 0
	p.reserve = 0
	await wait(0.35)
	await click()
	check("empty gun clicks, no shot", p.mag == 0 and main.msg_label.text.contains("Out of ammo"), main.msg_label.text)


func _t_zombie_combat() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var z = main.zombies[1]
	z.set_physics_process(true)
	z.global_position = Vector3(0, 0, -16)
	z.rotation.y = 0.0  # facing -z, away from the player: hasn't noticed them
	place(Vector3(0, 0.05, -9), z.global_position + Vector3(0, 1.1, 0))
	await physics_frame  # let the physics server pick up the teleport
	await physics_frame
	check("zombie unaware at 7m behind its back", z.mode == z.DORMANT, "mode=%d" % z.mode)
	await click()
	await process_frame
	check("body shot = 1 damage", z.hp == 4, "hp=%d" % z.hp)
	check("shot alerts zombie", z.is_hostile(), "mode=%d" % z.mode)
	await wait(0.35)
	aim(z.global_position + Vector3(0, 1.72, 0))
	await click()
	await process_frame
	check("headshot = 2 damage", z.hp == 2, "hp=%d" % z.hp)
	await snap("zombie_hit")
	var shots := 0
	while z.mode != z.DEAD and shots < 6:
		await wait(0.35)
		aim(z.global_position + Vector3(0, 1.1, 0))
		await click()
		shots += 1
	check("zombie dies at 0 hp", z.mode == z.DEAD, "after %d more shots, hp=%d" % [shots, z.hp])
	await wait(0.8)
	check("dead zombie stops blocking", z.col.disabled, "")
	var pos: Vector3 = z.global_position
	await wait(1.0)
	check("dead zombie stays put", pos.distance_to(z.global_position) < 0.05, "")
	await snap("zombie_dead")

	# Detection by sight: an idle zombie facing the player notices them.
	var z2 = main.zombies[0]
	z2.set_physics_process(true)
	z2.global_position = Vector3(0, 0, -20)
	z2.rotation.y = 0.0  # facing -z, away
	z2.mode = z2.DORMANT  # forget the gunshots it heard above
	place(Vector3(0, 0.05, -12), Vector3(0, 1, -30))
	await wait(0.3)
	check("no detection from behind at 8m", z2.mode == z2.DORMANT, "mode=%d" % z2.mode)
	z2.rotation.y = PI  # turn to face +z (towards player)
	await wait(0.3)
	check("detects player in sight at 8m", z2.mode == z2.CHASE, "mode=%d" % z2.mode)
	var d0: float = z2.global_position.distance_to(p.global_position)
	await wait(1.0)
	var d1: float = z2.global_position.distance_to(p.global_position)
	check("pursues at shambling pace (~1.3 m/s)", d0 - d1 > 0.6 and d0 - d1 < 2.0, "closed %.2fm in 1s" % (d0 - d1))
	# Losing the zombie: break line of sight and wait it out.
	place(Vector3(10, 0.05, -31.5), Vector3(20, 1.6, -31.5))
	z2.global_position = Vector3(0, 0, -12)
	await wait(7.5)
	check("zombie gives up after losing the player", z2.mode == z2.IDLE, "mode=%d" % z2.mode)


func _t_zombie_attack_and_heal() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var z = main.zombies[1]
	z.set_physics_process(true)
	place(Vector3(0, 0.05, -12), Vector3(0, 1.6, -20))
	z.global_position = Vector3(0, 0, -13.1)
	z._start_chase()
	await wait(1.0)
	check("zombie attacks at close range", p.health == 75, "health=%d" % p.health)
	check("damage feedback (red flash)", main.hurt_flash.color.a > 0.05 or p.health < 100, "a=%.2f" % main.hurt_flash.color.a)
	check("HUD condition updates", main.health_label.text == "CAUTION" or main.health_label.text == "FINE", main.health_label.text)
	await snap("hurt")
	z.set_physics_process(false)
	p.health = 30
	main.heal_count = 1
	await wait(0.1)
	check("DANGER state at 30hp", main.health_label.text == "DANGER", main.health_label.text)
	await tap(KEY_TAB)
	# items: Handgun, First Aid Spray
	await tap(KEY_DOWN)
	await tap(KEY_ENTER)
	check("using First Aid Spray heals +60", p.health == 90 and main.heal_count == 0, "health=%d heals=%d" % [p.health, main.heal_count])
	await tap(KEY_TAB)
	check("inventory closes", main.state == main.State.PLAY and not paused, "")


func _t_pickups_inventory() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	check("4 pickups placed", main.pickups.size() == 4, str(main.pickups.size()))
	place(Vector3(0, 0.05, -21.0), Vector3(-0.9, 0.2, -21.0))
	await wait(0.1)
	check("pickup prompt shown", main.prompt_label.text.contains("Handgun Ammo"), main.prompt_label.text)
	await snap("ammo_pickup")
	await tap(KEY_E)
	check("E collects ammo (+5 reserve)", p.reserve == 5 and main.pickups.size() == 3, "reserve=%d" % p.reserve)
	place(Vector3(-2.7, 0.05, -7.3), Vector3(-3.6, 0.2, -7.5))
	await wait(0.1)
	await tap(KEY_E)
	check("E collects First Aid Spray", main.heal_count == 1, "heals=%d" % main.heal_count)

	# Inventory: open, contents, pause, use ammo, refuse heal at full health.
	p.mag = 3
	var z = main.zombies[1]
	z.set_physics_process(true)
	z.global_position = Vector3(0, 0, -11)
	z._start_chase()
	await tap(KEY_TAB)
	check("Tab opens inventory + pauses", main.state == main.State.INVENTORY and paused and main.inv_panel.visible, "")
	var names := []
	for i in main.inv_list.item_count:
		names.append(main.inv_list.get_item_text(i).strip_edges())
	check("inventory lists weapon, ammo, heal", names[0].begins_with("Handgun") and names[1].begins_with("Handgun Ammo") and names[2].begins_with("First Aid"), str(names))
	await snap("inventory")
	var zpos: Vector3 = z.global_position
	await wait(1.0)
	check("world frozen while inventory open", zpos.distance_to(z.global_position) < 0.01, "")
	await tap(KEY_DOWN)  # Handgun Ammo
	await tap(KEY_ENTER)
	check("using ammo loads the handgun", p.mag == 8 and p.reserve == 0, "%d|%d" % [p.mag, p.reserve])
	# Ammo stack is gone now; list = Handgun, First Aid Spray.
	main.inv_list.select(1)
	main._on_inv_selected(1)
	await tap(KEY_ENTER)
	check("heal refused at full health (not wasted)", main.heal_count == 1 and main.inv_desc.text.contains("already"), main.inv_desc.text)
	await tap(KEY_TAB)
	check("Tab closes inventory", main.state == main.State.PLAY and not paused, "")
	z.set_physics_process(false)

	# Key item in storage; taking it wakes the corridor "corpse".
	place(Vector3(9.0, 0.05, -25.6), Vector3(9.0, 0.6, -24.6))
	await wait(0.1)
	await tap(KEY_E)
	check("E collects Exit Keycard", main.has_key, "")
	await wait(2.0)
	check("corpse rises after key pickup", main.riser.mode == main.riser.CHASE, "mode=%d" % main.riser.mode)
	await tap(KEY_I)
	var has_key_row := false
	for i in main.inv_list.item_count:
		has_key_row = has_key_row or main.inv_list.get_item_text(i).contains("Keycard")
	check("I key also opens inventory; keycard listed", main.state == main.State.INVENTORY and has_key_row, "")
	await tap(KEY_ESCAPE)
	check("Esc closes inventory", main.state == main.State.PLAY, "")


func _t_door_and_win() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	place(Vector3(26.4, 0.05, -31.5), Vector3(30, 1.6, -31.5))
	await wait(0.1)
	check("door prompt (locked)", main.prompt_label.text.contains("locked"), main.prompt_label.text)
	await tap(KEY_E)
	check("door stays locked without key", not main.door_unlocked and main.msg_label.text.contains("Locked"), main.msg_label.text)
	await hold(KEY_W, 1.0)
	check("locked door blocks the player", p.global_position.x < 27.8, "x=%.2f" % p.global_position.x)
	main.has_key = true
	await tap(KEY_E)
	check("keycard unlocks door (consumed)", main.door_unlocked and not main.has_key, "")
	await wait(2.7)
	await snap("door_open")
	# Walk until through the exit (frame-time independent: background windows get throttled).
	var ticks := 0
	while main.state == main.State.PLAY and ticks < 360:
		key(KEY_W, true)
		await physics_frame
		ticks += 1
	key(KEY_W, false)
	check("walking out = victory", main.state == main.State.WON, "x=%.2f state=%d" % [p.global_position.x, main.state])
	await wait(2.0)
	check("victory screen", main.end_panel.visible and main.end_title.text == "YOU ESCAPED", main.end_sub.text)
	await snap("win")


func _t_defeat_and_restart() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var z = main.zombies[1]
	z.set_physics_process(true)
	place(Vector3(0, 0.05, -12), Vector3(0, 1.6, -20))
	z.global_position = Vector3(0, 0, -13.1)
	z._start_chase()
	p.health = 25
	await wait(1.2)
	check("health 0 = defeat", main.state == main.State.LOST and p.health == 0, "health=%d" % p.health)
	await wait(2.0)
	check("defeat screen", main.end_panel.visible and main.end_title.text == "YOU DIED", "")
	await snap("dead")
	var old := main
	await tap(KEY_R)
	await wait(0.3)
	main = current_scene
	check("R restarts the level", main != old and main.state == main.State.PLAY and main.player.health == 100, "")
