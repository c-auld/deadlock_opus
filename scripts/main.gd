extends Node
## Builds the whole prototype in code: low-res viewport, corridor level, player,
## zombies, pickups, locked exit and UI. Owns the game state (play / inventory / won / lost).

const PS1_SHADER := preload("res://shaders/ps1.gdshader")
const POST_SHADER := preload("res://shaders/post.gdshader")
const Player := preload("res://scripts/player.gd")
const Zombie := preload("res://scripts/zombie.gd")
const Sfx := preload("res://scripts/sfx.gd")
const AMMO_BOX := preload("res://assets/models/ammo_9mm/ammo_9mm.fbx")
const AMMO_BOX_TEX := preload("res://assets/models/ammo_9mm/ammo_9mm_tex.png")
const AMMO_BOX_LENGTH := 0.28  # metres, longest side
const MEDKIT := preload("res://assets/models/medkit/medkit.glb")
const MEDKIT_TEX := preload("res://assets/models/medkit/medkit_T_Med_Kit_1.png")
const MEDKIT_LENGTH := 0.3  # metres, longest side
# Pickup hop (ammo, first aid kits, keycard): height (m), hops per second, spin (rad/s), and the frame rate the motion
# is stepped at for a choppy PSX look.
const PICKUP_HOP := 0.14
const PICKUP_HOP_RATE := 1.3
const PICKUP_SPIN := 1.5
const PICKUP_ANIM_FPS := 12.0

const H := 3.0
const TERMINAL_POS := Vector3(24.0, 1.2, -36.4)
const DOOR_POS := Vector3(28.0, 1.5, -31.5)
const EXIT_X := 31.0
const HEAL_AMOUNT := 60  # First Aid Kit carried in the item screen
const MEDKIT_HEAL := 50  # walk-over med kits, applied instantly
const MEDKIT_GLOW := 0.25  # med kit self-glow (0 = none, 1 = fully lit)
const MEDKIT_REACH := 0.6  # how close (m) you walk to grab a med kit
const START_MAG := 9  # plus one in the chamber
const NOISE_RADIUS := 14.0
const INV_SLOTS := 6

# Floor/ceiling rectangles in the XZ plane: corridor A, corridor B, door room, exit, closet, storage.
const RECTS := [
	Rect2(-1.5, -33.0, 3.0, 35.0),
	Rect2(1.5, -33.0, 18.5, 3.0),
	Rect2(20.0, -37.0, 8.0, 11.0),
	Rect2(28.0, -32.5, 6.0, 2.0),
	Rect2(-4.0, -8.0, 2.5, 2.0),
	Rect2(8.0, -30.0, 6.0, 6.0),
]
# Wall segments [x1, z1, x2, z2].
const WALLS := [
	[-1.5, 2.0, -1.5, -6.0], [-1.5, -8.0, -1.5, -33.0],
	[-4.0, -6.0, -1.5, -6.0], [-4.0, -8.0, -1.5, -8.0], [-4.0, -8.0, -4.0, -6.0],
	[1.5, 2.0, 1.5, -30.0], [-1.5, 2.0, 1.5, 2.0],
	[-1.5, -33.0, 20.0, -33.0], [1.5, -30.0, 10.0, -30.0], [12.0, -30.0, 20.0, -30.0],
	[8.0, -30.0, 8.0, -24.0], [14.0, -30.0, 14.0, -24.0], [8.0, -24.0, 14.0, -24.0],
	[20.0, -37.0, 20.0, -33.0], [20.0, -30.0, 20.0, -26.0],
	[20.0, -26.0, 28.0, -26.0], [20.0, -37.0, 28.0, -37.0],
	[28.0, -37.0, 28.0, -32.5], [28.0, -30.5, 28.0, -26.0],
	[28.0, -32.5, 34.0, -32.5], [28.0, -30.5, 34.0, -30.5], [34.0, -32.5, 34.0, -30.5],
]
const ITEM_NAMES := {
	"handgun": "Handgun", "ammo": "Handgun Ammo", "heal": "First Aid Kit", "key": "Exit Keycard",
}
const ITEM_DESC := {
	"handgun": "9mm USP. 15-round magazine.\n[LMB] fire   [R] reload\nAim for the head.",
	"ammo": "Spare 9mm rounds.\nUse to reload the handgun now.",
	"heal": "First aid kit.\nRestores a large amount of health.",
	"key": "Keycard marked EXIT.\nUse it at the security door,\nor press [E] at the door.",
}
const TERMINAL_LOG := "STAFF LOG: Exit keycard is in STORAGE. Don't go in there alone."

enum State { PLAY, INVENTORY, WON, LOST }

var state := State.PLAY
## When false the game never captures the cursor and ignores real mouse movement; clicks
## fire straight away. Automated tests set this before adding the scene so they don't take
## over the desktop mouse. Static so it survives a restart (reload_current_scene).
static var grab_mouse := true
var world: Node3D
var player: CharacterBody3D
var zombies: Array = []
var riser: CharacterBody3D
var sfx: AudioStreamPlayer
var flicker_lights: Array = []
var blackout := 0.0
var elapsed := 0.0

var pickups: Array = []
var heal_count := 0
var has_key := false

var door: StaticBody3D
var door_lamp: ShaderMaterial
var door_light: OmniLight3D
var exit_light: OmniLight3D
var door_unlocked := false

var mats := {}
var mono: SystemFont
var prompt_label: Label
var msg_label: Label
var msg_time := 0.0
var stamina_bar: ColorRect
var ammo_label: Label
var health_label: Label
var health_bar: ColorRect
var hurt_flash: ColorRect
var inv_panel: Panel
var inv_list: ItemList
var inv_desc: Label
var inv_status: Label
var inv_preview: SubViewportContainer
var preview_pivot: Node3D  # holds the selected item's model; yaw/pitch from dragging
var preview_id := ""
var preview_drag := false
var preview_idle := 0.0  # seconds since the last drag; auto-spin resumes after a pause
var inv_ids: Array = []
var end_panel: ColorRect
var end_title: Label
var end_sub: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # UI keeps running while the inventory pauses the world
	randomize()
	_setup_input()
	_build_viewport()
	_build_materials()
	_build_level()
	_build_actors()
	_build_pickups()
	_build_ui()
	_capture_mouse(true)
	show_msg("Find a way out.  [LMB] shoot  [R] reload  [Tab] items  [E] use  [F] light", 7.0)


# --- setup -------------------------------------------------------------------

func _setup_input() -> void:
	var binds := {
		"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT], "interact": [KEY_E], "flashlight": [KEY_F],
		"reload": [KEY_R], "restart": [KEY_R], "inventory": [KEY_TAB, KEY_I],
	}
	for action in binds:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in binds[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	if not InputMap.has_action("fire"):
		InputMap.add_action("fire")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("fire", mb)


func _build_viewport() -> void:
	# 3D renders at 1/4 resolution (320x180) and is upscaled with nearest filtering.
	var container := SubViewportContainer.new()
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.stretch_shrink = 4
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.process_mode = Node.PROCESS_MODE_PAUSABLE
	var post := ShaderMaterial.new()
	post.shader = POST_SHADER
	container.material = post
	add_child(container)

	var vp := SubViewport.new()
	vp.audio_listener_enable_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	container.add_child(vp)
	world = Node3D.new()
	vp.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.09, 0.1, 0.11)
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.015, 0.018, 0.02)
	env.fog_density = 0.09
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)


func _gen_tex(kind: String) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind)
	for y in 32:
		for x in 32:
			var n := rng.randf()
			var c := Color.BLACK
			match kind:
				"wall":
					var v := 0.4 + n * 0.08 - (0.12 if y % 16 == 0 else 0.0)
					v -= 0.1 * max(0.0, sin(x * 0.7) - 0.85) * 6.0 * (y / 32.0)  # water streaks
					c = Color(v, v * 0.97, v * 0.88)
				"floor":
					var grout := x % 16 == 0 or y % 16 == 0
					var v := (0.3 if ((x / 16) + (y / 16)) % 2 == 0 else 0.24) + n * 0.06
					if grout:
						v = 0.1
					c = Color(v * 0.95, v, v * 0.9)
				"ceiling":
					var v := 0.35 + n * 0.05 - (0.15 if x % 16 == 0 or y % 16 == 0 else 0.0)
					c = Color(v, v, v * 0.95)
				"metal":
					var v := 0.3 + n * 0.06 - (0.1 if x % 8 == 0 else 0.0)
					c = Color(v * 0.9, v * 0.95, v)
					if (x % 8 == 3 and y % 8 == 3):
						c = Color(0.5, 0.5, 0.5)
				"hazard":
					c = Color(0.75, 0.6, 0.05) if ((x + y) / 4) % 2 == 0 else Color(0.06, 0.06, 0.06)
					c = c * (0.85 + n * 0.2)
				"skin":
					# Pallid grey-green with bruising and dark veins.
					var v := 0.85 + n * 0.25
					c = Color(0.55, 0.57, 0.48) * v
					if (x * 7 + y * 3) % 23 == 0 or (x + y * 5) % 29 == 0:
						c = Color(0.25, 0.22, 0.3)
					if n > 0.95:
						c = Color(0.32, 0.04, 0.04)
					elif n < 0.08:
						c = c.darkened(0.35)
				"shirt":
					c = Color(0.38, 0.36, 0.3) * (0.7 + n * 0.4)
					if rng.randf() < 0.12 and y > 10:
						c = Color(0.35, 0.03, 0.02)
				"pants":
					c = Color(0.12, 0.14, 0.22) * (0.8 + n * 0.3)
				"coverall", "hazmat", "labcoat":
					# Work clothes: base colour, seams, grime rising from the bottom, blood spatter.
					var base: Color = {"coverall": Color(0.62, 0.3, 0.08), "hazmat": Color(0.72, 0.62, 0.12),
						"labcoat": Color(0.72, 0.72, 0.68)}[kind]
					c = base * (0.8 + n * 0.25)
					if x % 16 == 0:
						c = c.darkened(0.35)
					c = c.lerp(Color(0.12, 0.1, 0.07), clamp((y - 14) / 30.0, 0.0, 0.6) * (0.6 + n * 0.4))
					if rng.randf() < 0.08 and (x + y * 2) % 7 < 3:
						c = Color(0.3, 0.02, 0.02)
				"eyeball":
					# Yellowed, bloodshot: red veins running in from the edges.
					c = Color(0.85, 0.75, 0.55) * (0.9 + n * 0.1)
					if (x * 5 + y * 3) % 11 == 0 or (x * 2 + y * 7) % 13 == 0 or y < 6 or y > 26:
						c = Color(0.7, 0.05, 0.03)
				"wound":
					# Raw, wet flesh.
					c = Color(0.45, 0.04, 0.04) * (0.6 + n * 0.6)
					if n > 0.85:
						c = Color(0.6, 0.45, 0.3)
				"desk":
					c = Color(0.3, 0.28, 0.25) * (0.85 + n * 0.2)
				_:
					c = Color(n, n, n)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func _mat(tex: Texture2D, tint := Color.WHITE, world_uv := true, emission := Color.BLACK, energy := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PS1_SHADER
	if tex:
		m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("world_uv", world_uv)
	m.set_shader_parameter("emission_color", emission)
	m.set_shader_parameter("emission_energy", energy)
	return m


func _build_materials() -> void:
	mats.wall = _mat(_gen_tex("wall"))
	mats.floor = _mat(_gen_tex("floor"))
	mats.ceiling = _mat(_gen_tex("ceiling"))
	mats.metal = _mat(_gen_tex("metal"))
	mats.hazard = _mat(_gen_tex("hazard"))
	mats.desk = _mat(_gen_tex("desk"))
	mats.crate = _mat(_gen_tex("desk"), Color(0.8, 0.6, 0.4))
	mats.blood = _mat(null, Color(0.18, 0.01, 0.01))
	mats.fixture = _mat(null, Color(1, 1, 1), false, Color(1.0, 0.9, 0.7), 2.0)
	mats.screen = _mat(null, Color(0, 0.1, 0), false, Color(0.2, 1.0, 0.4), 1.6)
	mats.skin = _mat(_gen_tex("skin"), Color.WHITE, false)
	mats.shirt = _mat(_gen_tex("shirt"), Color.WHITE, false)
	mats.pants = _mat(_gen_tex("pants"), Color.WHITE, false)
	mats.eye = _mat(null, Color(1, 0.1, 0.05), false, Color(1.0, 0.08, 0.03), 4.0)
	mats.sclera = _mat(_gen_tex("eyeball"), Color.WHITE, false, Color(0.25, 0.02, 0.0), 0.4)
	mats.raw = _mat(_gen_tex("wound"), Color.WHITE, false, Color(0.2, 0.0, 0.0), 0.3)
	mats.vein = _mat(null, Color(0.07, 0.03, 0.08), false)
	mats.hair = _mat(null, Color(0.05, 0.04, 0.035), false)
	mats.coverall = _mat(_gen_tex("coverall"), Color.WHITE, false)
	mats.hazmat = _mat(_gen_tex("hazmat"), Color.WHITE, false)
	mats.labcoat = _mat(_gen_tex("labcoat"), Color.WHITE, false)
	mats.slacks = _mat(_gen_tex("pants"), Color(0.6, 0.6, 0.55), false)
	mats.hivis = _mat(null, Color(0.75, 0.78, 0.7), false, Color(0.7, 0.75, 0.6), 0.35)
	mats.hardhat = _mat(null, Color(0.85, 0.65, 0.05), false)
	mats.boot = _mat(null, Color(0.08, 0.06, 0.05), false)
	mats.steel = _mat(null, Color(0.4, 0.42, 0.45), false)
	mats.glove = _mat(null, Color(0.35, 0.3, 0.2), false)
	mats.rubber = _mat(null, Color(0.12, 0.17, 0.1), false)
	mats.belt = _mat(null, Color(0.18, 0.11, 0.06), false)
	mats.filter = _mat(null, Color(0.25, 0.27, 0.2), false)
	mats.lens = _mat(null, Color(0.1, 0.15, 0.15), false, Color(0.05, 0.1, 0.1), 0.5)
	mats.badge = _mat(null, Color(0.85, 0.85, 0.9), false, Color(0.3, 0.5, 0.9), 0.3)
	mats.dark = _mat(null, Color(0.03, 0.02, 0.02), false)
	mats.gore = _mat(null, Color(0.16, 0.01, 0.01), false)
	mats.bone = _mat(null, Color(0.7, 0.65, 0.5), false)
	mats.ammo = _mat(null, Color(0.55, 0.45, 0.15), false, Color(0.6, 0.45, 0.1), 0.3)
	mats.heal = _mat(null, Color(0.2, 0.7, 0.3), false, Color(0.2, 0.8, 0.3), 0.4)
	mats.key = _mat(null, Color(0.3, 0.8, 1.0), false, Color(0.3, 0.8, 1.0), 1.2)
	mats.blood_puff = _mat(null, Color(0.5, 0.02, 0.02), false, Color(0.3, 0.0, 0.0), 0.5)
	mats.dust_puff = _mat(null, Color(0.5, 0.5, 0.45), false)
	door_lamp = _mat(null, Color(1, 0, 0), false, Color(1.0, 0.05, 0.02), 3.0)


# --- level -------------------------------------------------------------------

func _box(pos: Vector3, size: Vector3, mat: Material, collide := true, rot_y := 0.0) -> Node3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	# Subdivide big faces so vertex snapping / affine warping stay subtle.
	mesh.subdivide_width = int(size.x)
	mesh.subdivide_height = int(size.y)
	mesh.subdivide_depth = int(size.z)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	var root: Node3D = mi
	if collide:
		root = StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		root.add_child(cs)
		root.add_child(mi)
	root.position = pos
	root.rotation.y = rot_y
	world.add_child(root)
	return root


func _ceiling_light(x: float, z: float, flicker: bool, color := Color(1.0, 0.82, 0.55), energy := 1.0, rng := 6.0) -> OmniLight3D:
	_box(Vector3(x, H - 0.03, z), Vector3(0.6, 0.06, 0.25), mats.fixture, false)
	var l := OmniLight3D.new()
	l.position = Vector3(x, H - 0.35, z)
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.4
	world.add_child(l)
	if flicker:
		flicker_lights.append({"light": l, "base": energy})
	return l


func _label3d(text: String, pos: Vector3, rot_y: float, color: Color, size := 32) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.rotation.y = rot_y
	l.modulate = color
	l.font_size = size
	l.outline_size = 0
	l.shaded = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	world.add_child(l)


func _build_level() -> void:
	for r: Rect2 in RECTS:
		var c := Vector3(r.position.x + r.size.x * 0.5, 0.0, r.position.y + r.size.y * 0.5)
		_box(c + Vector3(0, -0.1, 0), Vector3(r.size.x, 0.2, r.size.y), mats.floor)
		_box(c + Vector3(0, H + 0.1, 0), Vector3(r.size.x, 0.2, r.size.y), mats.ceiling)
	for w in WALLS:
		var a := Vector2(w[0], w[1])
		var b := Vector2(w[2], w[3])
		var size := Vector3(0.3, H, abs(b.y - a.y) + 0.3) if a.x == b.x else Vector3(abs(b.x - a.x) + 0.3, H, 0.3)
		_box(Vector3((a.x + b.x) * 0.5, H * 0.5, (a.y + b.y) * 0.5), size, mats.wall)

	# Props: pipes, crates, shelves, blood, graffiti.
	_box(Vector3(1.15, 2.75, -15.5), Vector3(0.12, 0.12, 35.0), mats.metal, false)
	_box(Vector3(0.95, 2.6, -15.5), Vector3(0.08, 0.08, 35.0), mats.metal, false)
	_box(Vector3(10.75, 2.75, -30.4), Vector3(18.5, 0.12, 0.12), mats.metal, false)
	_box(Vector3(-1.0, 0.3, -19.5), Vector3(0.6, 0.6, 0.6), mats.crate, true, 0.3)
	_box(Vector3(-1.05, 0.85, -19.4), Vector3(0.4, 0.4, 0.4), mats.crate, true, -0.2)
	_box(Vector3(1.0, 0.3, -25.0), Vector3(0.6, 0.6, 0.6), mats.crate, true, 0.5)
	_box(Vector3(17.0, 0.3, -32.3), Vector3(0.7, 0.6, 0.6), mats.crate, true, 0.1)
	_box(Vector3(9.0, 0.3, -24.6), Vector3(0.8, 0.6, 0.6), mats.crate)
	_box(Vector3(13.4, 0.9, -27.0), Vector3(0.6, 1.8, 2.4), mats.metal)  # storage shelving
	_box(Vector3(8.6, 0.3, -28.6), Vector3(0.6, 0.6, 0.6), mats.crate, true, 0.4)
	_box(Vector3(0.2, 0.005, -9.0), Vector3(1.0, 0.01, 0.6), mats.blood, false, 0.4)
	_box(Vector3(-0.9, 0.005, -7.0), Vector3(1.2, 0.01, 0.9), mats.blood, false, -0.2)
	_box(Vector3(6.0, 0.005, -31.2), Vector3(2.5, 0.01, 0.3), mats.blood, false, 0.05)
	_box(Vector3(11.0, 0.005, -26.5), Vector3(1.4, 0.01, 1.0), mats.blood, false, 0.3)
	_box(Vector3(23.0, 0.005, -34.5), Vector3(0.8, 0.01, 0.8), mats.blood, false, 0.7)
	_label3d("DON'T LOOK BACK", Vector3(1.34, 1.8, -10.0), -PI / 2, Color(0.55, 0.02, 0.02))
	_label3d("IT FOLLOWS  -->", Vector3(0.0, 1.7, -32.84), 0.0, Color(0.55, 0.02, 0.02))
	_label3d("STORAGE", Vector3(13.6, 2.2, -30.16), PI, Color(0.75, 0.7, 0.55), 40)
	_label3d("EXIT", Vector3(27.84, 2.55, -31.5), -PI / 2, Color(0.2, 1.0, 0.3), 80)

	# Lighting.
	_ceiling_light(0.0, -3.0, true)
	_ceiling_light(0.0, -14.0, false, Color(1.0, 0.82, 0.55), 0.8)
	_ceiling_light(0.0, -24.0, true)
	_ceiling_light(5.0, -31.5, false, Color(1.0, 0.82, 0.55), 0.7)
	_ceiling_light(15.0, -31.5, true)
	_ceiling_light(11.0, -27.0, true, Color(0.8, 0.85, 1.0), 0.5)
	_ceiling_light(24.0, -31.5, true, Color(0.9, 0.7, 0.6), 0.6)

	# Terminal (now just a log with a hint).
	_box(Vector3(24.0, 0.45, -36.4), Vector3(1.6, 0.9, 0.7), mats.desk)
	_box(Vector3(24.0, 1.2, -36.55), Vector3(0.7, 0.55, 0.45), mats.metal, false)
	_box(Vector3(24.0, 1.2, -36.32), Vector3(0.56, 0.42, 0.02), mats.screen, false)
	_box(Vector3(24.0, 0.92, -36.1), Vector3(0.6, 0.04, 0.2), mats.metal, false)
	var tl := OmniLight3D.new()
	tl.position = Vector3(24.0, 1.3, -35.8)
	tl.light_color = Color(0.2, 1.0, 0.4)
	tl.light_energy = 0.9
	tl.omni_range = 3.5
	world.add_child(tl)

	# Locked door + red keycard reader.
	door = _box(DOOR_POS, Vector3(0.2, H, 2.0), mats.metal) as StaticBody3D
	var stripe := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.22, 0.3, 2.0)
	stripe.mesh = sm
	stripe.material_override = mats.hazard
	stripe.position.y = -1.2
	door.add_child(stripe)
	_box(Vector3(27.82, 1.3, -33.0), Vector3(0.06, 0.2, 0.15), door_lamp, false)
	door_light = OmniLight3D.new()
	door_light.position = Vector3(27.4, 1.5, -33.0)
	door_light.light_color = Color(1.0, 0.1, 0.05)
	door_light.light_energy = 1.2
	door_light.omni_range = 4.0
	world.add_child(door_light)
	exit_light = OmniLight3D.new()
	exit_light.position = Vector3(32.0, 2.2, -31.5)
	exit_light.light_color = Color(0.8, 0.9, 1.0)
	exit_light.light_energy = 3.0
	exit_light.omni_range = 6.0
	exit_light.visible = false
	world.add_child(exit_light)


func _build_actors() -> void:
	sfx = Sfx.new()
	add_child(sfx)

	player = Player.new()
	world.add_child(player)
	player.position = Vector3(0, 0.05, 0)
	player.build_gun()
	player.mag = START_MAG
	player.chambered = true
	player.reserve = 0
	player.footstep.connect(sfx.step)
	player.fired.connect(_on_fired)
	player.gun_sound.connect(sfx.gun_sound)
	player.sound_leads = sfx.gun_sound_leads()

	# Closet lurker (optional fight: guards the first aid kit). A scientist who hid in there.
	_spawn_zombie(Vector3(-3.0, 0, -7.0), Vector3(0, 0, -7.0), Zombie.Outfit.SCIENTIST)
	# Storage guard: stands over the keycard, facing the doorway.
	_spawn_zombie(Vector3(12.0, 0, -25.0), Vector3(11.0, 0, -30.0), Zombie.Outfit.WORKER)
	# "Corpse" in corridor B that gets up once you take the keycard.
	riser = _spawn_zombie(Vector3(6.0, 0, -31.6), Vector3(10.0, 0, -31.6), Zombie.Outfit.HAZMAT)
	riser.set_lying()


func _spawn_zombie(pos: Vector3, look_at_pos: Vector3, outfit := -1) -> CharacterBody3D:
	var z := Zombie.new()
	z.build(mats, outfit)
	world.add_child(z)
	z.position = pos
	var d := look_at_pos - pos
	z.rotation.y = atan2(-d.x, -d.z)
	z.player = player
	# z.step and z.groan are free hooks for zombie footstep/groan sound files (none yet).
	var voice: AudioStreamPlayer3D = sfx.make_zombie_voice(z)
	z.scream.connect(voice.play)  # emitted at the start of a lunge
	z.attack_hit.connect(_on_zombie_attack.bind(z))
	zombies.append(z)
	return z


func _build_pickups() -> void:
	_add_pickup("ammo", 5, Vector3(-0.9, 0.0, -21.0))     # behind the crates in corridor A
	_add_pickup("heal", 1, Vector3(-3.6, 0.0, -7.5))      # back of the zombie's closet
	_add_pickup("ammo", 5, Vector3(21.0, 0.0, -26.7))     # corner of the door room
	_add_pickup("key", 1, Vector3(9.0, 0.6, -24.6))       # on a crate in storage
	# Walk-over med kits: one at the end of corridor B before the door room, one in the
	# door room's far corner by the terminal.
	_add_pickup("medkit", MEDKIT_HEAL, Vector3(18.8, 0.0, -32.3))
	_add_pickup("medkit", MEDKIT_HEAL, Vector3(26.9, 0.0, -36.0))


func _add_pickup(kind: String, amount: int, pos: Vector3) -> void:
	var n := Node3D.new()
	n.position = pos
	world.add_child(n)
	var mi := _item_model(kind)
	mi.position.y = 0.13
	n.add_child(mi)
	var glint := OmniLight3D.new()
	glint.position.y = 0.4
	glint.light_energy = 0.6
	glint.omni_range = 1.4
	if kind == "heal" or kind == "medkit":
		# The kit glows on its own; a faint warm light just lifts the floor around it.
		glint.light_color = Color(1.0, 0.85, 0.75)
		glint.light_energy = 0.25
		glint.omni_range = 1.0
	else:
		glint.light_color = (mats[kind] as ShaderMaterial).get_shader_parameter("emission_color")
	n.add_child(glint)
	pickups.append({"node": n, "mesh": mi, "kind": kind, "amount": amount, "phase": randf()})


## The model for a pickup or inventory item ("handgun", "ammo", "heal"/"medkit", "key").
func _item_model(kind: String) -> Node3D:
	match kind:
		"handgun":
			return Player.make_usp()
		"ammo":
			return _ammo_box()
		"heal", "medkit":
			return _medkit()
		_:
			var card := MeshInstance3D.new()
			var k := BoxMesh.new()
			k.size = Vector3(0.18, 0.02, 0.11)
			card.mesh = k
			card.material_override = mats.key
			return card


## The 9mm box from the PSX Ammo Boxes pack, centred and scaled, in the PS1 shader.
## Double-sided because the open flaps are single planes.
func _ammo_box() -> Node3D:
	var holder := Node3D.new()
	var src := AMMO_BOX.instantiate()
	var box: MeshInstance3D = src.find_child("9mm_Open_Box", true, false)
	box.get_parent().remove_child(box)
	box.owner = null
	holder.add_child(box)
	src.free()
	var aabb: AABB = box.transform * box.mesh.get_aabb()
	box.position -= aabb.get_center()
	holder.scale = Vector3.ONE * AMMO_BOX_LENGTH / aabb.get_longest_axis_size()
	var m := ShaderMaterial.new()
	m.shader = _two_sided_ps1()
	m.set_shader_parameter("albedo_tex", AMMO_BOX_TEX)
	box.material_override = m
	return holder


## "Health kit" from the PSX Med Pack. Its emissive texture is the same image as its
## colour, so the glow is the PS1 shader's self_glow, turned down to a faint MEDKIT_GLOW.
func _medkit() -> Node3D:
	var holder := Node3D.new()
	var src := MEDKIT.instantiate()
	var kit: MeshInstance3D = src.find_children("*", "MeshInstance3D")[0]
	kit.get_parent().remove_child(kit)
	kit.owner = null
	holder.add_child(kit)
	src.free()
	var aabb: AABB = kit.transform * kit.mesh.get_aabb()
	kit.position -= aabb.get_center()
	holder.scale = Vector3.ONE * MEDKIT_LENGTH / aabb.get_longest_axis_size()
	var m := ShaderMaterial.new()
	m.shader = _two_sided_ps1()  # the model is flagged double-sided
	m.set_shader_parameter("albedo_tex", MEDKIT_TEX)
	m.set_shader_parameter("self_glow", MEDKIT_GLOW)
	kit.material_override = m
	return holder


var _two_sided_shader: Shader

func _two_sided_ps1() -> Shader:
	if _two_sided_shader == null:
		_two_sided_shader = Shader.new()
		_two_sided_shader.code = PS1_SHADER.code.replace("render_mode ", "render_mode cull_disabled, ")
	return _two_sided_shader


# --- ui ----------------------------------------------------------------------

func _label(parent: Node, size: int, color: Color, font: Font = null) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if font:
		l.add_theme_font_override("font", font)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _build_ui() -> void:
	mono = SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "Monaco", "Consolas", "Courier New", "monospace"])
	var ui := CanvasLayer.new()
	add_child(ui)

	hurt_flash = ColorRect.new()
	hurt_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	hurt_flash.color = Color(0.6, 0.0, 0.0, 0.0)
	hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hurt_flash)

	var cross := ColorRect.new()
	cross.color = Color(1, 1, 1, 0.5)
	cross.size = Vector2(4, 4)
	cross.position = Vector2(638, 358)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(cross)

	prompt_label = _label(ui, 22, Color(0.85, 0.85, 0.7), mono)
	prompt_label.position = Vector2(0, 560)
	prompt_label.size = Vector2(1280, 40)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	msg_label = _label(ui, 22, Color(0.8, 0.75, 0.65), mono)
	msg_label.position = Vector2(0, 100)
	msg_label.size = Vector2(1280, 40)
	msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	stamina_bar = ColorRect.new()
	stamina_bar.color = Color(0.7, 0.7, 0.6, 0.5)
	stamina_bar.position = Vector2(24, 700)
	stamina_bar.size = Vector2(160, 4)
	stamina_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(stamina_bar)

	health_label = _label(ui, 22, Color.WHITE, mono)
	health_label.position = Vector2(24, 650)
	health_bar = ColorRect.new()
	health_bar.position = Vector2(24, 682)
	health_bar.size = Vector2(160, 8)
	health_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(health_bar)

	ammo_label = _label(ui, 26, Color(0.9, 0.85, 0.7), mono)
	ammo_label.position = Vector2(960, 655)
	ammo_label.size = Vector2(296, 40)
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Inventory (pauses the world).
	var beige := Color(0.85, 0.8, 0.65)
	inv_panel = Panel.new()
	inv_panel.position = Vector2(240, 110)
	inv_panel.size = Vector2(800, 480)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.04, 0.94)
	sb.border_color = beige.darkened(0.4)
	sb.set_border_width_all(2)
	inv_panel.add_theme_stylebox_override("panel", sb)
	inv_panel.hide()
	ui.add_child(inv_panel)
	var title := _label(inv_panel, 26, beige, mono)
	title.text = "ITEMS"
	title.position = Vector2(28, 18)
	inv_status = _label(inv_panel, 22, beige, mono)
	inv_status.position = Vector2(430, 22)
	inv_list = ItemList.new()
	inv_list.position = Vector2(28, 70)
	inv_list.size = Vector2(380, 340)
	inv_list.add_theme_font_override("font", mono)
	inv_list.add_theme_font_size_override("font_size", 22)
	inv_list.add_theme_color_override("font_color", beige)
	inv_list.add_theme_color_override("font_selected_color", Color.BLACK)
	inv_list.add_theme_constant_override("v_separation", 14)
	var lb := StyleBoxFlat.new()
	lb.bg_color = Color(0.07, 0.07, 0.08)
	inv_list.add_theme_stylebox_override("panel", lb)
	inv_list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sel := StyleBoxFlat.new()
	sel.bg_color = beige
	inv_list.add_theme_stylebox_override("selected", sel)
	inv_list.add_theme_stylebox_override("selected_focus", sel)
	inv_list.item_selected.connect(_on_inv_selected)
	inv_list.item_activated.connect(func(i: int): _use_item(inv_ids[i]))
	inv_panel.add_child(inv_list)
	inv_desc = _label(inv_panel, 19, beige.darkened(0.15), mono)
	inv_desc.position = Vector2(430, 80)
	inv_desc.size = Vector2(350, 300)
	inv_desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	_build_item_preview(beige)
	var help := _label(inv_panel, 17, beige.darkened(0.45), mono)
	help.text = "[Up/Down] select   [Enter] use   [Tab] close   [Drag] rotate"
	help.position = Vector2(28, 430)

	end_panel = ColorRect.new()
	end_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	end_panel.hide()
	ui.add_child(end_panel)
	end_title = _label(end_panel, 64, Color.WHITE, mono)
	end_title.position = Vector2(0, 270)
	end_title.size = Vector2(1280, 80)
	end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_sub = _label(end_panel, 22, Color(0.8, 0.8, 0.8), mono)
	end_sub.position = Vector2(0, 370)
	end_sub.size = Vector2(1280, 40)
	end_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func show_msg(text: String, dur := 3.0) -> void:
	msg_label.text = text
	msg_time = dur


func _condition() -> Array:
	if player.health >= 66:
		return ["FINE", Color(0.3, 0.9, 0.35)]
	if player.health >= 33:
		return ["CAUTION", Color(0.95, 0.75, 0.15)]
	return ["DANGER", Color(0.95, 0.15, 0.1)]


# --- inventory ---------------------------------------------------------------

## 3D viewer under the item description: the selected item's model, turning slowly,
## rotated by dragging with the mouse. Rendered at half resolution for chunky PS1 pixels.
func _build_item_preview(beige: Color) -> void:
	inv_preview = SubViewportContainer.new()
	inv_preview.position = Vector2(430, 190)
	inv_preview.size = Vector2(350, 224)
	inv_preview.stretch = true
	inv_preview.stretch_shrink = 2
	inv_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	inv_preview.mouse_default_cursor_shape = Control.CURSOR_DRAG
	inv_preview.gui_input.connect(_on_preview_input)
	inv_panel.add_child(inv_preview)
	var frame := ReferenceRect.new()  # thin border so the viewer reads as a window
	frame.size = inv_preview.size
	frame.position = inv_preview.position
	frame.border_color = beige.darkened(0.6)
	frame.editor_only = false
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inv_panel.add_child(frame)

	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	inv_preview.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.07, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.45, 0.5)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var key_light := DirectionalLight3D.new()
	key_light.rotation = Vector3(-0.7, 0.5, 0.0)
	key_light.light_color = Color(1.0, 0.92, 0.8)
	vp.add_child(key_light)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.25, 1.6)
	cam.fov = 40.0
	vp.add_child(cam)
	cam.look_at(Vector3.ZERO)
	preview_pivot = Node3D.new()
	vp.add_child(preview_pivot)


## Swaps the viewer to `id`'s model, centred and sized to fit.
func _show_preview(id: String) -> void:
	if id == preview_id:
		return
	preview_id = id
	for c in preview_pivot.get_children():
		c.queue_free()
	# Three-quarter view; the gun starts side-on with the muzzle to the left.
	preview_pivot.rotation = Vector3(0.15, PI / 2 - 0.35, 0.0) if id == "handgun" else Vector3(0.35, -0.6, 0.0)
	preview_idle = 0.0
	if id == "":
		return
	var holder := Node3D.new()
	preview_pivot.add_child(holder)
	var model := _item_model(id)
	model.position = Vector3.ZERO
	holder.add_child(model)
	# Fit: centre the visible meshes on the pivot and scale the longest side to 1m.
	var box := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false) + ([model] if model is MeshInstance3D else []):
		if not mi.visible:
			continue
		var xf: Transform3D = holder.global_transform.affine_inverse() * mi.global_transform
		var b: AABB = xf * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	holder.scale = Vector3.ONE / max(box.get_longest_axis_size(), 0.001)
	holder.position = -box.get_center() * holder.scale


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		preview_drag = event.pressed
		preview_idle = 0.0
		inv_list.grab_focus.call_deferred()  # clicking the viewer mustn't break keyboard navigation
	elif event is InputEventMouseMotion and preview_drag:
		preview_pivot.rotation.y += event.relative.x * 0.012
		preview_pivot.rotation.x = clamp(preview_pivot.rotation.x + event.relative.y * 0.012, -1.4, 1.4)
		preview_idle = 0.0


func _open_inventory() -> void:
	state = State.INVENTORY
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_inventory(0)
	inv_panel.show()
	inv_list.grab_focus()


func _close_inventory() -> void:
	if state != State.INVENTORY:
		return
	state = State.PLAY
	get_tree().paused = false
	inv_panel.hide()
	inv_list.release_focus()
	_capture_mouse(true)


func _refresh_inventory(select := -1) -> void:
	if select < 0:
		select = inv_list.get_selected_items()[0] if inv_list.is_anything_selected() else 0
	inv_list.clear()
	inv_ids.clear()
	_inv_add("handgun", "Handgun      %d/%d" % [player.rounds(), Player.MAG_SIZE])
	if player.reserve > 0:
		_inv_add("ammo", "Handgun Ammo   x%d" % player.reserve)
	if heal_count > 0:
		_inv_add("heal", "First Aid Kit   x%d" % heal_count)
	if has_key:
		_inv_add("key", "Exit Keycard")
	var filled := inv_ids.size()
	while inv_ids.size() < INV_SLOTS:
		inv_list.add_item("  ---")
		inv_list.set_item_disabled(inv_list.item_count - 1, true)
		inv_list.set_item_selectable(inv_list.item_count - 1, false)
		inv_ids.append("")
	select = clamp(select, 0, filled - 1)
	inv_list.select(select)
	_on_inv_selected(select)
	var cond := _condition()
	inv_status.text = "CONDITION: %s" % cond[0]
	inv_status.add_theme_color_override("font_color", cond[1])


func _inv_add(id: String, text: String) -> void:
	inv_list.add_item(text)
	inv_ids.append(id)


func _on_inv_selected(i: int) -> void:
	var id: String = inv_ids[i] if i < inv_ids.size() else ""
	inv_desc.text = ITEM_DESC.get(id, "")
	_show_preview(id)


func _use_item(id: String) -> void:
	match id:
		"heal":
			if player.health >= Player.MAX_HEALTH:
				inv_desc.text = "You're already in good condition."
				return
			player.heal(HEAL_AMOUNT)
			heal_count -= 1
			sfx.pickup()
			_refresh_inventory()
			inv_desc.text = "You patch up your wounds. You feel better."
		"ammo":
			if not player.start_reload():
				inv_desc.text = "The handgun is already full."
				return
			_close_inventory()
		"key":
			if _near_door():
				_close_inventory()
				_try_door()
			else:
				inv_desc.text = "There's nothing here to use it on."
		"handgun":
			inv_desc.text = "Equipped.\n[LMB] fire   [R] reload"


# --- game loop ---------------------------------------------------------------

func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _loudness(z: Node3D) -> float:
	return clamp(1.0 - _flat_dist(player.global_position, z.global_position) / 20.0, 0.05, 1.0)


func _capture_mouse(on: bool) -> void:
	if grab_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and state == State.PLAY and grab_mouse and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		player.look(event.relative)
	elif event.is_action_pressed("inventory"):
		if state == State.PLAY:
			_open_inventory()
		elif state == State.INVENTORY:
			_close_inventory()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		if state == State.INVENTORY:
			_close_inventory()
			get_viewport().set_input_as_handled()
		elif state == State.PLAY:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and state == State.PLAY:
		if grab_mouse and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse(true)
		elif event.is_action_pressed("fire"):
			_fire()


func _unhandled_input(event: InputEvent) -> void:
	if state == State.PLAY:
		if event.is_action_pressed("interact"):
			_interact()
		elif event.is_action_pressed("reload"):
			_reload()
		elif event.is_action_pressed("flashlight"):
			player.toggle_flashlight()
			sfx.click()
	elif event.is_action_pressed("restart") and (state == State.WON or state == State.LOST):
		get_tree().paused = false
		get_tree().reload_current_scene()


func _fire() -> void:
	if state != State.PLAY:
		return
	if player.try_fire() == 1:
		show_msg("*click*  Empty.  [R] reload" if player.reserve > 0 else "*click*  Out of ammo.", 1.5)


func _reload() -> void:
	if not player.start_reload() and player.reserve <= 0 and player.rounds() <= Player.MAG_SIZE:
		show_msg("No spare ammo.", 1.5)


func _on_fired(hit: Dictionary) -> void:
	sfx.shot()
	for z in zombies:
		if _flat_dist(z.global_position, player.global_position) < NOISE_RADIUS:
			z.hear(player.global_position)
	if hit.is_empty():
		return
	var target: Object = hit.collider
	if target.has_method("take_damage"):
		var headshot: bool = hit.position.y - (target as Node3D).global_position.y > 1.5
		target.take_damage(2 if headshot else 1, headshot)
		_puff(hit.position, mats.blood_puff, 7)
		sfx.splat()
	else:
		_puff(hit.position + hit.normal * 0.02, mats.dust_puff, 4)


func _puff(pos: Vector3, mat: Material, count: int) -> void:
	for i in count:
		var m := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = Vector3.ONE * 0.05
		m.mesh = b
		m.material_override = mat
		world.add_child(m)
		m.global_position = pos
		var tw := m.create_tween()
		var off := Vector3(randf_range(-1, 1), randf_range(-0.5, 1), randf_range(-1, 1)) * 0.3
		tw.tween_property(m, "global_position", pos + off, 0.35)
		tw.parallel().tween_property(m, "scale", Vector3.ZERO, 0.35)
		tw.tween_callback(m.queue_free)


func _on_zombie_attack(damage: int, z: Node3D) -> void:
	if state != State.PLAY:
		return
	player.take_damage(damage, z.global_position)
	sfx.hurt()
	hurt_flash.color.a = 0.5
	create_tween().tween_property(hurt_flash, "color:a", 0.0, 0.5)
	if player.health <= 0:
		_lose(z)


func _interact() -> void:
	var p := _target_pickup()
	if not p.is_empty():
		_collect(p)
	elif _near_door():
		_try_door()
	elif _near_terminal():
		show_msg(TERMINAL_LOG, 5.0)
		sfx.tone(980.0, 0.05)


func _target_pickup() -> Dictionary:
	var cam: Vector3 = player.cam.global_position
	var fwd: Vector3 = -player.cam.global_transform.basis.z
	var best := {}
	var best_d := 1e9
	for p in pickups:
		if p.kind == "medkit":
			continue  # walked over, not picked up with E
		var pos: Vector3 = p.node.global_position
		var d := _flat_dist(cam, pos)
		var facing := fwd.dot((pos - cam).normalized())
		if (d < 1.0 or (d < 2.0 and facing > 0.5)) and d < best_d:
			best = p
			best_d = d
	return best


func _collect(p: Dictionary) -> void:
	match p.kind:
		"ammo":
			player.reserve += p.amount
			show_msg("Picked up Handgun Ammo (%d)." % p.amount)
		"heal":
			heal_count += 1
			show_msg("Picked up a First Aid Kit. [Tab] to use.")
		"key":
			has_key = true
			show_msg("Picked up the Exit Keycard.  ...something stirs in the corridor.", 4.0)
			blackout = 0.6
			riser.rise()
	sfx.pickup()
	p.node.queue_free()
	pickups.erase(p)


func _near_door() -> bool:
	return _flat_dist(player.global_position, Vector3(27.0, 0, -31.5)) < 2.2


func _near_terminal() -> bool:
	var cam: Vector3 = player.cam.global_position
	if _flat_dist(cam, TERMINAL_POS) > 2.0:
		return false
	var fwd: Vector3 = -player.cam.global_transform.basis.z
	return fwd.dot((TERMINAL_POS - cam).normalized()) > 0.5


func _try_door() -> void:
	if door_unlocked:
		return
	if has_key:
		has_key = false
		_unlock_door()
	else:
		show_msg("Locked. The keycard reader blinks red.")
		sfx.buzz()


func _unlock_door() -> void:
	door_unlocked = true
	door_lamp.set_shader_parameter("emission_color", Color(0.1, 1.0, 0.2))
	door_light.light_color = Color(0.1, 1.0, 0.2)
	exit_light.visible = true
	sfx.chime()
	var tw := create_tween()
	tw.tween_property(door, "position:y", DOOR_POS.y + H - 0.1, 2.5).set_trans(Tween.TRANS_SINE)
	show_msg("Keycard accepted. The door grinds open.", 3.0)


func _physics_process(delta: float) -> void:
	if state != State.PLAY:
		return
	elapsed += delta
	var nearest := 1e9
	for z in zombies:
		if z.is_hostile():
			nearest = min(nearest, _flat_dist(z.global_position, player.global_position))
	var fear: float = clamp(1.0 - nearest / 12.0, 0.0, 1.0)
	var hurt: float = 1.0 - player.health / float(Player.MAX_HEALTH)
	sfx.heart_vol = max(fear, hurt * 0.7) * 0.6
	sfx.heart_bpm = lerp(70.0, 150.0, max(fear, hurt))
	_walk_over_medkits()
	if door_unlocked and player.global_position.x > EXIT_X:
		_win()


## Spin plus a hop, sampled at PICKUP_ANIM_FPS: rises, hangs, drops, and squashes a
## little on landing.
## Med kits heal on contact, but stay put if you're already at full health.
func _walk_over_medkits() -> void:
	if player.health >= Player.MAX_HEALTH:
		return
	for p in pickups.duplicate():
		if p.kind == "medkit" and _flat_dist(player.global_position, p.node.global_position) < MEDKIT_REACH:
			player.heal(p.amount)
			show_msg("Used a first aid kit. (+%d)" % p.amount)
			sfx.pickup()
			p.node.queue_free()
			pickups.erase(p)


func _animate_pickup(p: Dictionary) -> void:
	var t: float = floor(elapsed * PICKUP_ANIM_FPS) / PICKUP_ANIM_FPS + p.phase * 10.0
	var hop: float = fposmod(t * PICKUP_HOP_RATE, 1.0)
	var h := 4.0 * hop * (1.0 - hop)  # ballistic arc: 0 on the ground, 1 at the top
	var squash: float = max(0.0, 1.0 - hop * 8.0) + max(0.0, hop * 8.0 - 7.0)  # first/last 1/8 of the hop
	p.mesh.position.y = 0.13 + PICKUP_HOP * h
	p.mesh.rotation.y = t * PICKUP_SPIN
	var base: float = p.mesh.get_meta("base_scale", p.mesh.scale.x)
	p.mesh.set_meta("base_scale", base)
	p.mesh.scale = Vector3(base * (1.0 + 0.12 * squash), base * (1.0 - 0.2 * squash), base * (1.0 + 0.12 * squash))


func _process(delta: float) -> void:
	if state == State.INVENTORY and preview_pivot:
		preview_idle += delta
		if not preview_drag and preview_idle > 1.5:
			preview_pivot.rotation.y += delta * 0.6
	msg_time -= delta
	msg_label.modulate.a = clamp(msg_time, 0.0, 1.0)
	stamina_bar.size.x = 160.0 * player.stamina
	stamina_bar.visible = player.stamina < 0.99 and state == State.PLAY

	var cond := _condition()
	health_label.text = cond[0]
	health_label.add_theme_color_override("font_color", cond[1])
	health_bar.color = cond[1]
	health_bar.size.x = 160.0 * player.health / Player.MAX_HEALTH
	ammo_label.text = ("RELOADING  " if player.reloading > 0.0 else "") + "%d / %d" % [player.rounds(), player.reserve]
	for n in [health_label, health_bar, ammo_label]:
		n.visible = state == State.PLAY or state == State.INVENTORY

	if state == State.INVENTORY:
		return
	for p in pickups:
		_animate_pickup(p)

	blackout = max(0.0, blackout - delta)
	for f in flicker_lights:
		var l: OmniLight3D = f.light
		if blackout > 0.0:
			l.light_energy = 0.0
		elif randf() < 0.04:
			l.light_energy = f.base * randf_range(0.0, 0.3)
		else:
			l.light_energy = lerp(l.light_energy, f.base, 0.3)

	var prompt := ""
	if state == State.PLAY:
		var p := _target_pickup()
		if not p.is_empty():
			prompt = "[E] Pick up %s" % ITEM_NAMES[p.kind]
		elif _near_door() and not door_unlocked:
			prompt = "[E] Use Exit Keycard" if has_key else "[E] Door (locked)"
		elif _near_terminal():
			prompt = "[E] Read terminal"
	prompt_label.text = prompt


func _lose(killer: Node3D) -> void:
	state = State.LOST
	player.enabled = false
	for z in zombies:
		z.set_physics_process(false)
	sfx.heart_vol = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Snap the view to the killer, then collapse.
	var d := killer.global_position - player.global_position
	var start_yaw := player.rotation.y
	var target_yaw := atan2(-d.x, -d.z)
	var tw := create_tween()
	tw.tween_method(func(v: float): player.rotation.y = lerp_angle(start_yaw, target_yaw, v), 0.0, 1.0, 0.2)
	tw.parallel().tween_property(player.cam, "rotation:x", 0.15, 0.2)
	tw.tween_property(player.cam, "position:y", 0.35, 0.7).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(player.cam, "rotation:z", 0.7, 0.7)
	_show_end("YOU DIED", "You lasted %.1fs.   Press R to try again." % elapsed, Color(0.35, 0.0, 0.0, 0.8), Color(0.9, 0.1, 0.08))


func _win() -> void:
	state = State.WON
	player.enabled = false
	for z in zombies:
		z.set_physics_process(false)
	sfx.heart_vol = 0.0
	sfx.chime()
	var kills := zombies.filter(func(z): return z.mode == Zombie.DEAD).size()
	_show_end("YOU ESCAPED", "Time %.1fs  |  Zombies put down: %d/%d  |  Press R to play again" % [elapsed, kills, zombies.size()], Color(0.85, 0.9, 0.95, 0.92), Color(0.05, 0.08, 0.06))


func _show_end(title: String, sub: String, bg: Color, fg: Color) -> void:
	end_title.text = title
	end_title.add_theme_color_override("font_color", fg)
	end_sub.text = sub
	end_sub.add_theme_color_override("font_color", fg.lerp(Color.GRAY, 0.3))
	end_panel.color = Color(bg.r, bg.g, bg.b, 0.0)
	end_panel.modulate.a = 0.0
	end_panel.show()
	var tw := create_tween()
	tw.tween_interval(0.6)
	tw.tween_property(end_panel, "color:a", bg.a, 1.2)
	tw.parallel().tween_property(end_panel, "modulate:a", 1.0, 1.2)
