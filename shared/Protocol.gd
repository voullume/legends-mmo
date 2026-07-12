extends RefCounted
## NETWORK PROTOCOL VERSION (stabilization P5) — the single constant both sides compare during
## authentication. The client sends {"protocol": VERSION, "build": BUILD} with its token; the server
## rejects a mismatch (with a player-facing reason via recv_denied) BEFORE doing any token work.
##
## BUMP `VERSION` (+1) whenever a change breaks an already-shipped client, i.e. any of:
##   • an RPC in client/Net.gd changes name, signature, argument shape, or @rpc annotation
##     (or the /root/Main/Net node path moves);
##   • the snapshot gains a REQUIRED field or changes the meaning of an existing one
##     (purely additive optional fields the old client ignores do NOT need a bump);
##   • the semantics of an intent payload change (movement dict keys, ability sequencing);
##   • the authentication/handshake flow itself changes;
##   • an item or progression read model changes incompatibly (what recv_* pushes mean).
## Matching deploy rule: server first, then clients — an old client against a new server gets a
## clean "please update" refusal instead of undefined RPC behavior.
##
## `BUILD` is a free-form build identifier carried in the hello for diagnostics; `hello()` leaves
## room for a capability list later — do NOT grow this into a negotiation framework.

const VERSION := 1
const BUILD := ""

static func hello() -> Dictionary:
	return {"protocol": VERSION, "build": BUILD}

static func compatible(v: int) -> bool:
	return v == VERSION

# untrusted-input-safe read of a hello dict's protocol field (0 = absent/malformed = incompatible)
static func hello_version(hello) -> int:
	if not (hello is Dictionary):
		return 0
	var v = (hello as Dictionary).get("protocol", 0)
	if v is int or v is float:
		var i := int(v)
		return i if i > 0 else 0
	return 0
