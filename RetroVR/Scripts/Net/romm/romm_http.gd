## RommHttp — blocking HTTP for worker threads.
##
## HTTPRequest hands the response body back on the main thread, so a 3 MB catalog
## page or a 4 GB ROM would be parsed/copied there and blow the frame budget.
## This wraps HTTPClient's poll loop instead, so callers can run it on their own
## Thread and stream bodies straight to disk.
##
## NEVER call these from the main thread — every method blocks.
class_name RommHttp
extends RefCounted


## Outcome codes distinct enough to drive the download error matrix.
enum Result {
	OK,
	CONNECT_FAILED,   ## DNS / refused / TLS — transient, retry
	REQUEST_FAILED,   ## socket died mid-exchange — transient, retry
	HTTP_ERROR,       ## got a response, but a bad status — see `code`
	ABORTED,          ## caller set the abort flag
	WRITE_FAILED,     ## local disk write failed — terminal
}

const POLL_SLEEP_MS := 1
## Guard against a server that accepts the connection and then says nothing.
const CONNECT_TIMEOUT_SEC := 15.0
const RESPONSE_TIMEOUT_SEC := 30.0

var _client: HTTPClient = null
var _host: String = ""
var _port: int = -1
var _use_tls: bool = false


## Split "http://host:8080" into its parts. Returns {} when unusable.
static func parse_url(base_url: String) -> Dictionary:
	var url := base_url.strip_edges()
	if url.is_empty():
		return {}

	var use_tls := url.begins_with("https://")
	if use_tls:
		url = url.substr(8)
	elif url.begins_with("http://"):
		url = url.substr(7)

	# Strip any path — callers always pass absolute paths themselves.
	var slash := url.find("/")
	if slash >= 0:
		url = url.substr(0, slash)

	var host := url
	var port := 443 if use_tls else 80
	var colon := url.rfind(":")
	if colon > 0:
		host = url.substr(0, colon)
		var port_str := url.substr(colon + 1)
		if port_str.is_valid_int():
			port = int(port_str)

	if host.is_empty():
		return {}
	return {"host": host, "port": port, "use_tls": use_tls}


## Connect (or reconnect) to the server. Returns a Result.
func open(base_url: String) -> int:
	close()

	var parts := parse_url(base_url)
	if parts.is_empty():
		return Result.CONNECT_FAILED

	_host = parts["host"]
	_port = parts["port"]
	_use_tls = parts["use_tls"]

	_client = HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if _use_tls else null
	if _client.connect_to_host(_host, _port, tls) != OK:
		close()
		return Result.CONNECT_FAILED

	var deadline := Time.get_ticks_msec() + int(CONNECT_TIMEOUT_SEC * 1000.0)
	while true:
		var status := _client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			return Result.OK
		if status != HTTPClient.STATUS_CONNECTING and status != HTTPClient.STATUS_RESOLVING:
			close()
			return Result.CONNECT_FAILED
		if Time.get_ticks_msec() > deadline:
			close()
			return Result.CONNECT_FAILED
		_client.poll()
		OS.delay_msec(POLL_SLEEP_MS)

	return Result.CONNECT_FAILED


func close() -> void:
	if _client != null:
		_client.close()
		_client = null


func is_open() -> bool:
	return _client != null and _client.get_status() == HTTPClient.STATUS_CONNECTED


## Send a request and wait for response headers (not the body).
## Returns {result: Result, code: int, headers: Dictionary}.
func _send(method: int, path: String, headers: PackedStringArray, body: String = "") -> Dictionary:
	if _client == null:
		return {"result": Result.CONNECT_FAILED, "code": 0, "headers": {}}

	if _client.request(method, path, headers, body) != OK:
		return {"result": Result.REQUEST_FAILED, "code": 0, "headers": {}}

	var deadline := Time.get_ticks_msec() + int(RESPONSE_TIMEOUT_SEC * 1000.0)
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			return {"result": Result.REQUEST_FAILED, "code": 0, "headers": {}}
		OS.delay_msec(POLL_SLEEP_MS)

	if not _client.has_response():
		return {"result": Result.REQUEST_FAILED, "code": 0, "headers": {}}

	return {
		"result": Result.OK,
		"code": _client.get_response_code(),
		"headers": _client.get_response_headers_as_dictionary(),
	}


## GET a small body fully into memory and JSON-parse it.
## Only for responses that comfortably fit — catalog pages at limit=1000 are
## ~3 MB, which is fine on a worker thread.
## Returns {result: Result, code: int, data: Variant}.
func get_json(path: String, headers: PackedStringArray, abort: Callable = Callable()) -> Dictionary:
	var sent := _send(HTTPClient.METHOD_GET, path, headers)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "data": null}

	var code := int(sent["code"])
	var raw := _read_body(abort)
	if int(raw["result"]) != Result.OK:
		return {"result": raw["result"], "code": code, "data": null}

	if code < 200 or code >= 300:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	var json := JSON.new()
	var text: String = (raw["body"] as PackedByteArray).get_string_from_utf8()
	if json.parse(text) != OK:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	return {"result": Result.OK, "code": code, "data": json.data}


## POST/PUT a file as multipart/form-data and read the JSON reply.
##
## The only upload primitive here — everything else in this class is
## download-shaped. Battery saves are the whole use case and they are KB-sized
## (128 KB for a PS1 card, 16 MB for the largest GameCube one), so the body is
## composed in memory rather than streamed.
##
## Returns {result: Result, code: int, data: Variant}.
func upload_multipart(method: int, path: String, headers: PackedStringArray,
					  field: String, filename: String, bytes: PackedByteArray,
					  mime: String = "application/octet-stream") -> Dictionary:
	if _client == null:
		return {"result": Result.CONNECT_FAILED, "code": 0, "data": null}

	# Must not occur in the payload. Random rather than fixed: a save file is
	# arbitrary binary and a constant boundary could appear inside one.
	var boundary := "----RetroVR%016x%016x" % [randi(), randi()]

	var head := PackedByteArray()
	head.append_array(("--%s\r\n" % boundary).to_utf8_buffer())
	head.append_array(('Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
		% [field, filename]).to_utf8_buffer())
	head.append_array(("Content-Type: %s\r\n\r\n" % mime).to_utf8_buffer())

	var tail := ("\r\n--%s--\r\n" % boundary).to_utf8_buffer()

	var body := PackedByteArray()
	body.append_array(head)
	body.append_array(bytes)
	body.append_array(tail)

	var all := PackedStringArray(headers)
	all.append("Content-Type: multipart/form-data; boundary=%s" % boundary)
	all.append("Content-Length: %d" % body.size())

	if _client.request_raw(method, path, all, body) != OK:
		return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}

	var deadline := Time.get_ticks_msec() + int(RESPONSE_TIMEOUT_SEC * 1000.0)
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}
		OS.delay_msec(POLL_SLEEP_MS)

	if not _client.has_response():
		return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}

	var code := _client.get_response_code()
	var raw := _read_body()
	if int(raw["result"]) != Result.OK:
		return {"result": raw["result"], "code": code, "data": null}
	if code < 200 or code >= 300:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	# A 2xx with an unparseable body still means the upload landed, so the
	# result stays OK and `data` is simply null.
	return {"result": Result.OK, "code": code,
		"data": JSON.parse_string((raw["body"] as PackedByteArray).get_string_from_utf8())}


## Stream a response body straight into an open FileAccess, never holding it in
## memory. `file` must already be positioned (append for a resume).
##
## progress_cb : optional func(received_bytes: int, total_bytes: int) -> void
##               Called from THIS thread — marshal to the main thread yourself.
## abort       : optional func() -> bool, checked between chunks.
##
## Returns {result: Result, code: int, received: int, total: int}.
func download_to_file(path: String, headers: PackedStringArray, file: FileAccess,
					  progress_cb: Callable = Callable(),
					  abort: Callable = Callable()) -> Dictionary:
	var sent := _send(HTTPClient.METHOD_GET, path, headers)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "received": 0, "total": 0}

	var code := int(sent["code"])
	if code < 200 or code >= 300:
		# Drain so the connection stays reusable, then report the status.
		_read_body(abort)
		return {"result": Result.HTTP_ERROR, "code": code, "received": 0, "total": 0}

	var total := _content_length(sent["headers"])
	var received := 0
	var last_report := 0

	while _client.get_status() == HTTPClient.STATUS_BODY:
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "code": code, "received": received, "total": total}

		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(POLL_SLEEP_MS)
			continue

		file.store_buffer(chunk)
		if file.get_error() != OK:
			return {"result": Result.WRITE_FAILED, "code": code, "received": received, "total": total}

		received += chunk.size()
		# Throttle: a per-chunk deferred call would flood the main thread.
		if progress_cb.is_valid() and (received - last_report) > 262144:
			last_report = received
			progress_cb.call(received, total)

	if progress_cb.is_valid():
		progress_cb.call(received, total)

	return {"result": Result.OK, "code": code, "received": received, "total": total}


## HEAD — size/existence probe without pulling the body.
## Returns {result: Result, code: int, total: int}.
func head(path: String, headers: PackedStringArray) -> Dictionary:
	var sent := _send(HTTPClient.METHOD_HEAD, path, headers)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "total": 0}
	return {
		"result": Result.OK,
		"code": int(sent["code"]),
		"total": _content_length(sent["headers"]),
	}


func _read_body(abort: Callable = Callable()) -> Dictionary:
	var body := PackedByteArray()
	while _client.get_status() == HTTPClient.STATUS_BODY:
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "body": body}
		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(POLL_SLEEP_MS)
		else:
			body.append_array(chunk)
	return {"result": Result.OK, "body": body}


static func _content_length(headers: Dictionary) -> int:
	for key: String in headers:
		if key.to_lower() == "content-length":
			var v := str(headers[key])
			if v.is_valid_int():
				return int(v)
	return 0
