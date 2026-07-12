extends Node
## Stabilization-test double for client/Net.gd on the SERVER side (no transport, no client).
## Server.gd sends everything as `net.<rpc_name>.rpc_id(pid, ...)` — here EVERY property lookup
## resolves (via _get) to a Recorder whose rpc_id(...) captures the call into `sent` instead of
## touching ENet. Any RPC the server grows later is auto-recorded; nothing to keep in sync.

class Recorder:
	extends RefCounted
	var rpc_name: String
	var sent: Array
	func _init(n: String, log: Array) -> void:
		rpc_name = n
		sent = log
	# Server.gd calls rpc_id with 1..6 positional args; defaults soak up the unused tail.
	func rpc_id(pid = null, a = null, b = null, c = null, d = null, e = null) -> void:
		sent.append({"rpc": rpc_name, "pid": pid, "args": [a, b, c, d, e]})

var sent: Array = []            # every server→client send, in order: {rpc, pid, args[5]}
var _recorders := {}

func _get(prop: StringName) -> Variant:
	var key := str(prop)
	if not _recorders.has(key):
		_recorders[key] = Recorder.new(key, sent)
	return _recorders[key]

# all sends of one RPC (optionally to one peer), in order
func calls(rpc_name: String, pid = null) -> Array:
	var out := []
	for c in sent:
		if str(c["rpc"]) == rpc_name and (pid == null or int(c["pid"]) == int(pid)):
			out.append(c)
	return out

func clear() -> void:
	sent.clear()
