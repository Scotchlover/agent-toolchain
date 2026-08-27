# Sfx — tiny procedural sound synth. No binary assets in repo: every cue is
# generated PCM (16-bit mono 22050 Hz) at first use and cached per name.
class_name Sfx

const RATE := 22050
static var _cache: Dictionary = {}

## cue definitions: [freq_start, freq_end, seconds, volume, noise_mix 0..1]
const CUES := {
	"follow": [420.0, 540.0, 0.12, 0.5, 0.0],
	"hold":   [300.0, 250.0, 0.14, 0.5, 0.0],
	"hunt":   [620.0, 980.0, 0.15, 0.55, 0.05],
	"swing":  [700.0, 180.0, 0.12, 0.35, 0.35],
	"thud":   [130.0, 55.0, 0.09, 0.7, 0.25],
	"dread":  [95.0, 38.0, 0.5, 0.85, 0.2],
	"death":  [220.0, 45.0, 0.22, 0.5, 0.45],
	"execute":[160.0, 40.0, 0.32, 0.9, 0.3],
	"coin":   [900.0, 1400.0, 0.09, 0.4, 0.0],
	"bell":   [220.0, 215.0, 0.9, 0.6, 0.02],
	"alarm":  [118.0, 265.0, 0.72, 0.78, 0.08],
	"breach": [92.0, 38.0, 0.28, 0.92, 0.42],
}

static func clear_cache() -> void:
	_cache.clear()

static func stream(cue: String) -> AudioStreamWAV:
	if _cache.has(cue):
		return _cache[cue]
	var c: Array = CUES.get(cue, CUES["thud"])
	var f0: float = c[0]
	var f1: float = c[1]
	var dur: float = c[2]
	var vol: float = c[3]
	var noise: float = c[4]
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / float(n)
		var f := lerpf(f0, f1, t)
		phase += TAU * f / float(RATE)
		var tone := sin(phase)
		var nz := randf_range(-1.0, 1.0)
		var sample := lerpf(tone, nz, noise) * vol * (1.0 - t * 0.65)
		if i < 40:
			sample *= float(i) / 40.0   # click-free attack
		var v := int(clampf(sample, -1.0, 1.0) * 32000.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	_cache[cue] = wav
	return wav
