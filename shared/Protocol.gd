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
##   • an item or progression read model changes incompatibly (what recv_* pushes mean);
##   • a SHARED WORLD DATA FILE the server derives collision from changes — i.e. any
##     `data/decals/<map>.json` add/edit — ENFORCED by the `decal-protocol-guard` CI job, which
##     fails any PR that edits a decal file without moving VERSION in the same branch. The rule
##     lived only in this comment once, and shipped broken twice.
##     The client never computes decal collision (the snapshot
##     carries no obstacle list), so a client missing those records renders nothing where the
##     server blocks: the player slides along invisible walls. Backdrops (`data/backdrops/*.json`)
##     are render-only and do NOT need a bump.
## Matching deploy rule: server first, then clients — an old client against a new server gets a
## clean "please update" refusal instead of undefined RPC behavior.
##
## `BUILD` is a free-form build identifier carried in the hello for diagnostics; `hello()` leaves
## room for a capability list later — do NOT grow this into a negotiation framework.

const VERSION := 5   # v5: the Locale 1 DEPTH pass — data/decals/loc1_*.json give the five zones their
                     # dressing + decal collision (ridges/trees/compounds); a stale client would hit
                     # invisible walls. (v4: the cache RPC pair + the four greybox zones; v3: P5 decals)
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
