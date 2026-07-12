extends "res://server/Server.gd"
## Server.gd with ONLY the two transport seams stubbed for headless stabilization tests:
##   • _peer_live(pid) consults the harness's fake peer table instead of ENet;
##   • _transport_kick(pid) records the kick and mirrors the real transport by scheduling the same
##     peer-disconnected cleanup a real ENet drop would trigger (deferred, like the signal).
## _kick itself (the deny-reason send) is the PRODUCTION code under test.

var live_peers := {}            # pid -> true: peers the fake transport considers connected
var kicked: Array = []          # [{pid}] in order (reasons are asserted via the recv_denied sends)

func connect_peer(pid: int) -> void:
	live_peers[pid] = true
	_on_peer_connected(pid)

func drop_peer(pid: int) -> void:  # a client-side disconnect (graceful or not)
	live_peers.erase(pid)
	_on_peer_disconnected(pid)

func _peer_live(pid: int) -> bool:
	return live_peers.has(pid)

func _transport_kick(pid: int) -> void:
	kicked.append({"pid": pid})
	live_peers.erase(pid)
	# the real disconnect_peer() raises peer_disconnected on a later poll → defer the cleanup
	call_deferred("_on_peer_disconnected", pid)
