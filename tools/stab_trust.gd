extends SceneTree
## Stabilization P4 — TRANSPORT TRUST policy (shared/NetTrust.gd), headless:
##   • production server: no operator cert ⇒ REFUSES (null); operator cert (paths or PEM env) ⇒ runs;
##   • development server: no operator cert ⇒ ephemeral self-signed fallback (still encrypted);
##   • client: no pinned zone certificate ⇒ FAIL CLOSED (null); pinned cert ⇒ verifying options;
##     --insecure-dtls ⇒ allowed from source (editor) only, as an explicit unsafe override;
##   • plaintext: loopback always OK; non-loopback needs the explicit --insecure override (source only);
##   • the pinned CN contract is 'legends-zone'.
## Run: godot --headless --path . --script res://tools/stab_trust.gd

const NetTrust := preload("res://shared/NetTrust.gd")

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _clear_env() -> void:
	for k in ["LEGENDS_ENV", "LEGENDS_DTLS_CERT", "LEGENDS_DTLS_KEY",
			"LEGENDS_DTLS_CERT_PEM", "LEGENDS_DTLS_KEY_PEM", "LEGENDS_ZONE_CERT_PATH"]:
		OS.set_environment(k, "")

func _init() -> void:
	_clear_env()

	# ---- server: development fallback vs production fail-closed ----
	ok(NetTrust.server_tls_options() != null, "dev server: self-signed fallback works")
	OS.set_environment("LEGENDS_ENV", "production")
	ok(NetTrust.server_tls_options() == null, "prod server: NO cert ⇒ refuses to start")

	# ---- server: operator certificate via file paths ----
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key, "CN=legends-zone,O=Legends,C=US")
	var kp := OS.get_user_data_dir() + "/stab_zone.key"
	var cp := OS.get_user_data_dir() + "/stab_zone.crt"
	key.save(kp)
	cert.save(cp)
	OS.set_environment("LEGENDS_DTLS_CERT", cp)
	OS.set_environment("LEGENDS_DTLS_KEY", kp)
	ok(NetTrust.server_tls_options() != null, "prod server: operator cert files ⇒ starts")
	OS.set_environment("LEGENDS_DTLS_CERT", "/nonexistent.crt")
	ok(NetTrust.server_tls_options() == null, "prod server: unreadable cert path ⇒ refuses (never silent)")
	OS.set_environment("LEGENDS_DTLS_CERT", "")
	OS.set_environment("LEGENDS_DTLS_KEY", "")

	# ---- server: operator certificate via PEM contents (Fly-style secrets) ----
	OS.set_environment("LEGENDS_DTLS_CERT_PEM", cert.save_to_string())
	OS.set_environment("LEGENDS_DTLS_KEY_PEM", key.save_to_string())
	ok(NetTrust.server_tls_options() != null, "prod server: PEM env contents ⇒ starts")
	OS.set_environment("LEGENDS_DTLS_CERT_PEM", "garbage")
	ok(NetTrust.server_tls_options() == null, "prod server: unparseable PEM ⇒ refuses")
	OS.set_environment("LEGENDS_DTLS_CERT_PEM", "")
	OS.set_environment("LEGENDS_DTLS_KEY_PEM", "")

	# ---- client: pinned-cert verification, fail-closed, dev-only unsafe override ----
	OS.set_environment("LEGENDS_ZONE_CERT_PATH", OS.get_user_data_dir() + "/no_such_cert.pem")
	ok(NetTrust.client_tls_options(false) == null, "client: missing pinned cert ⇒ FAIL CLOSED")
	OS.set_environment("LEGENDS_ZONE_CERT_PATH", cp)
	ok(NetTrust.client_tls_options(false) != null, "client: pinned cert ⇒ verifying TLS options")
	ok(NetTrust.client_tls_options(true) != null, "client: --insecure-dtls allowed from source (explicit + warned)")
	ok(NetTrust.ZONE_CERT_CN == "legends-zone", "contract: the pinned CN is 'legends-zone'")

	# ---- plaintext policy ----
	ok(NetTrust.plaintext_allowed("127.0.0.1", false), "plaintext: loopback allowed (dev loop)")
	ok(NetTrust.plaintext_allowed("localhost", false), "plaintext: localhost allowed")
	ok(not NetTrust.plaintext_allowed("203.0.113.7", false), "plaintext: remote host REFUSED without --insecure")
	ok(NetTrust.plaintext_allowed("192.168.1.50", true), "plaintext: explicit --insecure override (source, warned)")

	# ---- profile flag ----
	ok(NetTrust.is_production(), "profile: LEGENDS_ENV=production detected")
	_clear_env()
	ok(not NetTrust.is_production(), "profile: default is development")

	print("=== stab_trust: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
