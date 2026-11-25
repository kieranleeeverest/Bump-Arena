extends RefCounted

# Supabase auth client: email/password sign-in, session persistence, token refresh.
# Use via preload("res://scripts/network/SupabaseClient.gd").new().
# Contract: sync methods (no await in body) can be called directly.
# Async methods (sign_up / sign_in / refresh_if_needed) contain await: callers MUST await to get bool.
# Success is determined ONLY by the awaited bool result, never by a signal.

const SUPABASE_URL := "https://qckgvfpttdcsudxsdlxl.supabase.co"
const PUBLISHABLE_KEY := "sb_publishable_JsYu3wN1XFk4xGgD0sdiVQ_dNO9fnvZ"
const SESSION_PATH := "user://supabase_session.json"
const SIGN_IN_TIMEOUT_SECONDS := 15.0

signal signed_in(user_id: String)
signal signed_out()
signal auth_failed(reason: String)

var _session: Dictionary = {}
# Last profile write failure, for callers that must show a real reason instead
# of a generic "sync failed". Codes: http_409 (nickname taken), no_rows_updated
# (no profile row for this account), http_403 (RLS), network_error / request_failed.
var last_profile_error := ""
# Why the last heartbeat returned false: "superseded" means another device logged
# into the same account and now owns the session.
var last_heartbeat_reason := ""

# --- Public API ------------------------------------------------------------

func sign_up(email: String, password: String) -> bool:
	var res: Dictionary = await _post("/auth/v1/signup", {"email": email, "password": password})
	return _handle_auth_result(res)


# 注册三态：拿到会话 / 已受理待邮箱验证 / 失败。
# 开启 Confirm email 后，/signup 只返回用户信息、不返回 access_token，
# 直接走 _handle_auth_result 会被判成失败，玩家会以为注册挂了。
func sign_up_with_status(email: String, password: String) -> Dictionary:
	var res: Dictionary = await _post("/auth/v1/signup", {"email": email, "password": password})
	# 注册三态排查用：把服务端原始响应打到控制台，失败时能直接看出是哪种响应
	if OS.has_feature("web"): print("SIGNUP_RAW ok=%s code=%s data=%s" % [str(res.get("ok", false)), str(res.get("code", -1)), JSON.stringify(res.get("data", null))])
	if not bool(res.get("ok", false)):
		return {"status": "error", "reason": str(res.get("reason", "unknown_error"))}
	var raw: Variant = res.get("data", null)
	if typeof(raw) != TYPE_DICTIONARY:
		return {"status": "error", "reason": "invalid_auth_response"}
	var data: Dictionary = raw
	if _apply_auth_data(data):
		return {"status": "session"}
	# 没有会话但拿到了用户标识：Supabase 已受理，等邮箱验证码
	var pending_email := str(data.get("email", ""))
	var user: Variant = data.get("user", null)
	if typeof(user) == TYPE_DICTIONARY:
		if pending_email.is_empty(): pending_email = str((user as Dictionary).get("email", ""))
	if not str(data.get("id", "")).is_empty() or not pending_email.is_empty() or not str(data.get("confirmation_sent_at", "")).is_empty():
		return {"status": "pending_confirmation", "email": pending_email if not pending_email.is_empty() else email}
	return {"status": "error", "reason": "missing_auth_fields"}


# 校验注册邮箱验证码（Supabase 原生 type=signup）。
# token 按字符串传，前导零必须保留；成功时服务端直接返回会话。
func verify_signup_otp(email: String, token: String) -> Dictionary:
	var res: Dictionary = await _post("/auth/v1/verify", {"type": "signup", "email": email, "token": token})
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "unknown_error"))}
	var raw: Variant = res.get("data", null)
	if typeof(raw) != TYPE_DICTIONARY or not _apply_auth_data(raw):
		return {"ok": false, "reason": "验证已通过但未取得会话，请重新登录"}
	return {"ok": true}


# 重发注册确认邮件（同一封模板，含 {{ .Token }}）
func resend_signup_otp(email: String) -> Dictionary:
	var res: Dictionary = await _post("/auth/v1/resend", {"type": "signup", "email": email})
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "unknown_error"))}
	return {"ok": true}


func sign_in(email: String, password: String) -> bool:
	var result := await sign_in_with_result(email, password)
	return _report_auth_result(result)


func sign_in_with_result(email: String, password: String) -> Dictionary:
	var result := await _request(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password",
		{"email": email, "password": password}, PackedStringArray(), SIGN_IN_TIMEOUT_SECONDS)
	return _accept_auth_result(result)


# Sync: load saved session data (including refresh_token) into memory only.
# No expiry check, no network, no clearing. Safe to call in _ready() without blocking.
func restore_session() -> bool:
	return _load_session_from_disk()


# Async: keep sessions with >60s remaining; otherwise refresh via refresh_token.
func refresh_if_needed() -> bool:
	var remain := float(_session.get("expires_at", 0.0)) - Time.get_unix_time_from_system()
	if remain > 60.0:
		return true
	return await _refresh()


# Sync: access token and user id present, and access token not expired.
func session_valid() -> bool:
	if str(_session.get("access_token", "")).is_empty():
		return false
	if str(_session.get("user_id", "")).is_empty():
		return false
	return Time.get_unix_time_from_system() < float(_session.get("expires_at", 0.0))


# Sync: a refresh_token is available for renewing the session.
func can_refresh() -> bool:
	return not str(_session.get("refresh_token", "")).is_empty()


func sign_out() -> void:
	_clear_session()
	signed_out.emit()


func current_user_id() -> String:
	return str(_session.get("user_id", ""))


# 当前账号的注册邮箱（资料页展示用）。老会话文件没有这个字段时返回空。
func account_email() -> String:
	return str(_session.get("email", ""))


func access_token() -> String:
	return str(_session.get("access_token", ""))

# --- Public: profile (business requests, need session + Bearer) ------------

# Async: fetch current user's profile. Returns {ok, username, avatar_key} or {ok:false, reason}.
func fetch_profile() -> Dictionary:
	if current_user_id().is_empty() or access_token().is_empty():
		return {"ok": false, "reason": "no_session"}
	if not await refresh_if_needed():
		return {"ok": false, "reason": "refresh_failed"}
	var uid := current_user_id()
	var endpoint := "/rest/v1/profiles?id=eq.%s&select=username,avatar_key,last_seen,signature,level" % _uri_component(uid)
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var rows: Variant = res.get("data", null)
	if typeof(rows) != TYPE_ARRAY:
		return {"ok": false, "reason": "invalid_response_body"}
	var arr: Array = rows
	if arr.is_empty():
		return {"ok": false, "reason": "profile_not_found"}
	var first: Variant = arr[0]
	if typeof(first) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "invalid_response_body"}
	var row: Dictionary = first
	return {
		"ok": true,
		"username": str(row.get("username", "")),
		"avatar_key": str(row.get("avatar_key", "")),
		"last_seen": str(row.get("last_seen", "")),
		"signature": str(row.get("signature", "")),
		"level": int(row.get("level", 1)),
	}


# Async: read another player's public profile (for the in-room player card).
# Returns {ok, username, signature, level, avatar_key, last_seen} or {ok:false, reason}.
func fetch_profile_by_id(user_id: String) -> Dictionary:
	var uid := user_id.strip_edges()
	if uid.is_empty():
		return {"ok": false, "reason": "empty_target"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var endpoint := "/rest/v1/profiles?id=eq.%s&select=username,signature,level,avatar_key,last_seen" % _uri_component(uid)
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var rows: Array = _array_data(res)
	if rows.is_empty() or typeof(rows[0]) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "profile_not_found"}
	var row: Dictionary = rows[0]
	return {
		"ok": true,
		"username": str(row.get("username", "")),
		"signature": str(row.get("signature", "")),
		"level": int(row.get("level", 1)),
		"avatar_key": str(row.get("avatar_key", "")),
		"last_seen": str(row.get("last_seen", "")),
	}


# Async: update current user's profile. Returns true only if exactly the row was updated.
# avatar_key only sent when non-empty; signature is always written (local is the source).
func push_profile(username: String, avatar_key: String = "", signature: String = "") -> bool:
	last_profile_error = ""
	if current_user_id().is_empty() or access_token().is_empty():
		last_profile_error = "no_session"
		return false
	if not await refresh_if_needed():
		last_profile_error = "refresh_failed"
		return false
	var payload := {"username": username, "signature": signature}
	if not avatar_key.is_empty():
		payload["avatar_key"] = avatar_key
	var endpoint := "/rest/v1/profiles?id=eq.%s" % _uri_component(current_user_id())
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_PATCH, endpoint, payload, headers)
	if not bool(res.get("ok", false)):
		last_profile_error = str(res.get("reason", "request_failed"))
		auth_failed.emit(last_profile_error)
		return false
	if not _rows_updated(res):
		# 200 with an empty array means the WHERE matched nothing: no profile row.
		last_profile_error = "no_rows_updated"
		return false
	return true


# Async: change the signed-in account's password. The password lives in Auth
# only; it is never copied into the profiles table.
# Returns {ok:true} or {ok:false, reason}.
func change_password(new_password: String) -> Dictionary:
	if new_password.length() < 6:
		return {"ok": false, "reason": "password_too_short"}
	if current_user_id().is_empty() or access_token().is_empty():
		return {"ok": false, "reason": "no_session"}
	if not await refresh_if_needed():
		return {"ok": false, "reason": "refresh_failed"}
	var res: Dictionary = await _request(HTTPClient.METHOD_PUT, "/auth/v1/user", {"password": new_password}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	return {"ok": true}


# Async: update last_seen to current UTC time (ISO8601). Reserved for Step 6 online presence.
# When session_id is given the PATCH only matches while this device still owns the
# profile row, which is how a second login kicks the first one offline.
func heartbeat(session_id: String = "") -> bool:
	last_heartbeat_reason = ""
	if current_user_id().is_empty() or access_token().is_empty():
		last_heartbeat_reason = "no_session"
		return false
	if not await refresh_if_needed():
		last_heartbeat_reason = "refresh_failed"
		return false
	var payload := {"last_seen": Time.get_datetime_string_from_system(true)}
	# Ask for the id only: a full row would multiply the cost of a 5s heartbeat.
	var endpoint := "/rest/v1/profiles?id=eq.%s&select=id" % _uri_component(current_user_id())
	if not session_id.is_empty():
		endpoint += "&session_id=eq.%s" % _uri_component(session_id)
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_PATCH, endpoint, payload, headers)
	if not bool(res.get("ok", false)):
		last_heartbeat_reason = str(res.get("reason", "request_failed"))
		auth_failed.emit(last_heartbeat_reason)
		return false
	if not _rows_updated(res):
		# 200 + [] means the WHERE matched nothing: another device took over.
		last_heartbeat_reason = "superseded" if not session_id.is_empty() else "no_rows_updated"
		return false
	return true


# Async: mark this device as the account's single active session.
# Requires the profiles.session_id column (see docs/单端登录.sql).
func claim_session(session_id: String) -> bool:
	if session_id.is_empty() or current_user_id().is_empty() or access_token().is_empty():
		return false
	if not await refresh_if_needed():
		return false
	var endpoint := "/rest/v1/profiles?id=eq.%s" % _uri_component(current_user_id())
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_PATCH, endpoint, {"session_id": session_id}, headers)
	if not bool(res.get("ok", false)):
		return false
	return _rows_updated(res)


# --- Public: friends (Step 5) ----------------------------------------------
# Table shapes verified against the live project:
#   profiles(id, username, avatar_key, last_seen, created_at, updated_at)
#   friendships(user_a, user_b, created_at)   -- check(friendships_ordered): user_a < user_b
#   friend_requests(id, from_user, to_user, status, created_at, responded_at)
#       status is limited to 'pending' / 'accepted'; a rejected request is DELETEd.
#   v_friendships(owner_id, friend_id, created_at)  -- symmetric friendship, one row per owner
# RLS decides identity: inserts must still send from_user/user_a, but the policy
# only accepts rows where the caller is a party, so the server is the authority.

const PROFILE_COLUMNS := "id,username,avatar_key,last_seen"

# Async: case-insensitive username search, self excluded.
# Returns {ok:true, rows:[{id, username, avatar_key, last_seen}]} or {ok:false, reason}.
func search_profiles(query: String, max_rows: int = 10) -> Dictionary:
	var q := query.strip_edges()
	if q.is_empty():
		return {"ok": false, "reason": "empty_query"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var endpoint := "/rest/v1/profiles?select=%s&username=ilike.%s&id=neq.%s&order=username.asc&limit=%d" % [
		PROFILE_COLUMNS, _uri_component("*%s*" % q), _uri_component(current_user_id()), max_rows,
	]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	return {"ok": true, "rows": _array_data(res)}


# Async: send a friend request to another player.
# Returns {ok:true, status:"sent"} or {ok:false, reason}.
# reason: empty_target | self | already_friend | already_pending | incoming_pending | ...
func send_friend_request(to_user: String) -> Dictionary:
	var target := to_user.strip_edges()
	if target.is_empty():
		return {"ok": false, "reason": "empty_target"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var me := current_user_id()
	if target == me:
		return {"ok": false, "reason": "self"}
	if await _is_friend_with(target):
		return {"ok": false, "reason": "already_friend"}
	if await _has_pending_request(me, target):
		return {"ok": false, "reason": "already_pending"}
	# The other side already asked us. Do NOT auto-accept: the player must see the
	# incoming request and confirm it, otherwise friends appear out of nowhere.
	# The profile card offers a dedicated "accept request" action for this state.
	if await _has_pending_request(target, me):
		return {"ok": false, "reason": "incoming_pending"}
	var endpoint := "/rest/v1/friend_requests"
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_POST, endpoint,
		{"from_user": me, "to_user": target, "status": "pending"}, headers)
	if not bool(res.get("ok", false)):
		var reason := str(res.get("reason", "request_failed"))
		# Unique index on (from_user, to_user): a concurrent duplicate is still "pending".
		if "duplicate key" in reason or reason.contains("23505"):
			return {"ok": false, "reason": "already_pending"}
		return {"ok": false, "reason": reason}
	if not _rows_updated(res):
		return {"ok": false, "reason": "not_created"}
	return {"ok": true, "status": "sent"}


# Async: friend requests addressed to me, newest first, with sender usernames.
# Returns {ok:true, rows:[{id, from_user, username, created_at}]} or {ok:false, reason}.
func list_pending_requests() -> Dictionary:
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	# Only select columns proven readable by the pending-check query. Asking for
	# created_at made the whole request fail on this project (column-level grant),
	# which surfaced as an empty inbox while the same row was still visible to
	# `_has_pending_request`. Ordering is dropped for the same reason.
	var endpoint := "/rest/v1/friend_requests?select=id,from_user&to_user=eq.%s&status=eq.pending" % _uri_component(current_user_id())
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var source: Array = _array_data(res)
	var ids: Array[String] = []
	for item in source:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var uid := str((item as Dictionary).get("from_user", ""))
		if not uid.is_empty():
			ids.append(uid)
	var names: Dictionary = await _usernames_for(ids)
	var rows: Array[Dictionary] = []
	for item in source:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = item
		var uid := str(row.get("from_user", ""))
		rows.append({
			"id": str(row.get("id", "")),
			"from_user": uid,
			"username": str(names.get(uid, "未知玩家")),
			"created_at": "",
		})
	return {"ok": true, "rows": rows}


# Async: accept or reject one incoming request.
# accept=true  -> status becomes 'accepted' and the friendship row is ensured.
# accept=false -> the request row is deleted (status has no 'rejected' value by design).
# Returns {ok:true} or {ok:false, reason}.
func respond_request(request_id: String, accept: bool) -> Dictionary:
	var rid := request_id.strip_edges()
	if rid.is_empty():
		return {"ok": false, "reason": "empty_request_id"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var endpoint := "/rest/v1/friend_requests?id=eq.%s&status=eq.pending" % _uri_component(rid)
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	if not accept:
		var del: Dictionary = await _request(HTTPClient.METHOD_DELETE, endpoint, {}, headers)
		if not bool(del.get("ok", false)):
			return {"ok": false, "reason": str(del.get("reason", "request_failed"))}
		if not _rows_updated(del):
			return {"ok": false, "reason": "request_not_found_or_not_permitted"}
		return {"ok": true}
	var payload := {"status": "accepted", "responded_at": Time.get_datetime_string_from_system(true)}
	var res: Dictionary = await _request(HTTPClient.METHOD_PATCH, endpoint, payload, headers)
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var rows: Array = _array_data(res)
	if rows.is_empty() or typeof(rows[0]) != TYPE_DICTIONARY:
		# Zero rows updated: the request was already handled or is not addressed to me.
		return {"ok": false, "reason": "request_not_found_or_not_permitted"}
	var from_user := str((rows[0] as Dictionary).get("from_user", ""))
	if from_user.is_empty():
		return {"ok": false, "reason": "missing_from_user"}
	# A DB trigger may already have created the friendship; the insert is idempotent.
	if not await _ensure_friendship(from_user):
		return {"ok": false, "reason": "friendship_failed"}
	return {"ok": true}


# Async: my friends with profile info, newest first.
# Returns {ok:true, rows:[{id, username, avatar_key, last_seen, since}]} or {ok:false, reason}.
func list_friends() -> Dictionary:
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var endpoint := "/rest/v1/v_friendships?select=friend_id,created_at&owner_id=eq.%s&order=created_at.desc" % _uri_component(current_user_id())
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var links: Array = _array_data(res)
	var ids: Array[String] = []
	for item in links:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var fid := str((item as Dictionary).get("friend_id", ""))
		if not fid.is_empty():
			ids.append(fid)
	if ids.is_empty():
		return {"ok": true, "rows": []}
	var profiles: Dictionary = await _profiles_for(ids)
	var rows: Array[Dictionary] = []
	for item in links:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var fid := str((item as Dictionary).get("friend_id", ""))
		var profile: Dictionary = profiles.get(fid, {})
		rows.append({
			"id": fid,
			"username": str(profile.get("username", "未知玩家")),
			"avatar_key": str(profile.get("avatar_key", "")),
			"last_seen": str(profile.get("last_seen", "")),
			"since": str((item as Dictionary).get("created_at", "")),
		})
	return {"ok": true, "rows": rows}


# --- Public: direct messages (Step 5.5) -------------------------------------
# Table: messages(id, from_user, to_user, body, created_at), max 500 chars,
# RLS lets a user read only rows where they are sender or recipient, and insert
# only with from_user = auth.uid(). No update/delete policy on purpose.

const MESSAGE_MAX_CHARS := 500
const MESSAGE_COLUMNS := "id,from_user,to_user,body,created_at"

# Async: send one message. Returns {ok:true, id} or {ok:false, reason}.
func send_message(to_user: String, body: String) -> Dictionary:
	var target := to_user.strip_edges()
	var text := body.strip_edges()
	if target.is_empty():
		return {"ok": false, "reason": "empty_target"}
	if text.is_empty():
		return {"ok": false, "reason": "body_empty"}
	if text.length() > MESSAGE_MAX_CHARS:
		return {"ok": false, "reason": "body_too_long"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var me := current_user_id()
	if target == me:
		return {"ok": false, "reason": "self"}
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_POST, "/rest/v1/messages",
		{"from_user": me, "to_user": target, "body": text}, headers)
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var rows: Array = _array_data(res)
	if rows.is_empty() or typeof(rows[0]) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "not_created"}
	return {"ok": true, "id": str((rows[0] as Dictionary).get("id", ""))}


# Async: newest `limit` messages between me and `other`, returned oldest first.
func list_messages(other: String, limit: int = 30) -> Dictionary:
	var peer := other.strip_edges()
	if peer.is_empty():
		return {"ok": false, "reason": "empty_target"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var me := current_user_id()
	# Both directions in one query. Parens/commas stay raw: PostgREST parses them.
	var pair := "or=(and(from_user.eq.%s,to_user.eq.%s),and(from_user.eq.%s,to_user.eq.%s))" % [me, peer, peer, me]
	var endpoint := "/rest/v1/messages?select=%s&%s&order=created_at.desc&limit=%d" % [MESSAGE_COLUMNS, pair, maxi(limit, 1)]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	var rows: Array = _array_data(res)
	rows.reverse()
	return {"ok": true, "rows": rows}


# Async: newest `limit` messages addressed to me by anyone, newest first.
# One request feeds the unread badge for every friend, so a 5s poll costs a single
# small row set instead of one query per friend. Body is not selected on purpose:
# the badge only needs "who wrote when", and egress is the scarce quota.
const INCOMING_COLUMNS := "id,from_user,created_at"

func list_incoming_messages(limit: int = 100) -> Dictionary:
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var me := current_user_id()
	var endpoint := "/rest/v1/messages?select=%s&to_user=eq.%s&order=created_at.desc&limit=%d" % [INCOMING_COLUMNS, me, maxi(limit, 1)]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "request_failed"))}
	return {"ok": true, "rows": _array_data(res)}


# --- Public: avatar storage (Step 5.5) --------------------------------------
# Bucket "avatars" is public-read; writes are restricted by RLS to avatars/<uid>/.
# avatar_key stores an upload timestamp so the public URL can bust the CDN cache.

const AVATAR_BUCKET := "avatars"
# 好友私聊的图片/动图：公开读、仅本人可写。消息体里只存一行 [[img:WxH]]<url>。
const CHAT_MEDIA_BUCKET := "chat_media"

static func avatar_object_path(user_id: String) -> String:
	return "%s/avatar.png" % user_id


# Public URL for a stored avatar; cache_key (profiles.avatar_key) is appended as ?v=.
static func avatar_public_url(user_id: String, cache_key: String) -> String:
	var url := "%s/storage/v1/object/public/%s/%s" % [SUPABASE_URL, AVATAR_BUCKET, avatar_object_path(user_id)]
	if not cache_key.is_empty():
		url += "?v=" + cache_key.uri_encode()
	return url


# Async: upload PNG bytes as the current user's avatar, then stamp avatar_key.
# Returns {ok:true, avatar_key} or {ok:false, reason}.
func upload_avatar(png_bytes: PackedByteArray) -> Dictionary:
	if png_bytes.is_empty():
		return {"ok": false, "reason": "empty_image"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var uid := current_user_id()
	var endpoint := "/storage/v1/object/%s/%s" % [AVATAR_BUCKET, avatar_object_path(uid)]
	var headers := PackedStringArray([
		"apikey: " + PUBLISHABLE_KEY,
		"Authorization: Bearer " + access_token(),
		"Content-Type: image/png",
		"x-upsert: true",
	])
	var res: Dictionary = await _request_bytes(HTTPClient.METHOD_POST, endpoint, png_bytes, headers)
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "upload_failed"))}
	# Milliseconds, so two uploads in the same second still bust the CDN cache.
	var stamp := str(int(Time.get_unix_time_from_system() * 1000.0))
	var pushed: bool = await push_profile_avatar_key(stamp)
	if not pushed:
		return {"ok": false, "reason": "avatar_key_not_saved"}
	return {"ok": true, "avatar_key": stamp}


func chat_media_public_url(path: String) -> String:
	return "%s/storage/v1/object/public/%s/%s" % [SUPABASE_URL, CHAT_MEDIA_BUCKET, path]


# Async: upload one chat image/GIF to Storage and return its public URL.
# 2MB 上限由桶本身拦着，这里先自己挡一次，省一个来回。
func upload_chat_media(bytes: PackedByteArray, mime: String) -> Dictionary:
	if bytes.is_empty():
		return {"ok": false, "reason": "empty_image"}
	if bytes.size() > 2 * 1024 * 1024:
		return {"ok": false, "reason": "too_large"}
	var ext := "png"
	match mime:
		"image/jpeg":
			ext = "jpg"
		"image/gif":
			ext = "gif"
		"image/png":
			ext = "png"
		_:
			return {"ok": false, "reason": "bad_type"}
	if not await _ready_for_business():
		return {"ok": false, "reason": "no_session"}
	var uid := current_user_id()
	if uid.is_empty():
		return {"ok": false, "reason": "no_session"}
	# 毫秒时间戳：同一秒连传两张也不会互相覆盖
	var stamp := str(int(Time.get_unix_time_from_system() * 1000.0))
	var path := "%s/%s.%s" % [uid, stamp, ext]
	var endpoint := "/storage/v1/object/%s/%s" % [CHAT_MEDIA_BUCKET, path]
	var headers := PackedStringArray([
		"apikey: " + PUBLISHABLE_KEY,
		"Authorization: Bearer " + access_token(),
		"Content-Type: " + mime,
		"x-upsert: true",
	])
	var res: Dictionary = await _request_bytes(HTTPClient.METHOD_POST, endpoint, bytes, headers)
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "upload_failed"))}
	return {"ok": true, "url": chat_media_public_url(path)}


# Async: PATCH only avatar_key, leaving the username untouched.
func push_profile_avatar_key(avatar_key: String) -> bool:
	if current_user_id().is_empty() or access_token().is_empty():
		return false
	var endpoint := "/rest/v1/profiles?id=eq.%s" % _uri_component(current_user_id())
	var headers := _auth_headers()
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_PATCH, endpoint, {"avatar_key": avatar_key}, headers)
	if not bool(res.get("ok", false)):
		return false
	return _rows_updated(res)


# Async: download raw bytes from a public object URL (no auth header needed).
func download_bytes(url: String) -> Dictionary:
	var res: Dictionary = await _request_bytes(HTTPClient.METHOD_GET, url, PackedByteArray(), PackedStringArray(), true)
	if not bool(res.get("ok", false)):
		return {"ok": false, "reason": str(res.get("reason", "download_failed"))}
	return {"ok": true, "bytes": res.get("bytes", PackedByteArray())}


# Session + token freshness gate shared by the friend endpoints.
func _ready_for_business() -> bool:
	if current_user_id().is_empty() or access_token().is_empty():
		return false
	return await refresh_if_needed()


# Async: how the signed-in user relates to another account.
# "friend" (already friends) | "requested" (outgoing request pending) | "none"
func friend_status(other_id: String) -> String:
	if other_id.is_empty() or other_id == current_user_id():
		return "none"
	if await _is_friend_with(other_id):
		return "friend"
	if await _has_pending_request(current_user_id(), other_id):
		return "requested"
	if await _has_pending_request(other_id, current_user_id()):
		return "incoming"
	return "none"


# Async: remove a friendship. Returns true only when a row was actually deleted:
# or an empty array means the WHERE matched nothing, which is not a success.
func remove_friend(other_id: String) -> bool:
	if other_id.is_empty() or other_id == current_user_id():
		return false
	if not await refresh_if_needed():
		return false
	var pair := _ordered_pair(current_user_id(), other_id)
	var endpoint := "/rest/v1/friendships?user_a=eq.%s&user_b=eq.%s" % [
		_uri_component(pair[0]), _uri_component(pair[1]),
	]
	var headers := _auth_headers()
	# Without representation a DELETE returns 204 and "deleted" cannot be told
	# apart from "nothing matched".
	headers.append("Prefer: return=representation")
	var res: Dictionary = await _request(HTTPClient.METHOD_DELETE, endpoint, {}, headers)
	if not bool(res.get("ok", false)):
		return false
	return _rows_updated(res)


# Async: accept the pending request this account received from `from_id`.
# Returns true only when the request was actually found and accepted.
func accept_friend_request_from(from_id: String) -> bool:
	var endpoint := "/rest/v1/friend_requests?select=id&from_user=eq.%s&to_user=eq.%s&status=eq.pending&limit=1" % [
		_uri_component(from_id), _uri_component(current_user_id()),
	]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return false
	var rows: Array = _array_data(res)
	if rows.is_empty():
		return false
	var row: Dictionary = rows[0]
	var rid := str(row.get("id", ""))
	if rid.is_empty():
		return false
	var accepted: Dictionary = await respond_request(rid, true)
	return bool(accepted.get("ok", false))


func _is_friend_with(other: String) -> bool:
	var pair := _ordered_pair(current_user_id(), other)
	var endpoint := "/rest/v1/friendships?select=user_a&user_a=eq.%s&user_b=eq.%s&limit=1" % [
		_uri_component(pair[0]), _uri_component(pair[1]),
	]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return false
	return not _array_data(res).is_empty()


func _has_pending_request(from_id: String, to_id: String) -> bool:
	var endpoint := "/rest/v1/friend_requests?select=id&from_user=eq.%s&to_user=eq.%s&status=eq.pending&limit=1" % [
		_uri_component(from_id), _uri_component(to_id),
	]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return false
	return not _array_data(res).is_empty()


# Insert the friendship row. Idempotent: ignore-duplicates keeps an existing row intact
# (whether it was created by a trigger or by an earlier accept).
func _ensure_friendship(other: String) -> bool:
	var pair := _ordered_pair(current_user_id(), other)
	var headers := _auth_headers()
	headers.append("Prefer: return=representation,resolution=ignore-duplicates")
	var res: Dictionary = await _request(HTTPClient.METHOD_POST, "/rest/v1/friendships",
		{"user_a": pair[0], "user_b": pair[1]}, headers)
	return bool(res.get("ok", false))


# friendships_ordered requires user_a < user_b (compared as text).
func _ordered_pair(left: String, right: String) -> Array[String]:
	if left <= right:
		return [left, right]
	return [right, left]


func _profiles_for(ids: Array[String]) -> Dictionary:
	if ids.is_empty():
		return {}
	var list := ",".join(ids)
	var endpoint := "/rest/v1/profiles?select=%s&id=in.%s" % [PROFILE_COLUMNS, _uri_component("(%s)" % list)]
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, endpoint, {}, _auth_headers())
	if not bool(res.get("ok", false)):
		return {}
	return _index_by_id(_array_data(res))


func _usernames_for(ids: Array[String]) -> Dictionary:
	var profiles := await _profiles_for(ids)
	var names := {}
	for uid in profiles.keys():
		names[uid] = str((profiles[uid] as Dictionary).get("username", ""))
	return names


func _index_by_id(rows: Array) -> Dictionary:
	var indexed := {}
	for item in rows:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = item
		var uid := str(row.get("id", ""))
		if not uid.is_empty():
			indexed[uid] = row
	return indexed


func _array_data(res: Dictionary) -> Array:
	var rows: Variant = res.get("data", null)
	if typeof(rows) != TYPE_ARRAY:
		return []
	return rows


# True only if the representation body is a non-empty array (i.e. at least one row updated).
func _rows_updated(res: Dictionary) -> bool:
	var rows: Variant = res.get("data", null)
	if typeof(rows) != TYPE_ARRAY:
		return false
	return not (rows as Array).is_empty()


# Minimal percent-encoding for a query value (uuid is url-safe, encodes defensively).
func _uri_component(value: String) -> String:
	return value.uri_encode()

# --- Private: auth result handling -----------------------------------------

func _handle_auth_result(res: Dictionary) -> bool:
	return _report_auth_result(_accept_auth_result(res))


func _report_auth_result(res: Dictionary) -> bool:
	if not bool(res.get("ok", false)):
		auth_failed.emit(str(res.get("reason", "unknown_error")))
		return false
	return true


func _accept_auth_result(res: Dictionary) -> Dictionary:
	if not bool(res.get("ok", false)):
		return res
	var raw: Variant = res.get("data", null)
	if typeof(raw) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "invalid_auth_response"}
	if not _apply_auth_data(raw):
		return {"ok": false, "reason": "missing_auth_fields"}
	# No signed_in emit here: success is determined solely by the awaited bool.
	return {"ok": true}


func _apply_auth_data(data: Dictionary) -> bool:
	var token := str(data.get("access_token", ""))
	var refresh := str(data.get("refresh_token", ""))
	var uid := ""
	var user_email := ""
	var user: Variant = data.get("user", null)
	if typeof(user) == TYPE_DICTIONARY:
		uid = str((user as Dictionary).get("id", ""))
		user_email = str((user as Dictionary).get("email", ""))
	# 注册响应（待邮箱验证）没有 user 包裹层，email 在顶层
	if user_email.is_empty():
		user_email = str(data.get("email", ""))
	# token 刷新响应不含 email，沿用旧值，否则资料页的邮箱会在刷新后变空
	if user_email.is_empty():
		user_email = str(_session.get("email", ""))
	if token.is_empty() or refresh.is_empty() or uid.is_empty():
		return false
	_session = {
		"access_token": token,
		"refresh_token": refresh,
		"expires_at": Time.get_unix_time_from_system() + float(data.get("expires_in", 0)),
		"user_id": uid,
		"email": user_email,
	}
	_save_session()
	return true


func _refresh() -> bool:
	var refresh_token := str(_session.get("refresh_token", ""))
	if refresh_token.is_empty():
		auth_failed.emit("no_refresh_token")
		_clear_session()
		return false
	# 8 秒超时：启动阶段会 await 这一步，网络不通时不能把首屏一起拖死。
	var res: Dictionary = await _post("/auth/v1/token?grant_type=refresh_token", {"refresh_token": refresh_token}, 8.0)
	if not bool(res.get("ok", false)):
		# Supabase 的 refresh token 是**一次性**的：另一个标签页 / iOS 主屏 WebClip
		# 可能刚用同一个 token 换过新的一对。磁盘上如果已经是别的 refresh_token，
		# 说明别人刷成功了，直接采用，绝不要把本地登录态清掉——
		# 那正是"用着用着突然要求重新登录"的来源。
		if _adopt_disk_session(refresh_token):
			return true
		var reason := str(res.get("reason", "refresh_failed"))
		auth_failed.emit(reason)
		# 网络层失败（断网/超时/请求没发出去）不代表凭证失效：保留磁盘会话，
		# 下次启动还能再试。只有 Supabase 明确拒绝（HTTP 4xx）才真的清掉。
		if reason.begins_with("network_error") or reason.begins_with("request_failed"):
			print("SESSION_REFRESH_OFFLINE reason=%s (session kept)" % reason)
			return false
		_clear_session()
		return false
	var data: Dictionary = res.get("data", {})
	if not _apply_auth_data(data):
		auth_failed.emit("missing_auth_fields")
		_clear_session()
		return false
	return true

# 刷新失败后的一次兜底：看看磁盘上的会话是不是已经被别的实例刷新过了。
# 只有 refresh_token 与失败时用的那个不同才算数，否则就是真的过期。
func _adopt_disk_session(stale_refresh: String) -> bool:
	var previous := _session
	if not _load_session_from_disk():
		_session = previous
		return false
	if str(_session.get("refresh_token", "")) == stale_refresh:
		_session = previous
		return false
	print("SESSION_ADOPT from_disk reason=rotated_elsewhere")
	return true

# --- Private: HTTP ---------------------------------------------------------

# Generic request. Auth endpoints use _post(); business endpoints pass _auth_headers() (+ optional Prefer).
# Success "data" may be a Dictionary (auth) or an Array (PostgREST list/representation).
func _request(method: HTTPClient.Method, endpoint: String, payload_dict: Dictionary, extra_headers: PackedStringArray = PackedStringArray(), timeout := 0.0) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return {"ok": false, "reason": "no_scene_tree"}
	var req := HTTPRequest.new()
	req.timeout = timeout
	# Web: the browser already inflates the body, then Godot sees
	# Content-Encoding: gzip and decompresses again -> RESULT_BODY_DECOMPRESS_FAILED.
	# Asking for identity bodies is the only reliable fix on that platform.
	req.accept_gzip = not OS.has_feature("web")
	tree.root.add_child(req)
	var headers := PackedStringArray([
		"apikey: " + PUBLISHABLE_KEY,
		"Content-Type: application/json",
	])
	var seen := {"apikey": true, "Content-Type": true}
	for h in extra_headers:
		var key := h.get_slice(":", 0).strip_edges()
		if seen.has(key):
			continue
		seen[key] = true
		headers.append(h)
	var request_data := ""
	# PostgREST takes filters from the URL; a DELETE body is meaningless and some
	# proxies drop it, so only write methods carry a payload.
	if method != HTTPClient.METHOD_GET and method != HTTPClient.METHOD_DELETE:
		request_data = JSON.stringify(payload_dict)
	# Godot 4.7 signature: request(url, custom_headers, method, request_data)
	var err := req.request(SUPABASE_URL + endpoint, headers, method, request_data)
	if err != OK:
		req.queue_free()
		return {"ok": false, "reason": "request_failed:%d" % err}
	var response: Array = await req.request_completed
	req.queue_free()
	var result: int = response[0]
	var code: int = response[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "reason": "network_error:%d" % result}
	var body: PackedByteArray = response[3]
	var text := body.get_string_from_utf8()
	var parsed: Variant = null
	var has_text := not text.strip_edges().is_empty()
	if has_text:
		parsed = JSON.parse_string(text)
	if code < 200 or code >= 300:
		var reason := "http_%d" % code
		var error_code := ""
		if typeof(parsed) == TYPE_DICTIONARY:
			var ed: Dictionary = parsed
			reason = str(ed.get("msg", ed.get("error_description", ed.get("message", reason))))
			error_code = str(ed.get("error_code", ed.get("code", "")))
		return {"ok": false, "reason": reason, "code": code, "error_code": error_code}
	if parsed == null and has_text:
		return {"ok": false, "reason": "invalid_json", "code": code}
	return {"ok": true, "data": parsed, "code": code}


# Thin POST wrapper for auth endpoints (no Authorization header).
func _post(endpoint: String, payload_dict: Dictionary, timeout := 0.0) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, endpoint, payload_dict, PackedStringArray(), timeout)


# Raw-body request for Storage: uploads PNG bytes or downloads a public object.
# `absolute` means the endpoint is already a full URL. Caller supplies every header.
func _request_bytes(method: HTTPClient.Method, endpoint: String, body: PackedByteArray, extra_headers: PackedStringArray, absolute: bool = false) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return {"ok": false, "reason": "no_scene_tree"}
	var req := HTTPRequest.new()
	req.accept_gzip = not OS.has_feature("web")
	tree.root.add_child(req)
	var headers := PackedStringArray()
	var seen := {}
	for h in extra_headers:
		var key := h.get_slice(":", 0).strip_edges().to_lower()
		if seen.has(key):
			continue
		seen[key] = true
		headers.append(h)
	var url := endpoint if absolute else SUPABASE_URL + endpoint
	var err := req.request_raw(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "reason": "request_failed:%d" % err}
	var response: Array = await req.request_completed
	req.queue_free()
	var result: int = response[0]
	var code: int = response[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "reason": "network_error:%d" % result}
	var raw: PackedByteArray = response[3]
	if code < 200 or code >= 300:
		var text := raw.get_string_from_utf8()
		var reason := "http_%d" % code
		var parsed: Variant = JSON.parse_string(text) if not text.strip_edges().is_empty() else null
		if typeof(parsed) == TYPE_DICTIONARY:
			var ed: Dictionary = parsed
			reason = str(ed.get("message", ed.get("error", ed.get("msg", reason))))
		return {"ok": false, "reason": reason, "code": code}
	return {"ok": true, "bytes": raw, "code": code}


# Business-request headers: apikey + Bearer token. _request() dedupes apikey.
func _auth_headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + PUBLISHABLE_KEY,
		"Authorization: Bearer " + access_token(),
	])

# --- Private: session persistence ------------------------------------------

func _save_session() -> void:
	var file := FileAccess.open(SESSION_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_session))
	file.close()


func _load_session_from_disk() -> bool:
	if not FileAccess.file_exists(SESSION_PATH):
		return false
	var file := FileAccess.open(SESSION_PATH, FileAccess.READ)
	if file == null:
		return false
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = parsed
	var token := str(data.get("access_token", ""))
	var refresh := str(data.get("refresh_token", ""))
	var uid := str(data.get("user_id", ""))
	if token.is_empty() or refresh.is_empty() or uid.is_empty():
		return false
	_session = {
		"access_token": token,
		"refresh_token": refresh,
		"expires_at": float(data.get("expires_at", 0.0)),
		"user_id": uid,
		"email": str(data.get("email", "")),
	}
	return true


func _clear_session() -> void:
	_session = {}
	var dir := DirAccess.open("user://")
	if dir != null and FileAccess.file_exists(SESSION_PATH):
		dir.remove("supabase_session.json")
