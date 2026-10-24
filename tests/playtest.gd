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
	# Leave the desktop mouse alone (also stops real mouse motion turning the view mid-test).
	load("res://scripts/main.gd").grab_mouse = false
	_run.call_deferred()


func _run() -> void:
	await _t_movement()
	await _t_shoot_reload()
	await _t_zombie_combat()
	await _t_zombie_attack_and_heal()
	await _t_zombie_lunge()
	await _t_pickups_inventory()
	await _t_medkits()
	await _t_lockers()
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


## Left-drag from `at` by `by` pixels in ten steps (injected mouse events).
func drag(at: Vector2, by: Vector2) -> void:
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = true
	b.position = at
	b.global_position = at
	Input.parse_input_event(b)
	await process_frame
	for i in 10:
		var m := InputEventMouseMotion.new()
		at += by / 10.0
		m.position = at
		m.global_position = at
		m.relative = by / 10.0
		m.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(m)
		await process_frame
	var r: InputEventMouseButton = b.duplicate()
	r.pressed = false
	r.position = at
	r.global_position = at
	Input.parse_input_event(r)
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
	check("test leaves the mouse free", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "mode=%d" % Input.mouse_mode)
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
	check("starts with 9+1 loaded, 0 spare", p.mag == 9 and p.chambered and p.reserve == 0, "%d+%s|%d" % [p.mag, p.chambered, p.reserve])
	check("HUD shows ammo as 'loaded / reserve'", main.ammo_label.text.strip_edges() == "10 / 0", main.ammo_label.text)
	await click()
	await process_frame
	check("click fires (10->9)", p.rounds() == 9, "rounds=%d" % p.rounds())
	check("muzzle flash shown", p.muzzle_flash.visible or p.flash_t > -0.1, "")
	await snap("shoot_flash")
	await click()
	check("fire-rate limit (instant 2nd click ignored)", p.rounds() == 9, "rounds=%d" % p.rounds())
	await wait(0.35)
	await click()
	check("second shot after delay", p.rounds() == 8, "rounds=%d" % p.rounds())
	await wait(0.1)
	check("muzzle flash gone after ~50ms", not p.muzzle_flash.visible, "")
	await tap(KEY_R)
	check("R with no spare ammo does not reload", p.reloading == 0.0 and main.msg_label.text.contains("No spare"), main.msg_label.text)

	# Tactical reload: rounds left, so swap the magazine only -> 15 + 1 chambered.
	p.reserve = 30
	await tap(KEY_R)
	check("R starts reload", p.reloading > 0.0 and not p.reload_empty, "")
	check("tactical reload is 1.2-1.8s", p.reloading >= 1.2 and p.reloading <= 1.8, "%.2fs" % p.reloading)
	await wait(0.3)
	var shots := [0]
	p.fired.connect(func(_h): shots[0] += 1)
	await click()
	check("can't fire while reloading", shots[0] == 0, "shots=%d" % shots[0])
	await wait(1.2)
	check("tactical reload = full mag + chambered (16)", p.rounds() == 16 and p.reserve == 22, "%d / %d" % [p.rounds(), p.reserve])
	await tap(KEY_R)
	check("R when full does nothing", p.reloading == 0.0, "")

	# Run it dry: the slide locks back on the last shot, then the trigger just clicks.
	p.mag = 0
	p.fire_cd = 0.0
	await click()
	check("last round locks the slide back", not p.chambered and p.slide_locked, "")
	await wait(0.35)
	var reserve_before: int = p.reserve
	await click()
	check("empty gun dry-fires, no shot", p.rounds() == 0 and p.reserve == reserve_before and main.msg_label.text.contains("Empty"), main.msg_label.text)

	# Empty reload: mag out, mag in, slide release -> 15 rounds.
	await tap(KEY_R)
	check("empty reload starts", p.reloading > 0.0 and p.reload_empty, "")
	check("empty reload is 1.2-1.8s", p.reloading >= 1.2 and p.reloading <= 1.8, "%.2fs" % p.reloading)
	await wait(0.6)
	await snap("reload_mag_out")
	check("slide stays locked until released", p.slide_locked, "")
	await wait(1.1)
	check("empty reload = full magazine (15), slide forward", p.rounds() == 15 and p.chambered and not p.slide_locked and p.reserve == 7, "%d / %d" % [p.rounds(), p.reserve])

	# Pickup into an empty gun only adds to the reserve.
	p.mag = 0
	p.chambered = false
	p.reserve = 0
	main._collect({"kind": "ammo", "amount": 5, "node": Node.new()})
	check("ammo pickup goes to reserve, gun stays empty", p.rounds() == 0 and p.reserve == 5, "%d / %d" % [p.rounds(), p.reserve])
	p.reserve = 0
	await wait(0.35)
	await click()
	check("out of ammo message", main.msg_label.text.contains("Out of ammo"), main.msg_label.text)


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
	# items: Handgun, First Aid Kit
	await tap(KEY_DOWN)
	await tap(KEY_ENTER)
	check("using First Aid Kit heals +60", p.health == 90 and main.heal_count == 0, "health=%d heals=%d" % [p.health, main.heal_count])
	await tap(KEY_TAB)
	check("inventory closes", main.state == main.State.PLAY and not paused, "")


func _t_pickups_inventory() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	check("7 pickups placed (2 ammo, kit, key, 2 med kits, 1 in a locker)", main.pickups.size() == 7, str(main.pickups.size()))
	place(Vector3(0, 0.05, -21.0), Vector3(-0.9, 0.2, -21.0))
	await wait(0.1)
	check("pickup prompt shown", main.prompt_label.text.contains("Handgun Ammo"), main.prompt_label.text)
	await snap("ammo_pickup")
	await tap(KEY_E)
	check("E collects ammo (+5 reserve)", p.reserve == 5 and main.pickups.size() == 6, "reserve=%d" % p.reserve)
	place(Vector3(-2.7, 0.05, -7.3), Vector3(-3.6, 0.2, -7.5))
	await wait(0.1)
	await tap(KEY_E)
	check("E collects First Aid Kit", main.heal_count == 1, "heals=%d" % main.heal_count)

	# Inventory: open, contents, pause, use ammo, refuse heal at full health.
	p.mag = 3
	p.chambered = true
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
	main.inv_list.select(0)
	main._on_inv_selected(0)
	await process_frame
	check("item viewer shows the selected item's model", main.preview_id == "handgun" and main.preview_pivot.get_child_count() > 0, main.preview_id)
	var rot0: Vector3 = main.preview_pivot.rotation
	await drag(main.inv_preview.get_global_rect().get_center(), Vector2(120, 40))
	check("dragging rotates the item viewer", main.preview_pivot.rotation.distance_to(rot0) > 0.5 and not main.preview_drag, "%s" % (main.preview_pivot.rotation - rot0))
	main.inv_list.select(1)
	main._on_inv_selected(1)
	await process_frame
	check("viewer swaps model with the selection", main.preview_id == "ammo", main.preview_id)
	var zpos: Vector3 = z.global_position
	await wait(1.0)
	check("world frozen while inventory open", zpos.distance_to(z.global_position) < 0.01, "")
	main.inv_list.select(2)  # First Aid Kit
	main._on_inv_selected(2)
	await tap(KEY_ENTER)
	check("heal refused at full health (not wasted)", main.heal_count == 1 and main.inv_desc.text.contains("already"), main.inv_desc.text)
	main.inv_list.select(1)  # Handgun Ammo
	main._on_inv_selected(1)
	await tap(KEY_ENTER)
	check("using ammo closes the items and starts a reload", main.state == main.State.PLAY and not paused and p.reloading > 0.0, "")
	await wait(1.6)
	check("...which loads the handgun", p.rounds() == 9 and p.reserve == 0, "%d / %d" % [p.rounds(), p.reserve])
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


func _t_medkits() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var kits: Array = main.pickups.filter(func(k): return k.kind == "medkit")
	var kit: Dictionary = kits[0]
	var at: Vector3 = kit.node.global_position
	place(at + Vector3(-2.0, 0.05, 0), at)
	await wait(0.1)
	check("no [E] prompt for walk-over med kits", not main.prompt_label.text.contains("Pick up"), main.prompt_label.text)
	# Full health: walking over it leaves it there.
	place(at + Vector3(0, 0.05, 0), at + Vector3(0, 0, -1))
	await wait(0.2)
	check("med kit ignored at full health", main.pickups.has(kit) and p.health == 100, "health=%d" % p.health)
	await snap("medkit")
	# Hurt: walk onto it -> +50, removed.
	p.health = 40
	place(at + Vector3(-1.5, 0.05, 0), at + Vector3(0, 0.2, 0))
	await hold(KEY_W, 1.2)
	check("walking over a med kit heals +50", p.health == 90, "health=%d" % p.health)
	check("used med kit is removed", not main.pickups.has(kit) and main.pickups.size() == 6, str(main.pickups.size()))
	# Heal is capped at max health.
	p.health = 80
	var at2: Vector3 = kits[1].node.global_position
	place(at2 + Vector3(0, 0.05, 0), at2 + Vector3(0, 0, -1))
	await wait(0.2)
	check("med kit heal capped at 100", p.health == 100 and main.pickups.size() == 5, "health=%d" % p.health)


func _t_lockers() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var l: Dictionary = main.lockers[3]  # the grey locker, med kit inside
	var kit: Dictionary = l.items[0] if l.items.size() > 0 else {}
	var front: Vector3 = l.root.global_transform * Vector3(0, 0, l.size.z * 0.5)
	check("5 lockers, all shut, med kit in the grey one", main.lockers.size() == 5 and main.lockers.all(func(x): return x.swing == 0.0) and kit.get("kind") == "medkit", "%d" % main.lockers.size())
	# Shut: hidden and out of reach even pressed right up against the door.
	p.health = 50
	place(front + Vector3(-0.6, 0.05, 0), front + Vector3(0, 0.9, 0))
	await hold(KEY_W, 0.6)
	check("pressed against the shut locker (x=%.2f)" % p.global_position.x, p.global_position.x > front.x - 0.45, "")
	check("shut locker: med kit hidden, still and not taken", not kit.node.visible and p.health == 50 and kit.mesh.rotation.y == 0.0 and main.pickups.has(kit), "health=%d" % p.health)
	check("open prompt when facing it", main.prompt_label.text == "[E] Open locker", main.prompt_label.text)
	# Open (at full health so the kit stays put).
	p.health = 100
	place(front + Vector3(-1.0, 0.05, -0.15), front + Vector3(0, 0.9, 0))
	await tap(KEY_E)
	check("E on the door shows the med kit at once (door not moved yet)", kit.node.visible and l.swing == 0.0, "swing=%.2f" % l.swing)
	await wait(0.2)
	check("mid-swing: med kit visible but still, out of reach", l.swing > 0.0 and l.swing < 1.0 and kit.node.visible and kit.mesh.rotation.y == 0.0 and main._target_pickup().is_empty(), "swing=%.2f" % l.swing)
	await wait(0.5)
	var angle := rad_to_deg(l.pivot.rotation.y)
	check("door swings fully open (%.0f deg) in ~0.5s" % angle, l.swing == 1.0 and absf(angle - main.LOCKER_OPEN_ANGLE) < 0.01, "")
	var y0: float = kit.mesh.position.y
	await wait(0.3)
	check("open: med kit visible and bouncing/spinning", kit.node.visible and (kit.mesh.position.y != y0 or kit.mesh.rotation.y != 0.0), "")
	check("close prompt", main.prompt_label.text == "[E] Close locker", main.prompt_label.text)
	place(front + Vector3(-0.5, 0.05, -0.05), front + Vector3(0, 0.9, 0))
	await hold(KEY_W, 0.6)
	check("full health: med kit left in the open locker", main.pickups.has(kit), "")
	# Close: hidden at once, back at rest.
	place(front + Vector3(-1.0, 0.05, -0.15), front + Vector3(0, 0.9, 0))
	await tap(KEY_E)
	await wait(0.05)
	check("closing: med kit stops at rest, still visible while the door swings", kit.node.visible and kit.mesh.rotation.y == 0.0 and is_equal_approx(kit.mesh.position.y, kit.rest_y), "")
	await wait(0.6)
	check("door shuts again, med kit hidden", l.swing == 0.0 and absf(l.pivot.rotation.y) < 0.001 and not kit.node.visible, "swing=%.2f" % l.swing)
	# The door stops rather than swing through the player standing in its arc.
	var hinge: Vector3 = l.root.global_transform * l.pivot.position
	place(hinge + Vector3(-0.5, 0.05, 0.05), front + Vector3(0, 0.9, 0))
	main._toggle_locker(l)
	await wait(0.7)
	check("door blocked by the player stops part-way", l.swing < 1.0, "swing=%.2f" % l.swing)
	place(front + Vector3(-1.2, 0.05, -0.3), front + Vector3(0, 0.9, 0))
	await wait(0.7)
	check("and finishes opening once they step away", l.swing == 1.0, "swing=%.2f" % l.swing)
	# The open door is solid: walk along the row into it.
	place(Vector3(front.x - 0.35, 0.05, hinge.z - 1.0), Vector3(front.x - 0.35, 1.6, hinge.z + 2.0))
	await hold(KEY_W, 1.0)
	check("open door blocks the player", p.global_position.z < hinge.z - 0.3, "z=%.2f hinge z=%.2f" % [p.global_position.z, hinge.z])
	# Hurt: walk up to the open locker and the kit heals as usual.
	p.health = 40
	place(front + Vector3(-0.8, 0.05, -0.1), front + Vector3(0, 0.9, -0.1))
	await hold(KEY_W, 0.8)
	check("open locker: walking up to the med kit heals +50", p.health == 90 and not main.pickups.has(kit) and l.items.is_empty(), "health=%d" % p.health)
	place(Vector3(12.5, 0.05, -27.4), Vector3(14.0, 1.6, -27.4))
	await hold(KEY_W, 1.0)
	check("lockers block the player", p.global_position.x < 13.3, "x=%.2f" % p.global_position.x)


func _t_door_and_win() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	# Terminal (IBM 5155 on the desk): prompt, log text, desk blocks the player.
	place(Vector3(24.0, 0.05, -34.9), Vector3(24.0, 1.05, -36.4))
	await wait(0.1)
	check("terminal prompt", main.prompt_label.text == "[E] Read terminal", main.prompt_label.text)
	await tap(KEY_E)
	check("E zooms into the terminal (reading, player frozen)", main.state == main.State.READING and not p.enabled and main.term_cam.current, "state=%d" % main.state)
	await wait(main.TERMINAL_ZOOM_TIME + 0.7)
	check("log starts typing on the screen", main.term_typing and main.term_shown > 0 and main.term_shown < main.term_full.length(), "%d/%d" % [main.term_shown, main.term_full.length()])
	await tap(KEY_E)
	await wait(0.1)
	check("E skips to the full log", main.term_label.text.begins_with(main.TERMINAL_HEADER + main.TERMINAL_LOG) and main.prompt_label.text == "[E] Close", main.term_label.text)
	await tap(KEY_E)
	await wait(main.TERMINAL_ZOOM_TIME)
	check("E closes the terminal, control returns", main.state == main.State.PLAY and p.enabled and p.cam.current, "state=%d" % main.state)
	# A zombie hit while reading snaps you out and still hurts.
	await tap(KEY_E)
	await wait(0.3)
	main._on_zombie_attack(25, main.zombies[1])
	check("zombie hit exits the terminal and deals damage", main.state == main.State.PLAY and p.cam.current and p.health == 75, "state=%d health=%d" % [main.state, p.health])
	p.health = 100
	await hold(KEY_W, 1.0)
	check("terminal desk blocks the player", p.global_position.z > -36.0, "z=%.2f" % p.global_position.z)
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


func _t_zombie_lunge() -> void:
	await fresh()
	park_zombies()
	var p = main.player
	var z = main.zombies[1]
	var screams := [0]
	z.scream.connect(func(): screams[0] += 1)
	z.set_physics_process(true)
	place(Vector3(0, 0.05, -12), Vector3(0, 1.6, -20))
	# Chasing from outside lunge range: plain shamble, no scream.
	z.global_position = Vector3(0, 0, -18)
	z._start_chase()
	await wait(0.5)
	check("no lunge from far away", screams[0] == 0 and z.lunge_t < 0.0, "screams=%d" % screams[0])
	# Close in: it screams, rears back, then charges faster than it shambles.
	z.global_position = Vector3(0, 0, -15.6)
	await wait(0.1)
	check("screams and lunges when close", screams[0] == 1 and z.lunge_t >= 0.0, "screams=%d lunge_t=%.2f" % [screams[0], z.lunge_t])
	await wait(z.SCREAM_TIME)
	await snap("lunge")
	var d0: float = z._flat_dist(p.global_position)
	await wait(0.6)
	var d1: float = z._flat_dist(p.global_position)
	check("lunge is faster than the shamble (~2 m/s)", (d0 - d1) / 0.6 > 1.6, "%.2f m/s" % ((d0 - d1) / 0.6))
	await wait(1.5)
	check("lunge ends in a hit", p.health == 75, "health=%d" % p.health)


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
