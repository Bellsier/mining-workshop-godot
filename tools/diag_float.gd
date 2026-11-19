extends SceneTree

func _initialize() -> void:
	var base := 115.0 / 100.0
	var next := base + 2.220446049250313e-16  # 1.1500000000000001 in JS
	var values := [next, base, 1.0 / 10.0 + 2.0 / 10.0, 1.0 / 3.0, 1180591620717411303424.0, 1e300, 5e-324, 123456.789, 9007199254740993.0, 1e21, 2.5e-7]
	for x: float in values:
		var reps := {
			"var_to_str": var_to_str(x), "str": str(x), "num17": String.num(x, 17), "pct17f": "%.17f" % x,
			"sci": String.num_scientific(x), "json_full": JSON.stringify(x, "", false, true), "json": JSON.stringify(x),
		}
		var line := "DIAG %s :" % var_to_str(x)
		for k: String in reps:
			var t: String = reps[k]
			var back_json: Variant = JSON.parse_string(t)
			var back_float := t.to_float()
			var back_var: Variant = str_to_var(t)
			line += " | %s=%s json_ok=%s to_float_ok=%s str_to_var_ok=%s" % [k, t, str(back_json is float and back_json == x), str(back_float == x), str((back_var is float or back_var is int) and float(back_var) == x)]
		print(line)
	# Is the parser correctly rounded? Exact 17-digit texts from JS (x.toPrecision(17)).
	var js := {"1.1500000000000001": next, "0.30000000000000004": 1.0 / 10.0 + 2.0 / 10.0, "0.33333333333333331": 1.0 / 3.0, "1.1499999999999999": base, "1.15": base}
	for t: String in js:
		var parsed: Variant = JSON.parse_string(t)
		print("DIAGPARSE %s json=%s to_float=%s" % [t, str(parsed == js[t]), str(t.to_float() == js[t])])
	print("DIAGEQ dict deep == ", {"a": {"b": [1.0, 2.0]}} == {"a": {"b": [1.0, 2.0]}}, " int-vs-float ", {"a": 1} == {"a": 1.0})
	print("DIAGINT int(1e300)=", int(1e300), " floori(1e30)=", floori(1e30), " int(INF)=", int(INF), " int(NAN)=", int(NAN))
	print("DIAGJSONINF ", JSON.parse_string("[1e999, -1e999]"), " stringify inf ", JSON.stringify([INF, NAN]))
	print("DIAGBYTES ", "a\r\nb😀한".to_utf8_buffer().hex_encode(), " ", "﻿{}".to_utf8_buffer().hex_encode(), " parse_bom=", JSON.parse_string("﻿{\"a\":1}"))
	quit(0)
