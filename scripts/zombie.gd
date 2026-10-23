extends CharacterBody3D
## Slow but dangerous zombie: an infected facility worker. Sleeps (or lies "dead")
## until it sees or hears the player, then stumbles after them. Get close and it
## rears back, screams and lunges at a faster pace, then swings at arm's length.
## Searches the last place it saw the player and gives up if it loses them.

signal step
signal groan
signal scream
signal attack_hit(damage: int)
signal died

enum { DORMANT, LYING, IDLE, CHASE, SEARCH, DEAD }
enum Outfit { WORKER, HAZMAT, SCIENTIST }

const MAX_HP := 5
const SPEED := 1.3
const SIGHT := 9.0
const HEAR := 3.0
const ATTACK_START := 1.3
const ATTACK_REACH := 1.8
const WINDUP := 0.55
const DAMAGE := 25
const LUNGE_RANGE := 4.0
const LUNGE_SPEED := 2.0   # still slower than the player's 2.6 walk
const SCREAM_TIME := 0.45  # rear back and scream before charging
const LUNGE_TIME := 2.5
const LUNGE_CD := 6.0
const STUMBLE_TIME := 0.75

var mode := DORMANT
var hp := MAX_HP
var player: Node3D
var last_seen := Vector3.ZERO
var search_t := 0.0
var attack_t := -1.0
var attack_cd := 0.0
var stagger := 0.0
var walk_t := 0.0
var groan_timer := 3.0
var time := 0.0
var outfit := Outfit.WORKER

var lunge_t := -1.0  # >= 0 while screaming/charging
var lunge_cd := 0.0
var lunge_carry := 0.0  # momentum a lunge carries into the swing
var stumble_t := 0.0
var stumble_next := 2.0
var stumble_dir := 1.0
var shuffle_t := 0.0
var shuffle_next := 3.0
var shuffle_dir := 1.0
var twitch := Vector3.ZERO  # decaying head jerk (x, y, z)
var twitch_arm := 0.0

var col: CollisionShape3D
var body: Node3D
var torso: Node3D
var head: Node3D
var jaw: Node3D
var arm_l: Node3D
var arm_r: Node3D
var fore_l: Node3D
var fore_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var shin_l: Node3D
var shin_r: Node3D
var coat_l: Node3D
var coat_r: Node3D
var coat_b: Node3D

# Per-zombie variation: one arm reaches, the other hangs; one leg drags.
var reach_l := 1.15
var reach_r := 0.25
var limp_l := 1.0
var limp_r := 0.55
var head_tilt := 0.35


## `m` is main.gd's material table. `kind` picks the outfit (-1 = random).
func build(m: Dictionary, kind := -1) -> void:
	outfit = (randi() % 3) if kind < 0 else kind
	col = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	add_child(col)
	wall_min_slide_angle = 0.0

	if randf() < 0.5:
		var t := reach_l
		reach_l = reach_r
		reach_r = t
		limp_l = 0.55
		limp_r = 1.0
		head_tilt = -head_tilt
	stumble_next = randf_range(1.5, 4.0)

	var skin: Material = m.skin
	var top: Material
	var legs: Material
	var boot: Material = m.boot
	var glove_l: Material = skin
	var glove_r: Material = skin
	var sleeve_r: Material = skin  # the torn-off sleeve side
	match outfit:
		Outfit.WORKER:
			top = m.coverall
			legs = m.coverall
			glove_l = m.glove
		Outfit.HAZMAT:
			top = m.hazmat
			legs = m.hazmat
			boot = m.rubber
			glove_l = m.rubber
			glove_r = m.rubber
		_:
			top = m.labcoat
			legs = m.slacks
			boot = m.dark

	body = _pivot(self, Vector3.ZERO)
	body.scale = Vector3.ONE * randf_range(0.95, 1.06)

	# Pelvis + legs.
	_limb(body, Vector3(0, 1.0, 0), 0.16, 0.15, 0.14, legs, Vector3(1, 1, 0.7))
	leg_l = _pivot(body, Vector3(-0.09, 0.88, 0))
	leg_r = _pivot(body, Vector3(0.09, 0.88, 0))
	for leg in [leg_l, leg_r]:
		_limb(leg, Vector3(0, -0.22, 0), 0.44, 0.075, 0.058, legs)
		var knee := _pivot(leg, Vector3(0, -0.44, 0))
		_ball(knee, Vector3.ZERO, 0.058, legs)
		_limb(knee, Vector3(0, -0.21, 0), 0.42, 0.056, 0.042, legs)
		if outfit == Outfit.HAZMAT:
			# Tall rubber boots.
			_limb(knee, Vector3(0, -0.3, 0), 0.24, 0.06, 0.056, boot)
			_box(knee, Vector3(0, -0.44, -0.04), Vector3(0.1, 0.06, 0.22), boot)
		else:
			_box(knee, Vector3(0, -0.43, -0.03), Vector3(0.1, 0.08, 0.22), boot)
			if outfit == Outfit.WORKER:
				_box(knee, Vector3(0, -0.43, -0.13), Vector3(0.1, 0.07, 0.04), m.steel)  # steel toe cap
		if outfit == Outfit.WORKER:
			_limb(knee, Vector3(0, -0.28, 0), 0.04, 0.052, 0.05, m.hivis)  # reflective shin band
		if leg == leg_l:
			shin_l = knee
		else:
			shin_r = knee

	if outfit == Outfit.WORKER:
		# Tool belt with a pouch and a hanging wrench.
		_limb(body, Vector3(0, 0.97, 0), 0.05, 0.158, 0.158, m.belt, Vector3(1, 1, 0.74))
		_box(body, Vector3(0.15, 0.92, -0.02), Vector3(0.05, 0.1, 0.09), m.belt)
		_box(body, Vector3(-0.155, 0.86, 0.03), Vector3(0.015, 0.18, 0.03), m.steel)
	elif outfit == Outfit.SCIENTIST:
		# Lab coat tails: front panels hang open and flap with the legs.
		coat_l = _pivot(body, Vector3(-0.1, 1.06, -0.1))
		coat_r = _pivot(body, Vector3(0.1, 1.06, -0.1))
		coat_b = _pivot(body, Vector3(0, 1.06, 0.1))
		for c in [coat_l, coat_r]:
			_box(c, Vector3(0, -0.24, 0), Vector3(0.13, 0.5, 0.015), top)
		_box(coat_l, Vector3(0.02, -0.4, -0.01), Vector3(0.06, 0.08, 0.012), m.gore)
		_box(coat_b, Vector3(0, -0.24, 0), Vector3(0.32, 0.5, 0.015), top)
		_box(coat_b, Vector3(-0.07, -0.33, 0.01), Vector3(0.1, 0.16, 0.012), m.gore)

	# Hunched torso: exposed belly, ribcage in a torn top.
	torso = _pivot(body, Vector3(0, 1.0, 0))
	torso.rotation.x = -0.35
	_limb(torso, Vector3(0, 0.1, 0), 0.2, 0.135, 0.145, skin, Vector3(1, 1, 0.72))
	_limb(torso, Vector3(0, 0.38, 0), 0.4, 0.21, 0.16, top, Vector3(1, 1, 0.62))
	_box(torso, Vector3(0.07, 0.15, -0.105), Vector3(0.12, 0.16, 0.012), top).rotation.z = 0.3
	_box(torso, Vector3(-0.07, 0.34, -0.13), Vector3(0.07, 0.1, 0.012), m.gore).rotation.z = 0.5
	_box(torso, Vector3(0.04, 0.08, -0.105), Vector3(0.07, 0.05, 0.012), m.gore)
	match outfit:
		Outfit.WORKER:
			_limb(torso, Vector3(0, 0.3, 0), 0.045, 0.184, 0.18, m.hivis, Vector3(1, 1, 0.64))
			_limb(torso, Vector3(0, 0.44, 0), 0.045, 0.2, 0.196, m.hivis, Vector3(1, 1, 0.64))
		Outfit.HAZMAT:
			# Hood torn back, respirator dragged down round the neck.
			_ball(torso, Vector3(0, 0.52, 0.13), 0.12, top, Vector3(1.15, 0.7, 0.6))
			var mask := _pivot(torso, Vector3(0.0, 0.46, -0.15))
			mask.rotation = Vector3(0.5, 0.0, 0.25)
			_box(mask, Vector3.ZERO, Vector3(0.11, 0.08, 0.05), m.rubber)
			_box(mask, Vector3(0, 0.0, -0.028), Vector3(0.05, 0.035, 0.01), m.lens)
			for side in [-1.0, 1.0]:
				var f := _limb(mask, Vector3(0.065 * side, -0.02, -0.02), 0.04, 0.028, 0.028, m.filter)
				f.rotation.x = PI / 2
		_:
			# Shirt and tie under the coat, ID badge on a lanyard.
			_box(torso, Vector3(0, 0.42, -0.128), Vector3(0.09, 0.2, 0.012), m.shirt)
			_box(torso, Vector3(0, 0.4, -0.136), Vector3(0.025, 0.16, 0.008), m.dark)
			var badge := _box(torso, Vector3(-0.1, 0.28, -0.14), Vector3(0.05, 0.07, 0.008), m.badge)
			badge.rotation.z = 0.25

	# Arms: sleeve on one side, torn off on the other. Elbows bend, hands are claws.
	arm_l = _pivot(torso, Vector3(-0.22, 0.52, 0))
	arm_r = _pivot(torso, Vector3(0.22, 0.52, 0))
	for arm in [arm_l, arm_r]:
		var left: bool = arm == arm_l
		var hand: Material = glove_l if left else glove_r
		_ball(arm, Vector3.ZERO, 0.07, top)
		_limb(arm, Vector3(0, -0.15, 0), 0.3, 0.05, 0.042, top if left else sleeve_r)
		if not left:
			_limb(arm, Vector3(0, -0.02, 0), 0.06, 0.055, 0.05, top)  # ragged sleeve stump
		if outfit == Outfit.WORKER and left:
			_limb(arm, Vector3(0, -0.12, 0), 0.035, 0.053, 0.051, m.hivis)
		var elbow := _pivot(arm, Vector3(0, -0.3, 0))
		_ball(elbow, Vector3.ZERO, 0.043, top if left else skin)
		_limb(elbow, Vector3(0, -0.135, 0), 0.27, 0.042, 0.032, top if (left and outfit != Outfit.WORKER) else skin)
		if left and outfit == Outfit.WORKER:
			_limb(elbow, Vector3(0, -0.24, 0), 0.08, 0.04, 0.036, hand)  # glove cuff
		_ball(elbow, Vector3(0, -0.3, 0), 0.045, hand, Vector3(0.6, 1.2, 1.0))
		for f in 3:
			var finger := _limb(elbow, Vector3(-0.02 + f * 0.02, -0.37, -0.01), 0.1, 0.009, 0.005, hand)
			finger.rotation.x = 0.35
		if left:
			fore_l = elbow
		else:
			fore_r = elbow

	# Neck + skull: sunken sockets, bloodshot eyes with glowing red irises, hanging jaw.
	head = _pivot(torso, Vector3(0, 0.58, -0.02))
	_limb(head, Vector3(0, 0.03, 0), 0.12, 0.045, 0.05, skin)
	_ball(head, Vector3(0, 0.15, 0), 0.115, skin, Vector3(0.95, 1.2, 1.1))
	if outfit != Outfit.HAZMAT:
		_ball(head, Vector3(0.02, 0.23, 0.03), 0.105, m.hair, Vector3(1.0, 0.55, 1.0))
	else:
		_ball(head, Vector3(0.0, 0.24, 0.02), 0.1, skin, Vector3(1.0, 0.45, 1.0))  # shaved
	for side in [-1.0, 1.0]:
		_ball(head, Vector3(0.045 * side, 0.165, -0.096), 0.036, m.dark)  # sunken socket
		_ball(head, Vector3(0.045 * side, 0.165, -0.106), 0.024, m.sclera)
		_box(head, Vector3(0.045 * side, 0.164, -0.13), Vector3(0.016, 0.016, 0.006), m.eye)
		_box(head, Vector3(0.045 * side, 0.142, -0.117), Vector3(0.042, 0.009, 0.008), m.raw)  # raw lower lid
		_box(head, Vector3(0.045 * side, 0.19, -0.118), Vector3(0.044, 0.01, 0.01), m.dark).rotation.z = -0.25 * side  # brow
	_box(head, Vector3(0, 0.07, -0.102), Vector3(0.08, 0.05, 0.02), m.dark)
	_box(head, Vector3(0, 0.088, -0.112), Vector3(0.07, 0.014, 0.01), m.bone)
	_box(head, Vector3(0.06, 0.12, -0.105), Vector3(0.04, 0.05, 0.012), m.gore)
	jaw = _pivot(head, Vector3(0, 0.075, -0.02))
	_box(jaw, Vector3(0, -0.02, -0.05), Vector3(0.11, 0.035, 0.1), skin)
	_box(jaw, Vector3(0, 0.0, -0.093), Vector3(0.07, 0.014, 0.01), m.bone)
	_box(jaw, Vector3(0.01, -0.04, -0.09), Vector3(0.05, 0.03, 0.01), m.gore)  # bloody chin

	if outfit == Outfit.WORKER:
		# Dented hard hat knocked askew.
		var hat := _pivot(head, Vector3(0.01, 0.255, 0.0))
		hat.rotation = Vector3(-0.15, 0.0, 0.2 * sign(head_tilt))
		_ball(hat, Vector3.ZERO, 0.125, m.hardhat, Vector3(1.0, 0.7, 1.12))
		_limb(hat, Vector3(0, -0.02, 0), 0.012, 0.135, 0.135, m.hardhat, Vector3(1.0, 1.0, 1.1))
		_box(hat, Vector3(0, -0.02, -0.15), Vector3(0.16, 0.012, 0.06), m.hardhat).rotation.x = 0.2  # peak
		_box(hat, Vector3(0, 0.07, 0.0), Vector3(0.03, 0.02, 0.24), m.hardhat)  # ridge
		_box(hat, Vector3(0.05, 0.04, -0.1), Vector3(0.04, 0.03, 0.02), m.dark)  # dent

	# Where it got infected: a bite with spreading black veins.
	match outfit:
		Outfit.HAZMAT:
			# Bitten through a tear in the suit: forearm wound with the yellow ripped around it.
			var tear := _pivot(fore_r, Vector3(0, -0.12, -0.036))
			_bite(tear, m, 0.8)
			_box(fore_r, Vector3(0.0, -0.02, -0.04), Vector3(0.07, 0.05, 0.012), top).rotation.z = 0.4
		Outfit.SCIENTIST:
			var s := _pivot(torso, Vector3(-0.115, 0.56, -0.08))
			s.rotation = Vector3(0.9, 0.3, 0.0)
			_bite(s, m, 1.0)
			_box(torso, Vector3(-0.12, 0.42, -0.135), Vector3(0.035, 0.18, 0.01), m.gore)  # bled down the coat
		_:
			var n := _pivot(torso, Vector3(0.115, 0.56, -0.08))
			n.rotation = Vector3(0.9, -0.3, 0.0)
			_bite(n, m, 1.0)
			_box(torso, Vector3(0.12, 0.4, -0.135), Vector3(0.04, 0.2, 0.01), m.gore)
	# Infection creeping up the neck onto the face, on the bitten side.
	var vs := -1.0 if outfit == Outfit.SCIENTIST else 1.0
	for i in 3:
		var v := _box(head, Vector3(0.088 * vs, 0.05 + i * 0.035, -0.05 + i * 0.012), Vector3(0.006, 0.05, 0.006), m.vein)
		v.rotation.z = (0.4 - i * 0.35) * vs

	_pose_idle()


## Bite wound laid out in the pivot's XY plane, facing local -Z: raw flesh,
## an arc of tooth punctures, black infected veins radiating out, a blood trickle.
func _bite(p: Node3D, m: Dictionary, s: float) -> void:
	_ball(p, Vector3.ZERO, 0.032 * s, m.raw, Vector3(1.3, 1.0, 0.35))
	_ball(p, Vector3(0, 0, 0.002), 0.042 * s, m.gore, Vector3(1.3, 1.0, 0.25))
	for i in 7:
		var a := PI * (0.15 + 0.7 * i / 6.0)
		for arc in [1.0, -1.0]:  # upper and lower jaw marks
			var at := Vector3(cos(a) * 0.04 * s, sin(a) * 0.03 * s * arc, -0.01)
			_box(p, at, Vector3(0.008, 0.008, 0.006) * s, m.dark)
	for i in 5:
		var a := TAU * i / 5.0 + 0.3
		var len := randf_range(0.05, 0.09) * s
		var v := _box(p, Vector3(cos(a), sin(a), 0) * (0.045 * s + len * 0.5) + Vector3(0, 0, -0.004), Vector3(len, 0.006, 0.005), m.vein)
		v.rotation.z = a
	_box(p, Vector3(0.01, -0.06 * s, -0.006), Vector3(0.012, 0.06 * s, 0.006), m.gore)


func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scl
	parent.add_child(mi)
	return mi


## Tapered 6-sided cylinder (faceted PS1 limb), centred on pos.
func _limb(parent: Node3D, pos: Vector3, length: float, r_top: float, r_bot: float, mat: Material, scl := Vector3.ONE) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.height = length
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.radial_segments = 6
	c.rings = 1
	return _mesh(parent, c, pos, mat, scl)


func _ball(parent: Node3D, pos: Vector3, radius: float, mat: Material, scl := Vector3.ONE) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = 7
	s.rings = 4
	return _mesh(parent, s, pos, mat, scl)


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return _mesh(parent, b, pos, mat)


func _pose_idle() -> void:
	arm_l.rotation = Vector3(reach_l * 0.5, 0, 0)
	arm_r.rotation = Vector3(reach_r * 0.5, 0, 0)
	fore_l.rotation.x = 0.3
	fore_r.rotation.x = 0.3
	shin_l.rotation.x = -0.1
	shin_r.rotation.x = -0.1
	head.rotation = Vector3(0, 0, head_tilt)
	jaw.rotation.x = -0.3
	body.rotation.z = 0.0
	body.position.y = 0.0


func set_lying() -> void:
	mode = LYING
	body.rotation.x = PI / 2
	body.position.y = 0.15
	col.disabled = true


## Lying "corpse" gets back up and comes for the player.
func rise() -> void:
	if mode != LYING:
		return
	var tw := create_tween()
	tw.tween_property(body, "rotation:x", 0.0, 1.6).set_trans(Tween.TRANS_BACK)
	tw.parallel().tween_property(body, "position:y", 0.0, 1.6)
	tw.tween_callback(func():
		col.disabled = false
		_start_chase())
	groan.emit()


func is_hostile() -> bool:
	return mode == CHASE or mode == SEARCH


func is_lunging() -> bool:
	return lunge_t >= SCREAM_TIME


## Gunshot or other noise: go and look.
func hear(pos: Vector3) -> void:
	if mode == DORMANT or mode == IDLE or mode == SEARCH:
		last_seen = pos
		mode = SEARCH
		search_t = 8.0


func take_damage(amount: int, headshot: bool) -> void:
	if mode == DEAD or mode == LYING:
		return
	hp -= amount
	attack_t = -1.0
	stagger = 0.6 if headshot else 0.35
	if lunge_t >= 0.0:
		_end_lunge(1.5)  # a hit knocks it out of the charge, but it's not done
	if not is_hostile():
		_start_chase()
	if hp <= 0:
		_die()


func _start_chase() -> void:
	mode = CHASE
	last_seen = player.global_position
	groan.emit()


func _start_lunge() -> void:
	lunge_t = 0.0
	stumble_t = 0.0
	scream.emit()


func _end_lunge(cd := LUNGE_CD) -> void:
	lunge_t = -1.0
	lunge_cd = cd


func _die() -> void:
	mode = DEAD
	lunge_t = -1.0
	col.set_deferred("disabled", true)
	jaw.rotation.x = -0.6
	var tw := create_tween()
	tw.tween_property(body, "rotation", Vector3(PI / 2, 0, 0), 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(body, "position:y", 0.15, 0.6)
	tw.parallel().tween_property(arm_l, "rotation", Vector3(0.6, 0, 0), 0.6)
	tw.parallel().tween_property(arm_r, "rotation", Vector3(-0.2, 0, 0), 0.6)
	died.emit()


func _physics_process(delta: float) -> void:
	time += delta
	if mode == DEAD or mode == LYING:
		return
	# Random nervous twitches: a sharp head jerk or arm spasm that eases off.
	twitch = twitch.move_toward(Vector3.ZERO, delta * 2.5)
	twitch_arm = move_toward(twitch_arm, 0.0, delta * 2.0)
	if randf() < delta * 0.35:
		twitch = Vector3(randf_range(-0.3, 0.4), randf_range(-0.5, 0.5), randf_range(-0.6, 0.6))
	if randf() < delta * 0.25:
		twitch_arm = randf_range(-0.6, 0.6)

	if mode == DORMANT or mode == IDLE:
		_idle_anim(delta)
		if _detects():
			_start_chase()
		return

	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = -0.1 if is_on_floor() else velocity.y - 18.0 * delta
	attack_cd = max(0.0, attack_cd - delta)
	lunge_cd = max(0.0, lunge_cd - delta)
	var dist := _flat_dist(player.global_position)

	if stagger > 0.0:
		stagger -= delta
		torso.rotation.x = -0.35 + 0.6 * stagger
		head.rotation.x = 0.5 * stagger
		move_and_slide()
		return
	torso.rotation.x = -0.35
	torso.rotation.y = 0.0
	head.rotation.x = 0.0
	head.rotation.y = twitch.y

	if attack_t >= 0.0:
		_attack(delta, dist)
		return

	var sees := _can_see_player()
	if sees:
		last_seen = player.global_position
		mode = CHASE
	elif mode == CHASE:
		mode = SEARCH
		search_t = 6.0
	if mode == SEARCH:
		search_t -= delta
		if search_t <= 0.0:
			mode = IDLE
			_end_lunge(0.0)
			_pose_idle()
			return

	if sees and dist < ATTACK_START and attack_cd <= 0.0:
		attack_t = 0.0
		lunge_carry = 1.0 if is_lunging() else 0.0
		if lunge_t >= 0.0:
			_end_lunge()
		groan.emit()
		return

	if lunge_t < 0.0 and sees and dist < LUNGE_RANGE and lunge_cd <= 0.0:
		_start_lunge()
	if lunge_t >= 0.0:
		lunge_t += delta
		if not sees or lunge_t > SCREAM_TIME + LUNGE_TIME:
			_end_lunge()
		elif lunge_t < SCREAM_TIME:
			_scream_anim(delta)
			return

	_walk(delta)


func _idle_anim(delta: float) -> void:
	# Swaying on the spot, weight rolling between feet, knees buckling, head lolling,
	# the odd shuffle round to face a new direction.
	var sway := sin(time * 0.6)
	var buckle: float = max(0.0, sin(time * 0.37 + 1.0) - 0.85) * 0.25
	body.rotation.z = sway * 0.05
	body.position.y = -buckle * 0.2
	torso.rotation.z = sin(time * 0.5) * 0.06
	torso.rotation.x = -0.35 - buckle
	leg_l.rotation.x = 0.0
	leg_r.rotation.x = 0.0
	shin_l.rotation.x = -0.1 - buckle * 2.0 - max(0.0, sway) * 0.1
	shin_r.rotation.x = -0.1 - buckle * 2.0 - max(0.0, -sway) * 0.1
	head.rotation = Vector3(twitch.x, twitch.y, head_tilt + sin(time * 0.7) * 0.2 + twitch.z)
	jaw.rotation.x = -0.3 - 0.1 * sin(time * 2.3)
	arm_l.rotation = Vector3(reach_l * 0.5 + sin(time * 0.6) * 0.06 + twitch_arm, 0, sway * 0.05)
	arm_r.rotation = Vector3(reach_r * 0.5 - sin(time * 0.6) * 0.06, 0, sway * 0.05)

	shuffle_next -= delta
	if shuffle_t <= 0.0 and shuffle_next <= 0.0:
		shuffle_t = 1.2
		shuffle_next = randf_range(4.0, 9.0)
		shuffle_dir = 1.0 if randf() < 0.5 else -1.0
	if shuffle_t > 0.0:
		var prev := sin((1.2 - shuffle_t) * TAU * 1.6)
		shuffle_t -= delta
		var s := sin((1.2 - shuffle_t) * TAU * 1.6)
		rotation.y += shuffle_dir * 0.3 * delta
		leg_l.rotation.x = max(0.0, s) * 0.2
		leg_r.rotation.x = max(0.0, -s) * 0.2
		if sign(prev) != sign(s):
			step.emit()


func _scream_anim(delta: float) -> void:
	# Rear up, throw the head back, arms flung wide, jaw hanging open.
	var k: float = min(1.0, lunge_t / (SCREAM_TIME * 0.5))
	var shake := sin(time * 60.0) * 0.04 * k
	torso.rotation.x = lerp(-0.35, 0.05, k)
	head.rotation = Vector3(0.6 * k + shake, shake, head_tilt * (1.0 - k))
	jaw.rotation.x = -0.3 - 0.75 * k
	arm_l.rotation = Vector3(lerp(reach_l, 0.7, k), 0, -0.7 * k)
	arm_r.rotation = Vector3(lerp(reach_r, 0.7, k), 0, 0.7 * k)
	fore_l.rotation.x = 0.6 * k
	fore_r.rotation.x = 0.6 * k
	body.rotation.z = 0.0
	_face(player.global_position, delta * 6.0)
	move_and_slide()


func _attack(delta: float, dist: float) -> void:
	attack_t += delta
	var raise: float = min(1.0, attack_t / WINDUP)
	# Swing: hunch forward, both arms reach out at the player, jaw gapes.
	arm_l.rotation = Vector3(lerp(reach_l, 1.25, raise), 0, 0)
	arm_r.rotation = Vector3(lerp(reach_r, 1.15, raise), 0, 0)
	fore_l.rotation.x = lerp(0.3, 0.1, raise)
	fore_r.rotation.x = lerp(0.3, 0.2, raise)
	jaw.rotation.x = -0.3 - 0.45 * raise
	torso.rotation.x = -0.35 - 0.25 * raise
	head.rotation.x = 0.25 * raise
	body.rotation.z = 0.0
	_face(player.global_position, delta * 3.0)
	if lunge_carry > 0.0 and dist > 0.8:
		# A lunge carries its momentum into the swing.
		var fwd := -global_transform.basis.z
		velocity.x = fwd.x * LUNGE_SPEED * lunge_carry * (1.0 - raise)
		velocity.z = fwd.z * LUNGE_SPEED * lunge_carry * (1.0 - raise)
	if attack_t >= WINDUP:
		attack_t = -1.0
		attack_cd = 1.2
		if dist < ATTACK_REACH and _can_see_player():
			attack_hit.emit(DAMAGE)
	move_and_slide()


func _walk(delta: float) -> void:
	var charging := is_lunging()
	var speed := LUNGE_SPEED if charging else SPEED
	var cadence := speed * (2.6 if charging else 2.2)

	# Every few seconds the shamble trips: a forward lurch with a sideways stagger,
	# arms flung out to catch itself, then it rights itself.
	var trip := 0.0
	if not charging:
		if stumble_t > 0.0:
			stumble_t -= delta
			trip = sin(PI * (1.0 - stumble_t / STUMBLE_TIME))
		else:
			stumble_next -= delta
			if stumble_next <= 0.0:
				stumble_t = STUMBLE_TIME
				stumble_next = randf_range(2.5, 6.0)
				stumble_dir = 1.0 if randf() < 0.5 else -1.0

	var to := last_seen - global_position
	to.y = 0.0
	walk_t += delta * cadence * (1.0 + trip * 0.6)
	if to.length() > 0.4:
		var d := to.normalized()
		var lurch: float = 0.7 + 0.6 * abs(sin(walk_t))
		var side := d.cross(Vector3.UP) * stumble_dir * trip * 0.7
		velocity.x = d.x * speed * lurch * (1.0 + trip * 0.3) + side.x
		velocity.z = d.z * speed * lurch * (1.0 + trip * 0.3) + side.z
		_face(last_seen, delta * (6.0 if charging else 4.0))
	move_and_slide()

	var prev := sin(walk_t - delta * cadence)
	var s := sin(walk_t)
	if sign(prev) != sign(s):
		step.emit()
	# Limping gait: the weak leg barely lifts and drags; knees bend on the back swing.
	var stride := 0.6 if charging else 0.45
	leg_l.rotation.x = s * stride * limp_l + trip * 0.3 * (1.0 if stumble_dir > 0 else 0.0)
	leg_r.rotation.x = -s * stride * limp_r + trip * 0.3 * (1.0 if stumble_dir < 0 else 0.0)
	shin_l.rotation.x = -0.1 - max(0.0, -s) * 0.8 * limp_l - trip * 0.4
	shin_r.rotation.x = -0.1 - max(0.0, s) * 0.8 * limp_r - trip * 0.4
	body.position.y = -abs(s) * 0.03 - trip * 0.06
	# Constant drunken roll, toward the dragging leg, plus the trip's sideways lean.
	body.rotation.z = sin(walk_t * 0.5) * 0.05 + (limp_l - limp_r) * 0.04 + stumble_dir * trip * 0.22
	torso.rotation.y = s * 0.12
	torso.rotation.z = s * 0.1 * (limp_l - limp_r + 0.5)
	head.rotation.z = head_tilt + sin(walk_t * 0.5) * 0.15 + twitch.z
	head.rotation.x = twitch.x
	if charging:
		# Lunge: bent low, both arms grabbing, jaw snapping.
		torso.rotation.x = -0.6
		head.rotation.x = 0.4
		head.rotation.z = head_tilt * 0.3
		arm_l.rotation = Vector3(1.35 + sin(walk_t * 2.0) * 0.12, 0, 0.1)
		arm_r.rotation = Vector3(1.3 - sin(walk_t * 2.0) * 0.12, 0, -0.1)
		fore_l.rotation.x = 0.15
		fore_r.rotation.x = 0.15
		jaw.rotation.x = -0.6 - 0.3 * abs(sin(time * 14.0))
	else:
		torso.rotation.x = -0.35 - trip * 0.4
		head.rotation.x += trip * 0.5
		arm_l.rotation = Vector3(reach_l + sin(walk_t * 0.5) * 0.12 + twitch_arm - trip * 0.6, 0, -trip * 0.9)
		arm_r.rotation = Vector3(reach_r - sin(walk_t * 0.5 + 0.7) * 0.15 - trip * 0.4, 0, trip * 0.9)
		fore_l.rotation.x = 0.3 + sin(walk_t) * 0.1 + trip * 0.5
		fore_r.rotation.x = 0.3 - sin(walk_t) * 0.1 + trip * 0.5
		jaw.rotation.x = -0.3 - 0.15 * abs(sin(time * 6.0))
	if coat_l:
		coat_l.rotation.x = leg_l.rotation.x * 0.7
		coat_r.rotation.x = leg_r.rotation.x * 0.7
		coat_b.rotation.x = -abs(s) * 0.2 - (0.3 if charging else 0.0)

	groan_timer -= delta
	if groan_timer <= 0.0:
		groan_timer = randf_range(4.0, 8.0)
		groan.emit()


func _face(target: Vector3, weight: float) -> void:
	var d := target - global_position
	rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.z), min(1.0, weight))


func _flat_dist(p: Vector3) -> float:
	return Vector2(p.x - global_position.x, p.z - global_position.z).length()


func _detects() -> bool:
	var dist := _flat_dist(player.global_position)
	if dist < HEAR:
		return true
	if dist > SIGHT:
		return false
	var fwd := -global_transform.basis.z
	var to := (player.global_position - global_position).normalized()
	return fwd.dot(to) > 0.2 and _can_see_player()


func _can_see_player() -> bool:
	# Body-width line of sight: three parallel rays, so "seeing" through a gap
	# the zombie can't actually fit through still counts as blocked.
	var from := global_position + Vector3(0, 1.0, 0)
	var to := player.global_position + Vector3(0, 1.0, 0)
	var side := (to - from).cross(Vector3.UP).normalized() * 0.32
	var space := get_world_3d().direct_space_state
	for off in [Vector3.ZERO, side, -side]:
		var q := PhysicsRayQueryParameters3D.create(from + off, to + off)
		q.exclude = [get_rid(), (player as CollisionObject3D).get_rid()]
		if not space.intersect_ray(q).is_empty():
			return false
	return true
