extends AudioStreamPlayer
## Game audio. Recorded files for the ambience, gunshot and zombie lunge attack; a tiny
## procedural synth for the rest (heartbeat, player footsteps, terminal beeps).

# --- Volume levels (linear, 0.0 to 1.0): tweak these. --------------------------------
const AMBIENCE_VOLUME := 0.35
const GUNSHOT_VOLUME := 0.8
const ZOMBIE_ATTACK_VOLUME := 1.0
const GUN_FOLEY_VOLUME := 0.8  # dry fire, magazine out/in, slide rack
const SYNTH_VOLUME := 0.7  # heartbeat, player footsteps, beeps
const LOCKER_VOLUME := 0.8  # locker door open/close
# ------------------------------------------------------------------------------------

const AMBIENCE := preload("res://audio/ambience_old_factory.wav")  # loops (set in its .import)
const GUNSHOT := preload("res://audio/gunshot_9mm.wav")
const ZOMBIE_ATTACK := preload("res://audio/zombie_attack.mp3")
# Gun foley: cue -> [file, lead]. Lead = seconds from the start of the file to its main
# click, so the player starts the sound that early and the click lands on the animation beat.
const GUN_FOLEY := {
	"dry_fire": [preload("res://audio/dry_fire.wav"), 0.0],
	"mag_out": [preload("res://audio/mag_out.wav"), 0.0],
	"mag_in": [preload("res://audio/mag_in.wav"), 0.32],
	"slide_rack": [preload("res://audio/slide_rack.wav"), 0.22],  # forward slam; pull-back click at 0.06
}
# Locker door sounds: res:// paths to audio files, or "" for silence (no suitable files yet).
const LOCKER_SOUNDS := {"open": "", "close": ""}
const RATE := 22050.0

var pb: AudioStreamGeneratorPlayback
var heart_vol := 0.0
var heart_bpm := 70.0
var heart_ph := 0.0
var step_env := 0.0
var step_lp := 0.0
var key_env := 0.0
var key_hp := 0.0
var tone_queue: Array = []  # [freq, dur, vol, wave(0=square,1=saw)]
var tone_t := 0.0
var tone_ph := 0.0
var ambience: AudioStreamPlayer
var gunshot: AudioStreamPlayer
var foley := {}  # cue -> AudioStreamPlayer


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	stream = gen
	volume_db = linear_to_db(SYNTH_VOLUME)
	play()
	pb = get_stream_playback()

	ambience = AudioStreamPlayer.new()
	ambience.stream = AMBIENCE
	ambience.volume_db = linear_to_db(AMBIENCE_VOLUME)
	add_child(ambience)
	ambience.play()

	# Several voices so rapid fire doesn't cut off the previous shot's tail;
	# the randomizer picks a fresh pitch (about 0.95-1.05) for every shot.
	var shot_rand := AudioStreamRandomizer.new()
	shot_rand.add_stream(0, GUNSHOT)
	shot_rand.random_pitch = 1.05
	gunshot = AudioStreamPlayer.new()
	gunshot.stream = shot_rand
	gunshot.max_polyphony = 6
	gunshot.volume_db = linear_to_db(GUNSHOT_VOLUME)
	add_child(gunshot)

	for cue in GUN_FOLEY:
		var r := AudioStreamRandomizer.new()
		r.add_stream(0, GUN_FOLEY[cue][0])
		r.random_pitch = 1.05  # about 0.95-1.05 per play
		var pl := AudioStreamPlayer.new()
		pl.stream = r
		pl.max_polyphony = 2
		pl.volume_db = linear_to_db(GUN_FOLEY_VOLUME)
		add_child(pl)
		foley[cue] = pl


## How early each gun cue must start (see GUN_FOLEY).
func gun_sound_leads() -> Dictionary:
	var leads := {}
	for cue in GUN_FOLEY:
		leads[cue] = GUN_FOLEY[cue][1]
	return leads


## Positional player for a zombie's lunge attack, attached to the zombie so the
## sound comes from where it is. Pitch varies about 0.9-1.1 per play.
func make_zombie_voice(z: Node3D) -> AudioStreamPlayer3D:
	var r := AudioStreamRandomizer.new()
	r.add_stream(0, ZOMBIE_ATTACK)
	r.random_pitch = 1.1
	var v := AudioStreamPlayer3D.new()
	v.stream = r
	v.volume_db = linear_to_db(ZOMBIE_ATTACK_VOLUME)
	v.unit_size = 4.0
	v.position.y = 1.6
	z.add_child(v)
	return v


## Short plasticky key click for terminal typing (placeholder synth until there's a file).
func key_click() -> void:
	key_env = randf_range(0.5, 0.9)


func step() -> void:
	step_env = 1.0


func tone(freq: float, dur: float, vol := 0.25, wave := 0) -> void:
	tone_queue.append([freq, dur, vol, wave])


func buzz() -> void:
	tone(110.0, 0.3, 0.35, 1)
	tone(0.0, 0.06, 0.0)
	tone(110.0, 0.3, 0.35, 1)


func chime() -> void:
	tone(660.0, 0.09)
	tone(880.0, 0.09)
	tone(1320.0, 0.25)


func click() -> void:
	tone(1800.0, 0.015, 0.15)


func shot() -> void:
	gunshot.play()


func splat() -> void:
	step_env = 2.0


func hurt() -> void:
	tone(150.0, 0.1, 0.4, 1)
	tone(95.0, 0.2, 0.4, 1)


## Gun foley from the player's gun_sound signal.
func gun_sound(cue: String) -> void:
	if foley.has(cue):
		foley[cue].play()


## Locker door open/close from the locker's position (silent while LOCKER_SOUNDS is empty).
func locker_sound(cue: String, at: Node3D) -> void:
	if LOCKER_SOUNDS.get(cue, "") == "":
		return
	var v := AudioStreamPlayer3D.new()
	v.stream = load(LOCKER_SOUNDS[cue])
	v.volume_db = linear_to_db(LOCKER_VOLUME)
	v.position.y = 1.0
	at.add_child(v)
	v.finished.connect(v.queue_free)
	v.play()


func pickup() -> void:
	tone(880.0, 0.06)
	tone(1320.0, 0.1)


func _process(_delta: float) -> void:
	if pb == null:
		return
	var n := pb.get_frames_available()
	if n <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(n)
	var dt := 1.0 / RATE
	var beat := 60.0 / heart_bpm
	for i in n:
		var s := 0.0
		var nz := randf() * 2.0 - 1.0

		if heart_vol > 0.001:
			heart_ph += dt
			if heart_ph > beat:
				heart_ph -= beat
			var b := heart_ph - 0.24
			var h := sin(TAU * 52.0 * heart_ph) * exp(-heart_ph * 28.0)
			if b > 0.0:
				h += 0.7 * sin(TAU * 48.0 * b) * exp(-b * 28.0)
			s += h * heart_vol

		if key_env > 0.001:
			key_hp += (nz - key_hp) * 0.6  # mostly high-frequency noise
			s += (nz - key_hp) * key_env * 0.35
			key_env *= 0.993

		if step_env > 0.001:
			step_lp += (nz - step_lp) * 0.25
			s += step_lp * step_env * 0.35
			step_env *= 0.9975

		if not tone_queue.is_empty():
			var tq: Array = tone_queue[0]
			tone_ph = fmod(tone_ph + tq[0] * dt, 1.0)
			var w: float = (1.0 if tone_ph < 0.5 else -1.0) if tq[3] == 0 else (tone_ph * 2.0 - 1.0)
			s += w * tq[2] * 0.5
			tone_t += dt
			if tone_t >= tq[1]:
				tone_t = 0.0
				tone_queue.pop_front()

		s = clamp(s, -1.0, 1.0)
		buf[i] = Vector2(s, s)
	pb.push_buffer(buf)
