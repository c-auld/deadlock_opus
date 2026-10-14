extends CharacterBody3D
## Slow but dangerous zombie. Sleeps (or lies "dead") until it sees or hears the
## player, shambles after them, swings at close range, searches the last place it
## saw them and gives up if it loses them. Killable with the handgun.

signal step
signal groan
signal attack_hit(damage: int)
signal died

enum { DORMANT, LYING, IDLE, CHASE, SEARCH, DEAD }

const MAX_HP := 5
const SPEED := 1.3
const SIGHT := 9.0
const HEAR := 3.0
const ATTACK_START := 1.3
const ATTACK_REACH := 1.8
const WINDUP := 0.55
const DAMAGE := 25

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

# Per-zombie variation: one arm reaches, the other hangs; one leg drags.
var reach_l := 1.15
var reach_r := 0.25
var limp_l := 1.0
var limp_r := 0.55
var head_tilt := 0.35


func build(skin: Material, shirt: Material, pants: Material, eye: Material,
		dark: Material, blood: Material, bone: Material) -> void:
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

	body = _pivot(self, Vector3.ZERO)
	body.scale = Vector3.ONE * randf_range(0.95, 1.06)

	# Pelvis + legs.
	_limb(body, Vector3(0, 1.0, 0), 0.16, 0.15, 0.14, pants, Vector3(1, 1, 0.7))
	leg_l = _pivot(body, Vector3(-0.09, 0.88, 0))
	leg_r = _pivot(body, Vector3(0.09, 0.88, 0))
	for leg in [leg_l, leg_r]:
		_limb(leg, Vector3(0, -0.22, 0), 0.44, 0.075, 0.058, pants)
		var knee := _pivot(leg, Vector3(0, -0.44, 0))
		_ball(knee, Vector3.ZERO, 0.058, pants)
		_limb(knee, Vector3(0, -0.21, 0), 0.42, 0.056, 0.042, pants)
		_box(knee, Vector3(0, -0.44, -0.04), Vector3(0.09, 0.06, 0.2), dark)
		if leg == leg_l:
			shin_l = knee
		else:
			shin_r = knee

	# Hunched torso: exposed belly, ribcage in a torn shirt.
	torso = _pivot(body, Vector3(0, 1.0, 0))
	torso.rotation.x = -0.35
	_limb(torso, Vector3(0, 0.1, 0), 0.2, 0.135, 0.145, skin, Vector3(1, 1, 0.72))
	_limb(torso, Vector3(0, 0.38, 0), 0.4, 0.21, 0.16, shirt, Vector3(1, 1, 0.62))
	_box(torso, Vector3(0.07, 0.15, -0.105), Vector3(0.12, 0.16, 0.012), shirt).rotation.z = 0.3
	_box(torso, Vector3(-0.07, 0.34, -0.13), Vector3(0.07, 0.1, 0.012), blood).rotation.z = 0.5
	_box(torso, Vector3(0.04, 0.08, -0.105), Vector3(0.07, 0.05, 0.012), blood)

	# Arms: shirt sleeve on one side, torn off on the other. Elbows bend, hands are claws.
	arm_l = _pivot(torso, Vector3(-0.22, 0.52, 0))
	arm_r = _pivot(torso, Vector3(0.22, 0.52, 0))
	for arm in [arm_l, arm_r]:
		_ball(arm, Vector3.ZERO, 0.07, shirt)
		_limb(arm, Vector3(0, -0.15, 0), 0.3, 0.05, 0.042, shirt if arm == arm_l else skin)
		var elbow := _pivot(arm, Vector3(0, -0.3, 0))
		_ball(elbow, Vector3.ZERO, 0.043, skin)
		_limb(elbow, Vector3(0, -0.135, 0), 0.27, 0.042, 0.032, skin)
		_ball(elbow, Vector3(0, -0.3, 0), 0.045, skin, Vector3(0.6, 1.2, 1.0))
		for f in 3:
			var finger := _limb(elbow, Vector3(-0.02 + f * 0.02, -0.37, -0.01), 0.1, 0.009, 0.005, skin)
			finger.rotation.x = 0.35
		if arm == arm_l:
			fore_l = elbow
		else:
			fore_r = elbow

	# Neck + skull: sunken sockets with pin-prick eyes, hanging jaw, matted hair.
	head = _pivot(torso, Vector3(0, 0.58, -0.02))
	_limb(head, Vector3(0, 0.03, 0), 0.12, 0.045, 0.05, skin)
	_ball(head, Vector3(0, 0.15, 0), 0.115, skin, Vector3(0.95, 1.2, 1.1))
	_ball(head, Vector3(0.02, 0.23, 0.03), 0.105, dark, Vector3(1.0, 0.55, 1.0))
	for side in [-1.0, 1.0]:
		_ball(head, Vector3(0.045 * side, 0.165, -0.098), 0.032, dark)
		_box(head, Vector3(0.045 * side, 0.163, -0.118), Vector3(0.014, 0.012, 0.01), eye)
	_box(head, Vector3(0, 0.07, -0.102), Vector3(0.08, 0.05, 0.02), dark)
	_box(head, Vector3(0, 0.088, -0.112), Vector3(0.07, 0.014, 0.01), bone)
	_box(head, Vector3(0.06, 0.12, -0.105), Vector3(0.04, 0.05, 0.012), blood)
	jaw = _pivot(head, Vector3(0, 0.075, -0.02))
	_box(jaw, Vector3(0, -0.02, -0.05), Vector3(0.11, 0.035, 0.1), skin)
	_box(jaw, Vector3(0, 0.0, -0.093), Vector3(0.07, 0.014, 0.01), bone)

	_pose_idle()


func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, scl := Vector3.ONE) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = pos
	m.scale = scl
	parent.add_child(m)
	return m


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
	arm_l.rotation.x = reach_l * 0.5
	arm_r.rotation.x = reach_r * 0.5
	fore_l.rotation.x = 0.3
	fore_r.rotation.x = 0.3
	shin_l.rotation.x = -0.1
	shin_r.rotation.x = -0.1
	head.rotation.z = head_tilt
	jaw.rotation.x = -0.3


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
	if not is_hostile():
		_start_chase()
	if hp <= 0:
		_die()


func _start_chase() -> void:
	mode = CHASE
	last_seen = player.global_position
	groan.emit()


func _die() -> void:
	mode = DEAD
	col.set_deferred("disabled", true)
	jaw.rotation.x = -0.6
	var tw := create_tween()
	tw.tween_property(body, "rotation:x", PI / 2, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(body, "position:y", 0.15, 0.6)
	tw.parallel().tween_property(arm_l, "rotation:x", 0.6, 0.6)
	tw.parallel().tween_property(arm_r, "rotation:x", -0.2, 0.6)
	died.emit()


func _physics_process(delta: float) -> void:
	time += delta
	match mode:
		DEAD, LYING:
			return
		DORMANT, IDLE:
			# Swaying on the spot, head lolling, jaw working, the odd twitch.
			head.rotation.z = head_tilt + sin(time * 0.7) * 0.2 + (randf_range(-0.5, 0.5) if randf() < 0.02 else 0.0)
			jaw.rotation.x = -0.3 - 0.1 * sin(time * 2.3)
			torso.rotation.z = sin(time * 0.5) * 0.06
			if _detects():
				_start_chase()
			return

	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = -0.1 if is_on_floor() else velocity.y - 18.0 * delta
	attack_cd = max(0.0, attack_cd - delta)
	var dist := _flat_dist(player.global_position)

	if stagger > 0.0:
		stagger -= delta
		torso.rotation.x = -0.35 + 0.6 * stagger
		head.rotation.x = 0.5 * stagger
		move_and_slide()
		return
	torso.rotation.x = -0.35
	head.rotation.x = 0.0

	if attack_t >= 0.0:
		attack_t += delta
		var raise: float = min(1.0, attack_t / WINDUP)
		# Lunge: hunch forward, both arms reach out at the player, jaw gapes.
		arm_l.rotation.x = lerp(reach_l, 1.25, raise)
		arm_r.rotation.x = lerp(reach_r, 1.15, raise)
		fore_l.rotation.x = lerp(0.3, 0.1, raise)
		fore_r.rotation.x = lerp(0.3, 0.2, raise)
		jaw.rotation.x = -0.3 - 0.45 * raise
		torso.rotation.x = -0.35 - 0.25 * raise
		head.rotation.x = 0.25 * raise
		_face(player.global_position, delta * 3.0)
		if attack_t >= WINDUP:
			attack_t = -1.0
			attack_cd = 1.2
			if dist < ATTACK_REACH and _can_see_player():
				attack_hit.emit(DAMAGE)
		move_and_slide()
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
			_pose_idle()
			return

	if sees and dist < ATTACK_START and attack_cd <= 0.0:
		attack_t = 0.0
		groan.emit()
		return

	var to := last_seen - global_position
	to.y = 0.0
	walk_t += delta * SPEED * 2.2
	if to.length() > 0.4:
		var d := to.normalized()
		var lurch: float = 0.7 + 0.6 * abs(sin(walk_t))
		velocity.x = d.x * SPEED * lurch
		velocity.z = d.z * SPEED * lurch
		_face(last_seen, delta * 4.0)
	move_and_slide()

	var prev := sin(walk_t - delta * SPEED * 2.2)
	var s := sin(walk_t)
	if sign(prev) != sign(s):
		step.emit()
	# Limping gait: the weak leg barely lifts and drags; knees bend on the back swing.
	leg_l.rotation.x = s * 0.45 * limp_l
	leg_r.rotation.x = -s * 0.45 * limp_r
	shin_l.rotation.x = -0.1 - max(0.0, -s) * 0.8 * limp_l
	shin_r.rotation.x = -0.1 - max(0.0, s) * 0.8 * limp_r
	body.position.y = -abs(s) * 0.03
	arm_l.rotation.x = reach_l + sin(walk_t * 0.5) * 0.12
	arm_r.rotation.x = reach_r - sin(walk_t * 0.5 + 0.7) * 0.15
	fore_l.rotation.x = 0.3 + sin(walk_t) * 0.1
	fore_r.rotation.x = 0.3 - sin(walk_t) * 0.1
	torso.rotation.z = s * 0.1 * (limp_l - limp_r + 0.5)
	head.rotation.z = head_tilt + sin(walk_t * 0.5) * 0.15
	jaw.rotation.x = -0.3 - 0.15 * abs(sin(time * 6.0))

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
