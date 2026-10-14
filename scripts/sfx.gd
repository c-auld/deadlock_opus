extends AudioStreamPlayer
## Tiny procedural synth: ambient drone, heartbeat, footsteps, groans and terminal beeps.

const RATE := 22050.0

var pb: AudioStreamGeneratorPlayback
var t := 0.0
var lp := 0.0
var heart_vol := 0.0
var heart_bpm := 70.0
var heart_ph := 0.0
var step_env := 0.0
var step_lp := 0.0
var z_env := 0.0
var z_vol := 0.0
var z_ph := 0.0
var groan_t := -1.0
var groan_len := 1.5
var groan_vol := 0.0
var groan_ph := 0.0
var groan_lp := 0.0
var groan_base := 80.0
var shot_env := 0.0
var shot_ph := 0.0
var tone_queue: Array = []  # [freq, dur, vol, wave(0=square,1=saw)]
var tone_t := 0.0
var tone_ph := 0.0


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	stream = gen
	volume_db = -3.0
	play()
	pb = get_stream_playback()


func step() -> void:
	step_env = 1.0


func zstep(vol: float) -> void:
	z_env = 1.0
	z_vol = vol


func groan(vol: float) -> void:
	groan_t = 0.0
	groan_len = randf_range(1.2, 2.0)
	groan_vol = vol
	groan_base = randf_range(65.0, 95.0)


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
	shot_env = 1.0
	shot_ph = 0.0


func splat() -> void:
	step_env = 2.0


func hurt() -> void:
	tone(150.0, 0.1, 0.4, 1)
	tone(95.0, 0.2, 0.4, 1)


func reload_sound() -> void:
	tone(1200.0, 0.03, 0.2)
	tone(0.0, 1.1, 0.0)
	tone(700.0, 0.05, 0.25)


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
		t += dt
		var s := 0.045 * sin(TAU * 43.0 * t) + 0.03 * sin(TAU * 64.5 * t + 1.5 * sin(t * 0.37))
		s += 0.012 * sin(TAU * 172.0 * t) * (0.5 + 0.5 * sin(t * 0.9))
		var nz := randf() * 2.0 - 1.0
		lp += (nz - lp) * 0.03
		s += lp * 0.25

		if heart_vol > 0.001:
			heart_ph += dt
			if heart_ph > beat:
				heart_ph -= beat
			var b := heart_ph - 0.24
			var h := sin(TAU * 52.0 * heart_ph) * exp(-heart_ph * 28.0)
			if b > 0.0:
				h += 0.7 * sin(TAU * 48.0 * b) * exp(-b * 28.0)
			s += h * heart_vol

		if step_env > 0.001:
			step_lp += (nz - step_lp) * 0.25
			s += step_lp * step_env * 0.35
			step_env *= 0.9975

		if shot_env > 0.001:
			shot_ph += 70.0 * dt
			s += (nz * 0.8 + sin(TAU * shot_ph) * 0.7) * shot_env
			shot_env *= 0.9994

		if z_env > 0.001:
			z_ph += 62.0 * dt
			s += sin(TAU * z_ph) * z_env * z_vol * 0.5
			z_env *= 0.9985

		if groan_t >= 0.0:
			var g := groan_t / groan_len
			var env := sin(PI * g)
			var f := groan_base * (1.0 - 0.25 * g) + 7.0 * sin(groan_t * 11.0)
			groan_ph = fmod(groan_ph + f * dt, 1.0)
			groan_lp += (groan_ph * 2.0 - 1.0 - groan_lp) * 0.12
			s += (groan_lp + nz * 0.15) * env * groan_vol * 0.6
			groan_t += dt
			if groan_t > groan_len:
				groan_t = -1.0

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
