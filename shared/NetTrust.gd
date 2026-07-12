extends RefCounted
## Transport trust policy (stabilization P4) — the ONE place that decides how the zone server and
## clients treat DTLS certificates and plaintext ENet, split by profile:
##
##   PRODUCTION (env LEGENDS_ENV=production — the Docker image sets it):
##     server: refuses to start without DTLS + a PERSISTENT operator certificate/key
##             (LEGENDS_DTLS_CERT/LEGENDS_DTLS_KEY file paths, or LEGENDS_DTLS_CERT_PEM/
##              LEGENDS_DTLS_KEY_PEM contents — e.g. Fly secrets).
##     client (exported build): connects ONLY with the pinned zone certificate baked into the build
##             (res://client/zone_cert.pem, CN 'legends-zone') — full identity verification; missing
##             pin ⇒ FAIL CLOSED. Plaintext to a non-loopback host is never allowed.
##
##   DEVELOPMENT (running from source/editor):
##     server: --dtls with no operator cert falls back to an ephemeral self-signed cert (warned).
##     client: --dtls uses the pinned cert when present; otherwise requires the EXPLICIT
##             --insecure-dtls flag (encrypt but don't verify — loud warning). Plaintext is allowed
##             silently only to loopback; any other host needs the EXPLICIT --insecure flag.
##
## Certificate contract: the operator keypair MUST carry CN=legends-zone (see ZONE_CERT_CN) — the
## client pins the public cert and verifies that CN regardless of the IP/host it dials.
## Rotation: generate a new keypair (deploy/gen_zone_cert.sh), ship the new zone_cert.pem in a client
## update FIRST (clients can only pin one cert, so rotate during a maintenance window), then swap the
## server's key/cert and restart.

const ZONE_CERT_PATH := "res://client/zone_cert.pem"   # the client's pinned trust anchor (public cert — safe to commit)
const ZONE_CERT_CN := "legends-zone"                   # the CN the pinned verification expects

static func is_production() -> bool:
	return OS.get_environment("LEGENDS_ENV") == "production"

static func is_loopback(host: String) -> bool:
	return host in ["127.0.0.1", "localhost", "::1"]

# test/dev override for the pinned-cert location (editor builds only — an exported client's trust
# anchor is immutable).
static func zone_cert_path() -> String:
	if OS.has_feature("editor"):
		var o := OS.get_environment("LEGENDS_ZONE_CERT_PATH")
		if o != "":
			return o
	return ZONE_CERT_PATH

# ---- server side ----
# The TLS configuration the zone server must run DTLS with, or null = REFUSE TO START.
static func server_tls_options() -> TLSOptions:
	var cert_pem := OS.get_environment("LEGENDS_DTLS_CERT_PEM")
	var key_pem := OS.get_environment("LEGENDS_DTLS_KEY_PEM")
	if cert_pem != "" and key_pem != "":
		var k := CryptoKey.new()
		var c := X509Certificate.new()
		if k.load_from_string(key_pem) != OK or c.load_from_string(cert_pem) != OK:
			push_error("[trust] LEGENDS_DTLS_CERT_PEM/KEY_PEM are set but unparseable — refusing to start")
			return null
		print("[trust] DTLS: operator certificate (from env PEM)")
		return TLSOptions.server(k, c)
	var cert_path := OS.get_environment("LEGENDS_DTLS_CERT")
	var key_path := OS.get_environment("LEGENDS_DTLS_KEY")
	if cert_path != "" and key_path != "":
		var k2 := CryptoKey.new()
		var c2 := X509Certificate.new()
		if k2.load(key_path) != OK or c2.load(cert_path) != OK:
			push_error("[trust] LEGENDS_DTLS_CERT/LEGENDS_DTLS_KEY are set but unreadable (%s / %s) — refusing to start" % [cert_path, key_path])
			return null
		print("[trust] DTLS: operator certificate (%s)" % cert_path)
		return TLSOptions.server(k2, c2)
	if is_production():
		push_error("[trust] PRODUCTION requires a persistent DTLS certificate — set LEGENDS_DTLS_CERT/LEGENDS_DTLS_KEY (paths) or LEGENDS_DTLS_CERT_PEM/LEGENDS_DTLS_KEY_PEM (contents). deploy/setup.sh provisions these; see docs/stabilization.md.")
		return null
	print("[trust] ⚠ DEV DTLS: ephemeral self-signed certificate — clients can't verify it (connect with --insecure-dtls)")
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key, "CN=%s,O=Legends,C=US" % ZONE_CERT_CN)
	return TLSOptions.server(key, cert)

# ---- client side ----
# The TLS configuration a client may connect with, or null = FAIL CLOSED (do not connect).
static func client_tls_options(explicit_insecure: bool) -> TLSOptions:
	if explicit_insecure:
		if not OS.has_feature("editor"):
			push_error("[trust] --insecure-dtls is development-only and is IGNORED in an exported build")
			return null
		push_warning("[trust] ⚠⚠ INSECURE DTLS: encrypting but NOT verifying the server's identity (--insecure-dtls) — development only, never with a real account")
		return TLSOptions.client_unsafe()
	var path := zone_cert_path()
	if FileAccess.file_exists(path):
		var cert := X509Certificate.new()
		if cert.load(path) == OK:
			print("[trust] DTLS: pinned zone certificate (%s), verifying CN '%s'" % [path, ZONE_CERT_CN])
			return TLSOptions.client(cert, ZONE_CERT_CN)
		push_error("[trust] pinned certificate at %s failed to load — refusing an unverified connection" % path)
		return null
	push_error("[trust] no pinned zone certificate (%s) — refusing an UNVERIFIED encrypted connection. Ship the server's public cert in the build, or (from source, development only) pass --insecure-dtls." % path)
	return null

# May this client send its login token over PLAINTEXT ENet to `host`?
static func plaintext_allowed(host: String, explicit_insecure: bool) -> bool:
	if is_loopback(host):
		return true                                    # the local dev loop (play.sh dev/zone) stays frictionless
	if not OS.has_feature("editor"):
		return false                                   # an exported build never sends the token plaintext off-box
	if explicit_insecure:
		push_warning("[trust] ⚠⚠ PLAINTEXT ENet to %s (--insecure): the access token crosses the wire unencrypted — LAN/VPN development only" % host)
		return true
	return false
