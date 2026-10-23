extends CharacterBody3D
## First-person survivor: movement, flashlight, health and a USP handgun viewmodel with
## a magazine, a chambered round, a locking slide and animated empty/tactical reloads.

signal footstep
signal fired(hit: Dictionary)
signal reloaded
## Gun foley cue: "dry_fire", "mag_out", "mag_in", "slide_rack". Reload cues are emitted
## `sound_leads[cue]` seconds before their animation beat so the recorded click lands on it.
signal gun_sound(cue: String)

const WALK := 2.6
const RUN := 4.4
const SENS := 0.0022
const EYE := 1.6
const MAX_HEALTH := 100

# --- Handgun tuning -------------------------------------------------------------------
const MAG_SIZE := 15
const FIRE_DELAY := 0.3
const FLASH_TIME := 0.05  # muzzle flash sprite + light, seconds
const ANIM_FPS := 15.0  # reload/recoil poses step at this rate for stiff PS1-style motion
# Reload timelines (seconds): when the magazine leaves, when the new one seats, when the
# slide drops (empty reload only), and the total length. Scale these to change reload speed.
const EMPTY_RELOAD := {"len": 1.6, "out": 0.25, "in": 0.85, "slide": 1.1}
const TACTICAL_RELOAD := {"len": 1.3, "out": 0.25, "in": 0.8}
# ---------------------------------------------------------------------------------------

const GUN_REST := Vector3(0.17, -0.16, -0.34)
const GUN_REST_ROT := Vector3(0.0, 0.4, 0.0)  # turned in so its right side shows
const RELOAD_POS := Vector3(0.05, -0.03, -0.3)  # raised and side-on so the mag swap is visible
const RELOAD_ROT := Vector3(0.05, 1.3, -0.3)
const GUN_SCENE := preload("res://assets/models/usp/pistols_pack.fbx")
const GUN_TEX := preload("res://assets/models/usp/usp_tex.jpg")
const MAG_TEX := preload("res://assets/models/usp/usp_mag_tex.jpg")
const ROUND_TEX := preload("res://assets/models/usp/9mm_tex.jpg")
const PS1_SHADER := preload("res://shaders/ps1.gdshader")
const GUN_SCALE := 0.09  # pack units -> metres (the USP is ~2.1 units long)
const MODEL_CENTER := Vector3(-0.05, 5.3, 0.0)  # USP bore line in the pack's coordinates
const MUZZLE := Vector3(1.06, 0.0, 0.0)  # barrel tip, model space after centring
const MAG_AXIS := Vector3(0.485, 0.874, 0.0)  # up the raked grip, model space
const SLIDE_TRAVEL := 0.32
const GUN_LAYER := 1 << 19  # viewmodel-only fill light uses this render layer
const ROUND_MATS := ["Material.016", "Material.018", "Material.019", "Material.031", "Material.035"]
const MAG_MATS := ["Material.027", "Material.033", "Material.034"]

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
var mag := MAG_SIZE  # rounds in the magazine
var chambered := true  # a round in the chamber (the gun can fire)
var reserve := 0
var reloading := 0.0  # seconds of reload left (0 = not reloading)
var reload_t := 0.0
var reload_plan := {}
var reload_empty := false
var sound_leads := {}
var fire_cd := 0.0
var kick := 0.0
var flash_t := 0.0
var shake := 0.0
var slide_t := 0.0  # slide cycling back-and-forward after a shot
var slide_locked := false
var gun_time := 0.0
var bob_amt := 0.0
var gun: Node3D
var model: Node3D
var slide: Node3D
var mag_empty: Node3D  # magazine meshes: empty (no rounds showing) and full
var mag_full: Node3D
var mag_new: Node3D  # the fresh magazine coming up during a reload
var muzzle_flash: MeshInstance3D
var muzzle_light: OmniLight3D
var slide_rest := Vector3.ZERO
var mag_rest := Vector3.ZERO

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


## Swaps in the USP from the PSX Pistol Pack as the first-person viewmodel.
func build_gun() -> void:
	gun = Node3D.new()
	gun.position = GUN_REST
	gun.rotation = GUN_REST_ROT
	cam.add_child(gun)
	model = make_usp()
	gun.add_child(model)
	slide = model.get_meta("slide")
	mag_empty = model.get_meta("mag_empty")
	mag_full = model.get_meta("mag_full")
	mag_new = mag_full.duplicate()
	model.add_child(mag_new)
	mag_new.visible = false
	slide_rest = slide.position
	mag_rest = mag_empty.position

	# The flashlight cone misses the gun, so a weak fill lights the viewmodel only.
	var fill := OmniLight3D.new()
	fill.position = Vector3(-0.1, 0.15, 0.05)
	fill.omni_range = 0.8
	fill.light_energy = 0.6
	fill.light_color = Color(0.8, 0.8, 0.85)
	fill.light_cull_mask = GUN_LAYER
	gun.add_child(fill)

	var tip: Vector3 = model.transform * MUZZLE
	muzzle_flash = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.1, 0.1)
	muzzle_flash.mesh = quad
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	fm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	fm.albedo_texture = _flash_texture()
	muzzle_flash.material_override = fm
	muzzle_flash.position = tip + Vector3(0, 0, -0.03)
	muzzle_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	muzzle_flash.layers = GUN_LAYER
	muzzle_flash.visible = false
	gun.add_child(muzzle_flash)
	muzzle_light = OmniLight3D.new()
	muzzle_light.position = tip + Vector3(0, 0, -0.1)
	muzzle_light.light_color = Color(1.0, 0.7, 0.35)
	muzzle_light.omni_range = 7.0
	muzzle_light.light_energy = 0.0
	gun.add_child(muzzle_light)


## The USP from the PSX Pistol Pack, centred on its bore, pointing down -Z, in PS1 materials.
## The slide and magazines are tagged as metadata ("slide", "mag_empty", "mag_full").
## Also used for the item-screen preview.
static func make_usp() -> Node3D:
	var usp := Node3D.new()
	usp.rotation.y = PI / 2  # the pack's guns point down +X
	usp.scale = Vector3.ONE * GUN_SCALE
	# The pack file holds four pistols; keep only the USP's parts.
	var src := GUN_SCENE.instantiate()
	var parts := {}
	for part in ["USPBody", "USPSlide", "USPTrigger&Hammer", "USPMag", "USPMagFull"]:
		var mi: MeshInstance3D = src.find_child(part, true, false)
		mi.get_parent().remove_child(mi)
		mi.owner = null
		usp.add_child(mi)
		mi.position -= MODEL_CENTER
		_ps1_materials(mi)
		parts[part] = mi
	src.free()
	parts.USPMagFull.transform = parts.USPMag.transform  # the pack lays the full mag out beside the gun
	parts.USPMag.visible = false
	usp.set_meta("slide", parts.USPSlide)
	usp.set_meta("mag_empty", parts.USPMag)
	usp.set_meta("mag_full", parts.USPMagFull)
	return usp


## Re-skins an imported part with the game's PS1 shader (vertex snap + affine UVs,
## nearest-neighbour texels), picking the texture from the pack's material names.
static func _ps1_materials(mi: MeshInstance3D) -> void:
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # it sits in front of the flashlight
	mi.layers = GUN_LAYER | 1
	for i in mi.mesh.get_surface_count():
		var src_mat := mi.mesh.surface_get_material(i)
		var name := src_mat.resource_name if src_mat else ""
		var m := ShaderMaterial.new()
		m.shader = PS1_SHADER
		m.set_shader_parameter("albedo_tex", ROUND_TEX if name in ROUND_MATS else (MAG_TEX if name in MAG_MATS else GUN_TEX))
		m.set_shader_parameter("tint", Color(0.75, 0.75, 0.75))
		mi.set_surface_override_material(i, m)


## 32x32 chunky muzzle burst: uneven spikes, white-hot core fading to yellow and orange.
func _flash_texture() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var spikes := [1.0, 0.55, 0.85, 0.5, 0.95, 0.6, 0.8, 0.45]
	for y in 32:
		for x in 32:
			# Sample on a 16x16 grid so every texel is a 2x2 block.
			var p := Vector2(int(x / 2) - 7.5, int(y / 2) - 7.5) / 8.0
			var a := fposmod(p.angle(), TAU) / TAU * 8.0
			var i := int(a)
			var f := a - i
			var spike: float = lerp(spikes[i], spikes[(i + 1) % 8], 0.5)
			var reach: float = 0.35 + spike * 0.65 * pow(abs(1.0 - 2.0 * f), 3.0)
			var r := p.length() / maxf(reach, 0.3)
			var c := Color(0, 0, 0, 0)
			if r < 0.35:
				c = Color(1.0, 1.0, 0.9)
			elif r < 0.65:
				c = Color(1.0, 0.85, 0.3)
			elif r < 1.0:
				c = Color(1.0, 0.5, 0.1)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func look(rel: Vector2) -> void:
	rotation.y -= rel.x * SENS
	cam.rotation.x = clamp(cam.rotation.x - rel.y * SENS, -1.45, 1.45)


func toggle_flashlight() -> void:
	light_on = not light_on
	flashlight.visible = light_on


func rounds() -> int:
	return mag + (1 if chambered else 0)


## Returns 0 = fired, 1 = empty (dry fire), 2 = busy (cooling down / reloading).
func try_fire() -> int:
	if not enabled or reloading > 0.0 or fire_cd > 0.0:
		return 2
	if not chambered:
		fire_cd = 0.25
		gun_sound.emit("dry_fire")
		return 1
	# The shot cycles the slide: it chambers the next round, or locks back on an empty mag.
	chambered = mag > 0
	if chambered:
		mag -= 1
		slide_t = 1.0
	else:
		slide_locked = true
	fire_cd = FIRE_DELAY
	kick = 1.0
	flash_t = FLASH_TIME
	muzzle_flash.rotation.z = randf() * TAU
	var from := cam.global_position
	var spread := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.008
	var dir := (-cam.global_transform.basis.z + spread).normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 40.0)
	q.exclude = [get_rid()]
	fired.emit(get_world_3d().direct_space_state.intersect_ray(q))
	return 0


## Empty gun: drop the mag, seat a new one, release the slide. Rounds still in the gun:
## swap the magazine only (the chambered round stays). Nothing to do without spare
## ammo or when already full.
func start_reload() -> bool:
	if reloading > 0.0 or reserve <= 0 or (chambered and mag >= MAG_SIZE):
		return false
	reload_empty = not chambered
	reload_plan = EMPTY_RELOAD if reload_empty else TACTICAL_RELOAD
	reload_t = 0.0
	reloading = reload_plan.len
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
		_step_reload(delta)
	if gun == null:
		return
	gun_time += delta
	kick = max(0.0, kick - delta * 7.0)
	slide_t = max(0.0, slide_t - delta * 12.0)
	flash_t -= delta
	muzzle_flash.visible = flash_t > 0.0
	muzzle_light.light_energy = 5.0 if flash_t > 0.0 else 0.0

	# Idle sway always; walk bob fades in with speed.
	var hs := Vector2(velocity.x, velocity.z).length()
	bob_amt = move_toward(bob_amt, clamp(hs / WALK, 0.0, 1.5), delta * 4.0)
	var sway := Vector3(sin(gun_time * 1.1) * 0.004, sin(gun_time * 1.7) * 0.003, 0.0)
	var bob := Vector3(cos(bob_t) * 0.012, -abs(sin(bob_t)) * 0.014, 0.0) * bob_amt
	# Recoil steps rather than glides, like a low-framerate PS1 animation.
	var k := _stepped(kick)
	gun.position = GUN_REST + sway + bob + Vector3(0, k * 0.01, k * 0.04)
	gun.rotation = GUN_REST_ROT + Vector3(k * 0.15 + sin(gun_time * 0.8) * 0.01, 0.0, 0.0)

	var slide_back := 1.0 if slide_locked else _stepped(slide_t)
	if slide_locked and reloading > 0.0 and reload_plan.has("slide") and reload_t > reload_plan.slide - 0.16:
		slide_back = 1.15  # hand racks it the last bit back before letting it fly forward
	slide.position = slide_rest + Vector3(-SLIDE_TRAVEL * slide_back, 0, 0)
	if reloading > 0.0:
		_pose_reload()
	else:
		mag_new.visible = false
		mag_empty.visible = mag == 0
		mag_full.visible = mag > 0
		mag_empty.position = mag_rest
		mag_full.position = mag_rest


func _stepped(v: float) -> float:
	return round(v * 4.0) / 4.0


func _step_reload(delta: float) -> void:
	var prev := reload_t
	reload_t += delta
	var crossed := func(at: float) -> bool: return prev < at and reload_t >= at
	var cues := {"mag_out": reload_plan.out, "mag_in": reload_plan["in"]}
	if reload_plan.has("slide"):
		cues["slide_rack"] = reload_plan.slide
	for cue in cues:
		if crossed.call(maxf(0.0, cues[cue] - sound_leads.get(cue, 0.0))):
			gun_sound.emit(cue)
	if crossed.call(reload_plan.out):
		reserve += mag  # rounds left in the old magazine go back in the pocket
		mag = 0
	if crossed.call(reload_plan["in"]):
		mag = min(MAG_SIZE, reserve)
		reserve -= mag
		kick = max(kick, 0.25)
	if reload_plan.has("slide") and crossed.call(reload_plan.slide):
		slide_locked = false
		chambered = mag > 0
		if chambered:
			mag -= 1
		kick = max(kick, 0.5)
	reloading = max(0.0, reload_plan.len - reload_t)
	if reloading <= 0.0:
		reloaded.emit()


## Reload pose, sampled at ANIM_FPS: cant the gun, drop the old magazine out of the
## grip, push the new one up until it seats.
func _pose_reload() -> void:
	var t: float = floor(reload_t * ANIM_FPS) / ANIM_FPS
	var p := reload_plan
	var tilt: float = clamp(t / 0.2, 0.0, 1.0) * clamp((p.len - t) / 0.3, 0.0, 1.0)
	tilt = smoothstep(0.0, 1.0, tilt)
	gun.position += (RELOAD_POS - GUN_REST) * tilt
	gun.rotation += (RELOAD_ROT - GUN_REST_ROT) * tilt

	var old := mag_empty if reload_empty else mag_full
	var other := mag_full if reload_empty else mag_empty
	other.visible = false
	if t < p.out:
		old.visible = true
		old.position = mag_rest
	else:
		var ft: float = t - p.out
		old.visible = ft < 0.4
		old.position = mag_rest - MAG_AXIS * (ft * 3.0 + 40.0 * ft * ft)
	var rise: float = clamp((t - (p["in"] - 0.35)) / 0.35, 0.0, 1.0)
	mag_new.visible = t >= p["in"] - 0.35
	mag_new.position = mag_rest - MAG_AXIS * 2.2 * (1.0 - rise) * (1.0 - rise)
	if t >= p["in"]:
		# The new magazine is now the gun's magazine.
		mag_new.visible = false
		mag_full.visible = mag > 0
		mag_empty.visible = mag == 0
		mag_full.position = mag_rest
		mag_empty.position = mag_rest
