extends Node
## Minimal Supabase Realtime client for one Postgres Changes subscription.
##
## Why a websocket instead of polling: the "another device logged in" kick has to
## land immediately. Polling profiles costs egress and always lags; one push per
## login costs a few dozen bytes and arrives in well under a second.
##
## Protocol (Phoenix Channels v2, what Supabase Realtime speaks):
##   connect  wss://<ref>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0
##   join     {"topic":"realtime:public:profiles","event":"phx_join",
##             "payload":{"config":{"postgres_changes":[{...}]},
##                        "access_token":"<jwt>"},"ref":"1"}
##   push     {"event":"postgres_changes","payload":{"data":{"record":{...}}}}
##   keepalive{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"n"}
## The server drops a connection that stops sending heartbeats, so one is sent
## every 25s. Reconnects use exponential backoff and always re-read the token.

signal record_changed(record: Dictionary)
signal connection_changed(connected: bool)

const SUPABASE_URL := "https://qckgvfpttdcsudxsdlxl.supabase.co"
const PUBLISHABLE_KEY := "sb_publishable_JsYu3wN1XFk4xGgD0sdiVQ_dNO9fnvZ"
const HEARTBEAT_SECONDS := 25.0
const RECONNECT_MIN := 2.0
const RECONNECT_MAX := 30.0
# Re-join periodically with a fresh JWT: the token in the join payload expires
# after an hour and the server then refuses the subscription.
const REJOIN_SECONDS := 50.0 * 60.0

var _peer: WebSocketPeer
var _topic := "realtime:public:profiles"
var _filter := ""
var _token := ""
var _connected := false
var _joined := false
var _ref := 0
var _next_heartbeat_ms := 0
var _next_rejoin_ms := 0
var _next_attempt_ms := 0
var _backoff := RECONNECT_MIN
var _last_error := ""
var _token_supplier: Callable


func subscribe(uid: String, access_token: String, token_supplier: Callable = Callable()) -> void:
	_filter = "id=eq." + uid
	_token = access_token
	_token_supplier = token_supplier
	_backoff = RECONNECT_MIN
	_next_attempt_ms = 0
	# unsubscribe() turns processing off; a later subscribe must turn it back on.
	set_process(true)
	_open()


func unsubscribe() -> void:
	_close()
	set_process(false)


func is_live() -> bool:
	return _connected and _joined


func last_error() -> String:
	return _last_error


func _open() -> void:
	_close()
	var base := SUPABASE_URL.replace("https://", "wss://")
	var url := "%s/realtime/v1/websocket?apikey=%s&vsn=1.0.0" % [base, PUBLISHABLE_KEY]
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = 65536
	_peer.outbound_buffer_size = 65536
	var err := _peer.connect_to_url(url)
	if err != OK:
		_last_error = "connect_failed_%d" % err
		_peer = null
		_schedule_retry()
		return
	print("REALTIME_CONNECTING")


func _close() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	_joined = false
	if _connected:
		_connected = false
		connection_changed.emit(false)


func _schedule_retry() -> void:
	_next_attempt_ms = Time.get_ticks_msec() + int(_backoff * 1000.0)
	_backoff = minf(_backoff * 2.0, RECONNECT_MAX)


func _next_ref() -> String:
	_ref += 1
	return str(_ref)


func _send(message: Dictionary) -> void:
	if _peer == null:
		return
	_peer.send_text(JSON.stringify(message))


func _join() -> void:
	_joined = true
	_send({
		"topic": _topic,
		"event": "phx_join",
		"payload": {
			"config": {
				"postgres_changes": [{
					"event": "UPDATE",
					"schema": "public",
					"table": "profiles",
					"filter": _filter,
				}],
			},
			"access_token": _token,
		},
		"ref": _next_ref(),
	})
	var now := Time.get_ticks_msec()
	_next_heartbeat_ms = now + int(HEARTBEAT_SECONDS * 1000.0)
	_next_rejoin_ms = now + int(REJOIN_SECONDS * 1000.0)


func _process(_dt: float) -> void:
	var now := Time.get_ticks_msec()
	if _peer == null:
		if now >= _next_attempt_ms:
			if _token_supplier.is_valid():
				var fresh: Variant = _token_supplier.call()
				if fresh is String and not str(fresh).is_empty():
					_token = str(fresh)
			_open()
		return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			connection_changed.emit(true)
		if not _joined:
			_join()
		# Drain into a buffer first, then handle. A handler can tear this socket
		# down (another device logged in), and touching _peer afterwards crashes.
		var packets: Array[String] = []
		while _peer != null and _peer.get_available_packet_count() > 0:
			packets.append(_peer.get_packet().get_string_from_utf8())
		for raw in packets:
			if _peer == null:
				break
			_handle(raw)
		if _peer == null:
			return
		if now >= _next_rejoin_ms:
			# JWT is about to expire: drop and re-join with a fresh one.
			print("REALTIME_REJOIN")
			_close()
			_next_attempt_ms = now
			return
		if now >= _next_heartbeat_ms:
			_next_heartbeat_ms = now + int(HEARTBEAT_SECONDS * 1000.0)
			_send({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": _next_ref()})
	elif state == WebSocketPeer.STATE_CLOSED:
		_last_error = "closed_%d" % _peer.get_close_code()
		print("REALTIME_CLOSED code=%d" % _peer.get_close_code())
		_close()
		_schedule_retry()


func _handle(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var message: Dictionary = parsed
	match str(message.get("event", "")):
		"phx_reply":
			var reply_variant: Variant = message.get("payload", {})
			var reply: Dictionary = reply_variant if reply_variant is Dictionary else {}
			if str(reply.get("status", "")) == "ok":
				print("REALTIME_JOINED")
				_backoff = RECONNECT_MIN
			else:
				_last_error = "join_rejected"
				print("REALTIME_JOIN_REJECTED %s" % JSON.stringify(reply).left(200))
				_close()
				_schedule_retry()
		"postgres_changes":
			var payload_variant: Variant = message.get("payload", {})
			var payload: Dictionary = payload_variant if payload_variant is Dictionary else {}
			var data_variant: Variant = payload.get("data", {})
			var data: Dictionary = data_variant if data_variant is Dictionary else {}
			# Supabase sends "record" in current builds and "new" in older ones;
			# either can be null, and a typed assignment from null would throw.
			var record_variant: Variant = data.get("record", null)
			if record_variant == null:
				record_variant = data.get("new", null)
			if not (record_variant is Dictionary):
				return
			var record: Dictionary = record_variant
			if not record.is_empty():
				record_changed.emit(record)
		"phx_error", "phx_close":
			_last_error = str(message.get("event", ""))
			print("REALTIME_CHANNEL_CLOSED %s" % _last_error)
			_close()
			_schedule_retry()
		"system":
			pass
