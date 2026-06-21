extends RefCounted
## Deterministic seeded RNG — exact port of the web sim's `mulberry32` (JS).
## Same seed -> identical sequence as the web version, so balance runs stay
## reproducible and the sim is lockstep-multiplayer-ready later.
##
## JS uses 32-bit ops (>>> 0, | 0, Math.imul); GDScript ints are 64-bit, so we
## emulate 32-bit wrap-around with masks below.

var _a: int

func _init(seed_value: int) -> void:
	_a = seed_value & 0xFFFFFFFF

static func _u32(x: int) -> int:
	return x & 0xFFFFFFFF

static func _i32(x: int) -> int:
	x = x & 0xFFFFFFFF
	return x - 0x100000000 if x >= 0x80000000 else x

static func _imul(x: int, y: int) -> int:
	# JS Math.imul: 32-bit signed multiply, low 32 bits.
	return _i32((_i32(x) * _i32(y)) & 0xFFFFFFFF)

func next() -> float:
	_a = _i32(_a + 0x6D2B79F5)
	var t := _imul(_a ^ (_u32(_a) >> 15), 1 | _a)
	var m := _imul(t ^ (_u32(t) >> 7), 61 | t)
	t = _i32(t + m) ^ t
	return float(_u32(t ^ (_u32(t) >> 14))) / 4294967296.0

## Convenience: integer in [0, n).
func next_int(n: int) -> int:
	return int(next() * n)
