## RaHttpBridge — the networking rcheevos deliberately does not provide.
##
## rc_client builds every RetroAchievements request itself (login2, gameid, patch,
## startsession, ping, awardachievement) and parses every response; all it asks of
## the integration is that the bytes get moved. It emits `ra_http_request` with a
## url, optional post data and a request id; this node performs the call and hands
## the raw body back through RetroAchievements.HttpResponse(). The body is NOT
## parsed here — rc_client does that, and a JSON parse on this side would only
## throw away the error text it needs.
##
## Structured after RommClient._request_json (Scripts/Net/romm/romm_client.gd),
## which is the established shape in this project for an HTTPRequest-per-call
## client: use_threads, queue_free in the completion lambda, and a callback that
## fires exactly once on every path.
class_name RaHttpBridge
extends Node


## RetroAchievements is not a fast server under load and an unlock must not be
## abandoned early — a dropped unlock is a lost achievement.
const REQUEST_TIMEOUT := 30.0

## rc_api_request.h. A transport failure is reported with one of these in place of
## an HTTP status: the retryable form makes rc_client queue the unlock and resend
## it later rather than discard it, which is what a flaky headset wifi needs.
const RC_API_SERVER_RESPONSE_CLIENT_ERROR := -1
const RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR := -2

var _user_agent: String = ""


func _ready() -> void:
	var ra: Object = _ra()
	if ra == null:
		push_warning("[RaHttpBridge] RetroAchievements singleton unavailable")
		return
	ra.connect("ra_http_request", _on_request)


static func _ra() -> Object:
	# The GDExtension registers this; a build without the extension loaded (the
	# headless editor's template_debug path) simply has no achievements.
	return Engine.get_singleton("RetroAchievements") if \
		Engine.has_singleton("RetroAchievements") else null


## RetroAchievements requires a user agent on every call to dorequest.php and says
## so in as many words. The server also uses it to decide whether a client is
## approved for hardcore — an unrecognised one has its hardcore unlocks recorded
## as softcore — so it must be stable and identify RetroXR honestly.
## Format: RetroXR/0.2.0 (Android 14; arm64) rcheevos/12.4.0
static func build_user_agent() -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	var os_name := OS.get_name()
	var os_version := OS.get_version()
	var model := OS.get_model_name()

	var platform := "%s %s" % [os_name, os_version]
	if not model.is_empty() and model != "GenericDevice":
		platform += "; " + model

	return "RetroXR/%s (%s)" % [version, platform]


## Push the user agent into the extension, which appends its own rcheevos clause.
func apply_user_agent() -> void:
	var ra: Object = _ra()
	if ra == null:
		return
	ra.SetUserAgent(build_user_agent())
	_user_agent = ra.GetUserAgent()


func _on_request(request_id: int, url: String, post_data: String, content_type: String) -> void:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	http.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()

			if result != HTTPRequest.RESULT_SUCCESS:
				# Transport, not protocol. Retryable so a queued unlock survives a
				# dropped connection instead of being silently dropped.
				push_warning("[RaHttpBridge] request %d failed (result %d)" % [request_id, result])
				_respond(request_id, RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR, "")
				return

			_respond(request_id, response_code, body.get_string_from_utf8())
	)

	if _user_agent.is_empty():
		apply_user_agent()

	var headers := PackedStringArray(["User-Agent: " + _user_agent])
	var method := HTTPClient.METHOD_GET
	if not post_data.is_empty():
		method = HTTPClient.METHOD_POST
		headers.append("Content-Type: " + (content_type if not content_type.is_empty()
			else "application/x-www-form-urlencoded"))

	var err := http.request(url, headers, method, post_data)
	if err != OK:
		push_warning("[RaHttpBridge] could not start request %d (err %d)" % [request_id, err])
		http.queue_free()
		_respond(request_id, RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR, "")


## Every path through _on_request ends here exactly once. rc_client leaks the
## request's callback data if a response never arrives for an id it handed out.
func _respond(request_id: int, status: int, body: String) -> void:
	var ra: Object = _ra()
	if ra == null:
		return
	ra.HttpResponse(request_id, status, body)
