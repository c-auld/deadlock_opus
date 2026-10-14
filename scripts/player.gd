extends CharacterBody3D
## First-person survivor: movement, flashlight, health and a handgun with a magazine.

signal footstep
signal fired(hit: Dictionary)
signal reloaded

const WALK := 2.6
const RUN := 4.4
const SENS := 0.0022
const EYE := 1.6
const MAX_HEALTH := 100
const MAG_SIZE := 8
const RELOAD_TIME := 1.4
const FIRE_DELAY := 0.3
const GUN_REST := Vector3(0.17, -0.16, -0.44)

var cam: Camera3D
var flashlight: SpotLight3D
var enabled := true
var stamina := 1.0
var bob_t := 0.0
var last_step := 0
var light_on := true
var flicker_t := 6.0
var flicker_burst := 0.0

var health := MAX_HEALTH
var mag := MAG_SIZE
var reserve := 0
var reloading := 0.0
var fire_cd := 0.0
var kick := 0.0
var flash_t := 0.0
var shake := 0.0
var gun: Node3D
var muzzle_flash: MeshInstance3D
var muzzle_light: OmniLight3D


func _ready() -> void:
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.75
	col.shape = cap
	col.position.y = 0.875
	add_child(col)

	cam = Camera3D.new()
	cam.position.y = EYE
	cam.fov = 70.0
	cam.near = 0.05
	cam.far = 60.0
	cam.current = true
	add_child(cam)

	flashlight = SpotLight3D.new()
	flashlight.position = Vector3(-0.15, -0.1, 0.0)  # left hand, so it doesn't glare off the gun
	flashlight.light_color = Color(1.0, 0.9, 0.72)
	flashlight.light_energy = 3.0
	flashlight.spot_range = 15.0
	flashlight.spot_angle = 24.0
	flashlight.shadow_enabled = true
	cam.add_child(flashlight)


func build_gun(metal: Material, flash: Material) -> void:
	gun = Node3D.new()
	gun.position = GUN_REST
	cam.add_child(gun)
	_gun_part(Vector3(0, 0, -0.08), Vector3(0.05, 0.065, 0.22), metal)
	_gun_part(Vector3(0, -0.07, 0.03), Vector3(0.045, 0.11, 0.06), metal).rotation.x = 0.25
	muzzle_flash = _gun_part(Vector3(0, 0.0, -0.22), Vector3(0.06, 0.06, 0.03), flash)
	muzzle_flash.visible = false
	muzzle_light = OmniLight3D.new()
	muzzle_light.position = Vector3(0, 0, -0.35)
	muzzle_light.light_color = Color(1.0, 0.75, 0.4)
	muzzle_light.omni_range = 7.0
	muzzle_light.light_energy = 0.0
	gun.add_child(muzzle_light)


func _gun_part(pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = mat
	m.position = pos
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # it sits in front of the flashlight
	gun.add_child(m)
	return m


func look(rel: Vector2) -> void:
	rotation.y -= rel.x * SENS
	cam.rotation.x = clamp(cam.rotation.x - rel.y * SENS, -1.45, 1.45)


func toggle_flashlight() -> void:
	light_on = not light_on
	flashlight.visible = light_on


## Returns 0 = fired, 1 = empty (dry click), 2 = busy (cooling down / reloading).
func try_fire() -> int:
	if not enabled or reloading > 0.0 or fire_cd > 0.0:
		return 2
	if mag <= 0:
		fire_cd = 0.25
		return 1
	mag -= 1
	fire_cd = FIRE_DELAY
	kick = 1.0
	flash_t = 0.05
	var from := cam.global_position
	var spread := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.008
	var dir := (-cam.global_transform.basis.z + spread).normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 40.0)
	q.exclude = [get_rid()]
	fired.emit(get_world_3d().direct_space_state.intersect_ray(q))
	return 0


func start_reload() -> bool:
	if reloading > 0.0 or mag >= MAG_SIZE or reserve <= 0:
		return false
	reloading = RELOAD_TIME
	return true


func take_damage(amount: int, from: Vector3) -> void:
	health = max(0, health - amount)
	shake = 0.5
	var push := global_position - from
	push.y = 0.0
	velocity += push.normalized() * 3.0


func heal(amount: int) -> void:
	health = min(MAX_HEALTH, health + amount)


func _physics_process(delta: float) -> void:
	var input := Vector2.ZERO
	if enabled:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := global_transform.basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0

	var running := enabled and Input.is_action_pressed("sprint") and input.length() > 0.1 and stamina > 0.05
	stamina = clamp(stamina + (-delta / 3.5 if running else delta / 6.0), 0.0, 1.0)
	var speed := RUN if running else WALK

	var k: float = min(1.0, 12.0 * delta)
	velocity.x = lerp(velocity.x, dir.x * speed, k)
	velocity.z = lerp(velocity.z, dir.z * speed, k)
	if is_on_floor():
		velocity.y = -0.1
	else:
		velocity.y -= 18.0 * delta
	move_and_slide()

	if enabled:
		var hs := Vector2(velocity.x, velocity.z).length()
		if hs > 0.3:
			bob_t += delta * hs * 2.6
			var idx := int(bob_t / PI)
			if idx != last_step:
				last_step = idx
				footstep.emit()
		cam.position.y = EYE - 0.05 * abs(sin(bob_t))
		cam.position.x = cos(bob_t) * 0.03
		cam.rotation.z = randf_range(-1.0, 1.0) * shake * 0.06
	shake = max(0.0, shake - delta * 1.5)

	_update_gun(delta)

	# The battery is dying: occasional flicker bursts.
	flicker_t -= delta
	if flicker_t <= 0.0:
		flicker_t = randf_range(5.0, 14.0)
		flicker_burst = randf_range(0.2, 0.6)
	if flicker_burst > 0.0:
		flicker_burst -= delta
		flashlight.light_energy = 3.0 if randf() > 0.5 else 0.25
	else:
		flashlight.light_energy = 3.0


func _update_gun(delta: float) -> void:
	fire_cd = max(0.0, fire_cd - delta)
	if reloading > 0.0:
		reloading -= delta
		if reloading <= 0.0:
			reloading = 0.0
			var n: int = min(MAG_SIZE - mag, reserve)
			mag += n
			reserve -= n
			reloaded.emit()
	if gun == null:
		return
	kick = max(0.0, kick - delta * 6.0)
	flash_t -= delta
	muzzle_flash.visible = flash_t > 0.0
	muzzle_light.light_energy = 4.0 if flash_t > 0.0 else 0.0
	var dip := sin(PI * (1.0 - reloading / RELOAD_TIME)) if reloading > 0.0 else 0.0
	gun.position = GUN_REST + Vector3(cos(bob_t) * 0.01, -abs(sin(bob_t)) * 0.01 - dip * 0.12, kick * 0.05)
	gun.rotation.x = kick * 0.35 - dip * 0.9
