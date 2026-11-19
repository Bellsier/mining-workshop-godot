extends RefCounted
## Save JSON with exact numbers, read and written the way JavaScript does.
##
## Godot 4.4.1's own JSON is not exact (measured in CI): it reads some numbers as a neighbouring double
## ("1.1500000000000001" → 1.15), writes numbers nested in arrays and dictionaries with 15 significant
## digits, and reads "1e999" as infinity. A save written and read with it can change its own values.
##
## This reader rounds every number to the nearest double (ties to even), like JSON.parse in JavaScript,
## and rejects numbers outside the double range instead of turning them into infinity. The writer emits
## the shortest text that reads back as the same double, formatted like JSON.stringify in JavaScript,
## and refuses NaN and infinity. Text, objects and arrays follow RFC 8259; a leading byte order mark is
## skipped. Duplicate keys keep the last value, as in JavaScript.

const BASE := 10000000  # big integers: little-endian limbs of 7 decimal digits
const MAX_DEPTH := 256
const TWO_53 := 9007199254740992.0
const FRACTION_MASK := 0xFFFFFFFFFFFFF
const HIDDEN_BIT := 1 << 52

static var _exact_powers: Array[float] = []
static var _string_stop: RegEx
static var _needs_escape: RegEx


## {"ok": true, "value": value} or {"ok": false, "error": why}.
static func parse(text: String) -> Dictionary:
	var c := {"t": text, "p": 0, "n": text.length(), "e": ""}
	if c.n > 0 and text.unicode_at(0) == 0xFEFF:
		c.p = 1
	var value: Variant = _value(c, 0)
	if c.e.is_empty():
		_space(c)
		if c.p < c.n:
			_fail(c, "extra text after the value")
	if not c.e.is_empty():
		return {"ok": false, "error": c.e}
	return {"ok": true, "value": value}


## Compact JSON text, or "" if the value holds something JSON cannot carry (NaN, infinity, objects).
static func stringify(value: Variant, sort_keys := true) -> String:
	var parts := PackedStringArray()
	if not _write(value, parts, sort_keys, 0):
		return ""
	return "".join(parts)


## The JavaScript text of a finite double: shortest round-trip digits, JSON.stringify layout.
static func number_text(x: float) -> String:
	if x == 0.0:
		return "0"
	if x < 0.0:
		return "-" + number_text(-x)
	if x == floorf(x) and x < TWO_53:
		return str(int(x))
	var shortest := shortest_digits(x)
	var digits: String = shortest[0]
	var k := digits.length()
	var n: int = shortest[1] + k  # value = 0.digits × 10^n
	if k <= n and n <= 21:
		return digits + "0".repeat(n - k)
	if 0 < n and n <= 21:
		return digits.substr(0, n) + "." + digits.substr(n)
	if -6 < n and n <= 0:
		return "0." + "0".repeat(-n) + digits
	var mantissa := digits.substr(0, 1) + ("." + digits.substr(1) if k > 1 else "")
	return "%se%s%d" % [mantissa, "+" if n - 1 >= 0 else "-", absi(n - 1)]


## [digits, exponent] with value = digits × 10^exponent: the fewest digits that read back as x (x > 0).
static func shortest_digits(x: float) -> Array:
	var exact := _exact_decimal(x)
	# Below the smallest normal double precision is lower, so fewer than 15 digits can be the shortest.
	var precisions := range(1, 18) if x < _from_bits(0x0010000000000000) else [15, 16, 17]
	for precision: int in precisions:
		var rounded := _round_digits(exact[0], precision)
		var digits: String = rounded[0]
		var exponent: int = exact[1] + rounded[1]
		while digits.length() > 1 and digits.ends_with("0"):
			digits = digits.substr(0, digits.length() - 1)
			exponent += 1
		if precision == 17 or decimal_to_double(digits, exponent) == x:
			return [digits, exponent]
	return []


## The double nearest to digits × 10^exponent (digits: decimal digits only), ties to even. INF if too large.
static func decimal_to_double(digits: String, exponent: int) -> float:
	var first := 0
	while first < digits.length() and digits.unicode_at(first) == 48:
		first += 1
	var last := digits.length()
	while last > first and digits.unicode_at(last - 1) == 48:
		last -= 1
		exponent += 1
	if first == last:
		return 0.0
	digits = digits.substr(first, last - first)
	var count := digits.length()
	if count + exponent > 310:
		return INF
	if count + exponent <= -324:
		return 0.0
	if count <= 15 and absi(exponent) <= 22:
		# Both operands are exact doubles, so one IEEE operation rounds correctly (Clinger's fast path).
		var whole := float(digits.to_int())
		return whole * _power_of_ten(exponent) if exponent >= 0 else whole / _power_of_ten(-exponent)
	var guess := _guess(digits, exponent)
	if not is_finite(guess):
		guess = _from_bits(0x7FEFFFFFFFFFFFFF)
	elif guess <= 0.0:
		guess = _from_bits(1)
	return _correct(guess, _big_from_digits(digits), exponent)


## Within a few units in the last place of digits × 10^exponent (each step rounds once). Godot's own
## String.to_float is not used: it gives up on exponents near the ends of the double range.
static func _guess(digits: String, exponent: int) -> float:
	var head := digits.substr(0, 17)
	var scale := exponent + digits.length() - head.length()
	var x := float(head.to_int())
	while scale > 0:
		var step := mini(scale, 22)
		x *= _power_of_ten(step)
		scale -= step
	while scale < 0:
		var step := mini(-scale, 22)
		x /= _power_of_ten(step)
		scale += step
	return x


# --- reading ------------------------------------------------------------------------------------------

static func _fail(c: Dictionary, why: String) -> void:
	if c.e.is_empty():
		c.e = "%s (character %d)" % [why, c.p]


static func _peek(c: Dictionary) -> int:
	return c.t.unicode_at(c.p) if c.p < c.n else -1


static func _space(c: Dictionary) -> void:
	var text: String = c.t
	var p: int = c.p
	var n: int = c.n
	while p < n:
		var ch := text.unicode_at(p)
		if ch != 32 and ch != 10 and ch != 13 and ch != 9:
			break
		p += 1
	c.p = p


static func _value(c: Dictionary, depth: int) -> Variant:
	if depth > MAX_DEPTH:
		_fail(c, "nested too deeply")
		return null
	_space(c)
	var ch := _peek(c)
	if ch == 123:
		return _object(c, depth)
	if ch == 91:
		return _array(c, depth)
	if ch == 34:
		return _string(c)
	if ch == 116:
		return _word(c, "true", true)
	if ch == 102:
		return _word(c, "false", false)
	if ch == 110:
		return _word(c, "null", null)
	if ch == 45 or (ch >= 48 and ch <= 57):
		return _number(c)
	_fail(c, "unexpected end" if ch < 0 else "unexpected character")
	return null


static func _word(c: Dictionary, word: String, value: Variant) -> Variant:
	if c.t.substr(c.p, word.length()) != word:
		_fail(c, "unexpected word")
		return null
	c.p += word.length()
	return value


static func _object(c: Dictionary, depth: int) -> Variant:
	c.p += 1
	var result := {}
	_space(c)
	if _peek(c) == 125:
		c.p += 1
		return result
	while true:
		_space(c)
		if _peek(c) != 34:
			_fail(c, "expected a key")
			return null
		var key: Variant = _string(c)
		if not c.e.is_empty():
			return null
		_space(c)
		if _peek(c) != 58:
			_fail(c, "expected ':'")
			return null
		c.p += 1
		var item: Variant = _value(c, depth + 1)
		if not c.e.is_empty():
			return null
		result[key] = item
		_space(c)
		var ch := _peek(c)
		c.p += 1
		if ch == 125:
			return result
		if ch != 44:
			c.p -= 1
			_fail(c, "expected ',' or '}'")
			return null
	return null


static func _array(c: Dictionary, depth: int) -> Variant:
	c.p += 1
	var result := []
	_space(c)
	if _peek(c) == 93:
		c.p += 1
		return result
	while true:
		var item: Variant = _value(c, depth + 1)
		if not c.e.is_empty():
			return null
		result.append(item)
		_space(c)
		var ch := _peek(c)
		c.p += 1
		if ch == 93:
			return result
		if ch != 44:
			c.p -= 1
			_fail(c, "expected ',' or ']'")
			return null
	return null


static func _string(c: Dictionary) -> Variant:
	if _string_stop == null:
		_string_stop = RegEx.create_from_string("[\"\\\\\\x00-\\x1f]")
	var text: String = c.t
	var p: int = c.p + 1
	var parts := PackedStringArray()
	while true:
		var found := _string_stop.search(text, p)
		if found == null:
			c.p = c.n
			_fail(c, "unterminated string")
			return null
		var at := found.get_start()
		if at > p:
			parts.append(text.substr(p, at - p))
		var ch := text.unicode_at(at)
		if ch == 34:
			c.p = at + 1
			return "".join(parts)
		c.p = at
		if ch != 92:
			_fail(c, "control character in a string")
			return null
		var escape := text.unicode_at(at + 1) if at + 1 < c.n else -1
		p = at + 2
		match escape:
			34: parts.append("\"")
			92: parts.append("\\")
			47: parts.append("/")
			98: parts.append(char(8))
			102: parts.append(char(12))
			110: parts.append("\n")
			114: parts.append("\r")
			116: parts.append("\t")
			117:
				var code := _hex4(text, p)
				if code < 0:
					_fail(c, "bad \\u escape")
					return null
				p += 4
				if code >= 0xD800 and code <= 0xDBFF and text.substr(p, 2) == "\\u":
					var low := _hex4(text, p + 2)
					if low >= 0xDC00 and low <= 0xDFFF:
						code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
						p += 6
				# A lone surrogate is not a character Godot strings can hold.
				parts.append(char(0xFFFD if code >= 0xD800 and code <= 0xDFFF else code))
			_:
				_fail(c, "bad escape")
				return null
	return null


static func _hex4(text: String, p: int) -> int:
	if p + 4 > text.length():
		return -1
	var code := 0
	for index in 4:
		var ch := text.unicode_at(p + index)
		var digit := -1
		if ch >= 48 and ch <= 57:
			digit = ch - 48
		elif ch >= 65 and ch <= 70:
			digit = ch - 55
		elif ch >= 97 and ch <= 102:
			digit = ch - 87
		if digit < 0:
			return -1
		code = code * 16 + digit
	return code


static func _digits_end(text: String, p: int, n: int) -> int:
	while p < n:
		var ch := text.unicode_at(p)
		if ch < 48 or ch > 57:
			break
		p += 1
	return p


static func _number(c: Dictionary) -> Variant:
	var text: String = c.t
	var n: int = c.n
	var start: int = c.p
	var p := start
	var negative := text.unicode_at(p) == 45
	if negative:
		p += 1
	var whole_start := p
	var ch := text.unicode_at(p) if p < n else -1
	if ch == 48:
		p += 1
	elif ch >= 49 and ch <= 57:
		p = _digits_end(text, p, n)
	else:
		c.p = p
		_fail(c, "bad number")
		return null
	var digits := text.substr(whole_start, p - whole_start)
	var fraction_length := 0
	if p < n and text.unicode_at(p) == 46:
		var fraction_start := p + 1
		p = _digits_end(text, fraction_start, n)
		if p == fraction_start:
			c.p = p
			_fail(c, "bad number")
			return null
		fraction_length = p - fraction_start
		digits += text.substr(fraction_start, fraction_length)
	var exponent := 0
	if p < n and (text.unicode_at(p) == 101 or text.unicode_at(p) == 69):
		p += 1
		var sign := 1
		if p < n and (text.unicode_at(p) == 43 or text.unicode_at(p) == 45):
			sign = -1 if text.unicode_at(p) == 45 else 1
			p += 1
		var exponent_start := p
		p = _digits_end(text, p, n)
		if p == exponent_start:
			c.p = p
			_fail(c, "bad number")
			return null
		var exponent_text := text.substr(exponent_start, p - exponent_start).lstrip("0")
		# Far outside the double range either way; kept small enough not to overflow below.
		exponent = sign * (99999999 if exponent_text.length() > 8 else exponent_text.to_int())
	c.p = p
	var value := decimal_to_double(digits, exponent - fraction_length)
	if is_inf(value):
		c.p = start
		_fail(c, "number out of range")
		return null
	return -value if negative else value


# --- writing ------------------------------------------------------------------------------------------

static func _write(value: Variant, parts: PackedStringArray, sort_keys: bool, depth: int) -> bool:
	if depth > MAX_DEPTH:
		return false
	match typeof(value):
		TYPE_NIL:
			parts.append("null")
		TYPE_BOOL:
			parts.append("true" if value else "false")
		TYPE_INT:
			parts.append(str(value))
		TYPE_FLOAT:
			if not is_finite(value):
				return false
			parts.append(number_text(value))
		TYPE_STRING, TYPE_STRING_NAME:
			parts.append(_quote(str(value)))
		TYPE_ARRAY:
			parts.append("[")
			var first := true
			for item: Variant in value:
				if not first:
					parts.append(",")
				first = false
				if not _write(item, parts, sort_keys, depth + 1):
					return false
			parts.append("]")
		TYPE_DICTIONARY:
			var keys: Array = value.keys()
			for key: Variant in keys:
				if not key is String:
					return false
			if sort_keys:
				keys.sort()
			parts.append("{")
			var first := true
			for key: String in keys:
				if not first:
					parts.append(",")
				first = false
				parts.append(_quote(key))
				parts.append(":")
				if not _write(value[key], parts, sort_keys, depth + 1):
					return false
			parts.append("}")
		_:
			return false
	return true


static func _quote(text: String) -> String:
	if _needs_escape == null:
		_needs_escape = RegEx.create_from_string("[\"\\\\\\x00-\\x1f]")
	var found := _needs_escape.search_all(text)
	if found.is_empty():
		return "\"" + text + "\""
	var parts := PackedStringArray(["\""])
	var p := 0
	for match_: RegExMatch in found:
		var at := match_.get_start()
		parts.append(text.substr(p, at - p))
		var ch := text.unicode_at(at)
		match ch:
			34: parts.append("\\\"")
			92: parts.append("\\\\")
			8: parts.append("\\b")
			12: parts.append("\\f")
			10: parts.append("\\n")
			13: parts.append("\\r")
			9: parts.append("\\t")
			_: parts.append("\\u%04x" % ch)
		p = at + 1
	parts.append(text.substr(p))
	parts.append("\"")
	return "".join(parts)


# --- exact arithmetic ---------------------------------------------------------------------------------

static func _power_of_ten(exponent: int) -> float:
	if _exact_powers.is_empty():
		var power := 1.0
		for index in 23:
			_exact_powers.append(power)
			power *= 10.0
	return _exact_powers[exponent]


static func _bits(x: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, x)
	return bytes.decode_s64(0)


static func _from_bits(bits: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_s64(0, bits)
	return bytes.decode_double(0)


## [mantissa, binary exponent] with x = mantissa × 2^exponent, for x >= 0.
static func _split(x: float) -> Array:
	var bits := _bits(x)
	var biased := (bits >> 52) & 0x7FF
	var fraction := bits & FRACTION_MASK
	if biased == 0:
		return [fraction, -1074]
	return [fraction | HIDDEN_BIT, biased - 1075]


## Moves a nearby guess to the double nearest digits × 10^exponent, comparing exactly with the halfway
## points between neighbouring doubles.
static func _correct(x: float, digits: PackedInt64Array, exponent: int) -> float:
	for step in 4096:
		var bits := _bits(x)
		var biased := (bits >> 52) & 0x7FF
		var fraction := bits & FRACTION_MASK
		var parts := _split(x)
		var mantissa: int = parts[0]
		var power: int = parts[1]
		var odd := mantissa % 2 == 1
		var above := _compare(digits, exponent, 2 * mantissa + 1, power - 1)
		if above > 0 or (above == 0 and odd):
			if biased == 0x7FE and fraction == FRACTION_MASK:
				return INF
			x = _from_bits(bits + 1)
			continue
		if mantissa == 0:
			return x
		var below: int
		if fraction == 0 and biased > 1:
			# The double below is in the next lower binade, where doubles are twice as close.
			below = _compare(digits, exponent, 4 * mantissa - 1, power - 2)
		else:
			below = _compare(digits, exponent, 2 * mantissa - 1, power - 1)
		if below < 0 or (below == 0 and odd):
			x = _from_bits(bits - 1)
			continue
		return x
	return x


## Sign of digits × 10^exponent − half × 2^power.
static func _compare(digits: PackedInt64Array, exponent: int, half: int, power: int) -> int:
	var left := digits
	var right := _big_from_int(half)
	if exponent >= 0:
		left = _times_power_of_ten(left, exponent)
	else:
		right = _times_power_of_ten(right, -exponent)
	if power >= 0:
		right = _times_power_of_two(right, power)
	else:
		left = _times_power_of_two(left, -power)
	return _big_compare(left, right)


## [digits, exponent]: x (> 0) written out exactly, value = digits × 10^exponent.
static func _exact_decimal(x: float) -> Array:
	var parts := _split(x)
	var mantissa := _big_from_int(parts[0])
	var power: int = parts[1]
	if power >= 0:
		return [_big_to_digits(_times_power_of_two(mantissa, power)), 0]
	# m × 2^-k = m × 5^k × 10^-k
	return [_big_to_digits(_times_power_of_five(mantissa, -power)), power]


## [digits, extra exponent]: digits rounded to `precision` significant digits, half to even.
static func _round_digits(digits: String, precision: int) -> Array:
	if digits.length() <= precision:
		return [digits, 0]
	var head := digits.substr(0, precision)
	var rest := digits.substr(precision)
	var shift := rest.length()
	var first := rest.unicode_at(0) - 48
	var beyond_half := rest.substr(1).lstrip("0") != ""
	var round_up := first > 5 or (first == 5 and (beyond_half or (head.unicode_at(precision - 1) - 48) % 2 == 1))
	if round_up:
		head = str(head.to_int() + 1)
		if head.length() > precision:
			head = head.substr(0, precision)
			shift += 1
	return [head, shift]


@warning_ignore("integer_division")
static func _big_from_int(value: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	while value > 0:
		result.append(value % BASE)
		value /= BASE
	if result.is_empty():
		result.append(0)
	return result


static func _big_from_digits(digits: String) -> PackedInt64Array:
	var result := PackedInt64Array()
	var end := digits.length()
	while end > 0:
		var begin := maxi(0, end - 7)
		result.append(digits.substr(begin, end - begin).to_int())
		end = begin
	return result


static func _big_to_digits(value: PackedInt64Array) -> String:
	var top := value.size() - 1
	while top > 0 and value[top] == 0:
		top -= 1
	var parts := PackedStringArray([str(value[top])])
	for index in range(top - 1, -1, -1):
		parts.append("%07d" % value[index])
	return "".join(parts)


@warning_ignore("integer_division")
static func _times_small(value: PackedInt64Array, factor: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	result.resize(value.size())
	var carry := 0
	for index in value.size():
		var product := value[index] * factor + carry
		result[index] = product % BASE
		carry = product / BASE
	while carry > 0:
		result.append(carry % BASE)
		carry /= BASE
	return result


static func _times_power_of_two(value: PackedInt64Array, power: int) -> PackedInt64Array:
	while power >= 30:
		value = _times_small(value, 1 << 30)
		power -= 30
	return _times_small(value, 1 << power) if power > 0 else value


static func _times_power_of_five(value: PackedInt64Array, power: int) -> PackedInt64Array:
	while power >= 13:
		value = _times_small(value, 1220703125)
		power -= 13
	var factor := 1
	for index in power:
		factor *= 5
	return _times_small(value, factor) if power > 0 else value


@warning_ignore("integer_division")
static func _times_power_of_ten(value: PackedInt64Array, power: int) -> PackedInt64Array:
	if power <= 0:
		return value
	var shifted := PackedInt64Array()
	shifted.resize(power / 7)
	shifted.fill(0)
	shifted.append_array(value)
	var factor := 1
	for index in power % 7:
		factor *= 10
	return _times_small(shifted, factor) if factor > 1 else shifted


static func _big_compare(left: PackedInt64Array, right: PackedInt64Array) -> int:
	var a := left.size() - 1
	while a > 0 and left[a] == 0:
		a -= 1
	var b := right.size() - 1
	while b > 0 and right[b] == 0:
		b -= 1
	if a != b:
		return 1 if a > b else -1
	for index in range(a, -1, -1):
		if left[index] != right[index]:
			return 1 if left[index] > right[index] else -1
	return 0
