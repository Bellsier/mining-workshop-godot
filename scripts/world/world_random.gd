extends RefCounted
## Seeded random source: mulberry32, bit for bit the same as the JavaScript version used to build the
## test fixtures (tools/world/make_web_fixtures.cjs). The web game uses Math.random for its layouts; the
## Godot port takes a seed so a world can be rebuilt and tested. All arithmetic stays in unsigned 32 bits.

const MASK := 0xFFFFFFFF

var _a := 0

func _init(seed_value: int = 0) -> void:
	_a = seed_value & MASK

## Math.imul as an unsigned 32-bit result. Split so no product leaves 64-bit range.
static func imul(a: int, b: int) -> int:
	a &= MASK
	b &= MASK
	var lo := (a & 0xFFFF) * b
	var hi := ((a >> 16) * b) & 0xFFFF
	return (lo + (hi << 16)) & MASK

## The next value in [0, 1).
func next_float() -> float:
	_a = (_a + 0x6D2B79F5) & MASK
	var t := imul(_a ^ (_a >> 15), _a | 1)
	t = ((t + imul(t ^ (t >> 7), t | 61)) & MASK) ^ t
	return float((t ^ (t >> 14)) & MASK) / 4294967296.0

## A Callable for the generators' `random` argument.
func source() -> Callable:
	return next_float
