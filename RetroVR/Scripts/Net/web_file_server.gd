## WebFileServer — lightweight HTTP file manager.
## Serves the retrovr user data directory (roms + cores) over a local HTTP port.
## Supports directory listing, multi-file drag-and-drop upload, and deletion.
class_name WebFileServer
extends Node

const DEFAULT_PORT    := 8080
const WRITE_CHUNK_SIZE := 524288  # 512 KB per loop iteration

var _tcp := TCPServer.new()
## Each entry: { peer: StreamPeerTCP, buf: PackedByteArray }
## While writing: also has "write" → { queue, idx, f, offset, total, saved }
var _connections: Array = []
var _running := false
var _thread: Thread = null
## Shared progress state read by /api/progress (written on server thread, read on same thread via a new connection).
var _upload_progress: Dictionary = {}


## Root of the served filesystem.
static func server_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retrovr/files"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retrovr"


## Best-guess LAN IP address (filters out loopback and IPv6).
static func local_ip() -> String:
	for addr: String in IP.get_local_addresses():
		if ":" in addr:
			continue  # skip IPv6
		if addr.begins_with("192.168.") or addr.begins_with("10.") or addr.begins_with("172."):
			return addr
	return "127.0.0.1"


func start(port: int = DEFAULT_PORT) -> bool:
	if _running:
		return true
	DirAccess.make_dir_recursive_absolute(server_root())
	var err := _tcp.listen(port)
	if err != OK:
		push_error("[WebFileServer] listen(%d) failed: %s" % [port, error_string(err)])
		return false
	_running = true
	_thread = Thread.new()
	_thread.start(_thread_loop)
	print("[WebFileServer] Listening on http://%s:%d  root=%s" % [local_ip(), port, server_root()])
	return true


func stop() -> void:
	_running = false
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	for c: Dictionary in _connections:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_connections.clear()
	_tcp.stop()
	print("[WebFileServer] Stopped")


func _thread_loop() -> void:
	while _running:
		# Accept new connections.
		while _tcp.is_connection_available():
			var peer := _tcp.take_connection()
			_connections.append({"peer": peer, "buf": PackedByteArray()})

		# Service connections.
		var to_remove: Array = []
		for c: Dictionary in _connections:
			if c.has("write"):
				# Writing phase — advance one chunk; done when true is returned.
				if _write_chunk(c):
					to_remove.append(c)
				continue

			# Receiving phase.
			var peer := c["peer"] as StreamPeerTCP
			peer.poll()
			var st := peer.get_status()
			if st == StreamPeerTCP.STATUS_NONE or st == StreamPeerTCP.STATUS_ERROR:
				to_remove.append(c)
				continue
			var avail := peer.get_available_bytes()
			if avail > 0:
				var result := peer.get_data(avail)
				if result[0] == OK:
					var new_buf: PackedByteArray = c["buf"]
					new_buf.append_array(result[1])
					c["buf"] = new_buf
			if _try_handle(c):
				# Upload requests stay alive while writing; all others close.
				if not c.has("write"):
					to_remove.append(c)

		for c: Dictionary in to_remove:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
			_connections.erase(c)

		OS.delay_msec(1)


## Returns true when the request is fully received and handled.
func _try_handle(c: Dictionary) -> bool:
	var buf := c["buf"] as PackedByteArray
	var sep := _find_bytes(buf, "\r\n\r\n".to_utf8_buffer())
	if sep == -1:
		return false  # headers incomplete

	var header_text := buf.slice(0, sep).get_string_from_utf8()
	var lines := header_text.split("\r\n")
	if lines.is_empty():
		return true

	var req_parts := lines[0].split(" ")
	if req_parts.size() < 2:
		return true
	var method: String = req_parts[0]
	var raw_path: String = req_parts[1]

	var hdrs: Dictionary = {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon != -1:
			hdrs[lines[i].substr(0, colon).strip_edges().to_lower()] = \
				lines[i].substr(colon + 1).strip_edges()

	var body_start := sep + 4
	var content_length := int(hdrs.get("content-length", "0"))
	if buf.size() < body_start + content_length:
		return false  # body incomplete

	var body := buf.slice(body_start, body_start + content_length)
	var q_pos := raw_path.find("?")
	var path := raw_path.substr(0, q_pos if q_pos != -1 else raw_path.length())
	var query := _parse_query(raw_path.substr(q_pos + 1) if q_pos != -1 else "")

	_dispatch(c, method, path, query, hdrs, body)
	return true


func _dispatch(c: Dictionary, method: String, path: String,
			   query: Dictionary, headers: Dictionary, body: PackedByteArray) -> void:
	var peer := c["peer"] as StreamPeerTCP
	if method == "GET" and path == "/":
		_send_text(peer, 200, "text/html", _HTML)
	elif method == "GET" and path == "/api/list":
		_handle_list(peer, query.get("path", ""))
	elif method == "GET" and path == "/api/progress":
		_send_text(peer, 200, "application/json", JSON.stringify(_upload_progress))
	elif method == "POST" and path == "/api/upload":
		_handle_upload(c, query.get("path", ""), headers, body)
	elif method == "DELETE" and path == "/api/delete":
		_handle_delete(peer, query.get("path", ""))
	elif method == "OPTIONS":
		_send_text(peer, 200, "text/plain", "")
	else:
		_send_text(peer, 404, "text/plain", "Not Found")


# ── API handlers ──────────────────────────────────────────────────────────────

func _handle_list(peer: StreamPeerTCP, rel: String) -> void:
	var abs := _resolve(rel)
	if abs.is_empty():
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var dir := DirAccess.open(abs)
	if not dir:
		_send_text(peer, 404, "application/json", '{"error":"not found"}')
		return

	var dirs: Array[String] = []
	var files: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not name.begins_with("."):
			if dir.current_is_dir():
				dirs.append(name)
			else:
				var fa := FileAccess.open(abs.path_join(name), FileAccess.READ)
				var size := fa.get_length() if fa else 0
				files.append({"name": name, "size": size})
		name = dir.get_next()
	dir.list_dir_end()

	dirs.sort()
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	_send_text(peer, 200, "application/json", JSON.stringify({"dirs": dirs, "files": files}))


## Parses the multipart body and queues files for chunked writing.
## The connection stays open; _write_chunk advances the write each loop iteration.
func _handle_upload(c: Dictionary, rel: String,
					headers: Dictionary, body: PackedByteArray) -> void:
	var peer := c["peer"] as StreamPeerTCP
	var abs := _resolve(rel)
	if abs.is_empty():
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var ct: String = headers.get("content-type", "")
	var b_idx := ct.find("boundary=")
	if b_idx == -1:
		_send_text(peer, 400, "application/json", '{"error":"no boundary"}')
		return
	var boundary := ct.substr(b_idx + 9).strip_edges()
	var parts := _parse_multipart(body, boundary)
	var queue: Array = []
	for part: Dictionary in parts:
		var filename := _extract_filename(part["headers"] as String)
		if filename.is_empty():
			continue
		queue.append({"dest": abs.path_join(filename.get_file()),
					  "data": part["data"] as PackedByteArray,
					  "filename": filename.get_file()})
	if queue.is_empty():
		_send_text(peer, 200, "application/json", '{"saved":0}')
		return
	c["write"] = {"queue": queue, "idx": 0, "f": null, "offset": 0, "total": 0, "saved": 0}
	_start_next_write(c)


func _start_next_write(c: Dictionary) -> void:
	var w: Dictionary = c["write"]
	var item: Dictionary = w["queue"][w["idx"]]
	var f := FileAccess.open(item["dest"], FileAccess.WRITE)
	if not f:
		push_error("[WebFileServer] Cannot open %s for writing" % item["dest"])
		w["idx"] += 1
		if w["idx"] < (w["queue"] as Array).size():
			_start_next_write(c)
		else:
			_send_text(c["peer"] as StreamPeerTCP, 200, "application/json",
					   '{"saved":%d}' % w["saved"])
			c.erase("write")
			_upload_progress = {}
		return
	w["f"] = f
	w["offset"] = 0
	w["total"] = (item["data"] as PackedByteArray).size()
	_upload_progress = {"filename": item["filename"], "written": 0, "total": w["total"]}
	print("[WebFileServer] Writing %s (%d bytes)" % [item["dest"], w["total"]])


## Writes one WRITE_CHUNK_SIZE chunk. Returns true when all files in the queue are done.
func _write_chunk(c: Dictionary) -> bool:
	var w: Dictionary = c["write"]
	var item: Dictionary = (w["queue"] as Array)[w["idx"]]
	var data := item["data"] as PackedByteArray
	var f    := w["f"]     as FileAccess
	var offset: int = w["offset"]
	var chunk_end := mini(offset + WRITE_CHUNK_SIZE, data.size())
	f.store_buffer(data.slice(offset, chunk_end))
	w["offset"] = chunk_end
	_upload_progress["written"] = chunk_end

	if chunk_end < data.size():
		return false  # still writing this file

	# File complete.
	f.close()
	w["f"] = null
	w["saved"] = (w["saved"] as int) + 1
	print("[WebFileServer] Saved %s" % item["dest"])
	w["idx"] = (w["idx"] as int) + 1
	if (w["idx"] as int) < (w["queue"] as Array).size():
		_start_next_write(c)
		return false  # more files to write

	# All files written — send response and signal done.
	# Leave _upload_progress set (written == total) so in-flight polls see 100%.
	# It will be overwritten when the next upload begins.
	_send_text(c["peer"] as StreamPeerTCP, 200, "application/json",
			   '{"saved":%d}' % w["saved"])
	c.erase("write")
	return true


func _handle_delete(peer: StreamPeerTCP, rel: String) -> void:
	var abs := _resolve(rel)
	if abs.is_empty() or abs == server_root():
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var err := DirAccess.remove_absolute(abs)
	if err == OK:
		_send_text(peer, 200, "application/json", '{"ok":true}')
	else:
		_send_text(peer, 500, "application/json",
				   '{"error":"delete failed","code":%d}' % err)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _resolve(rel: String) -> String:
	var root := server_root()
	if rel.is_empty():
		return root
	var abs := (root + "/" + rel.uri_decode()).simplify_path()
	return abs if abs.begins_with(root) else ""


func _parse_query(s: String) -> Dictionary:
	var d: Dictionary = {}
	for pair in s.split("&"):
		var eq := pair.find("=")
		if eq != -1:
			d[pair.substr(0, eq).uri_decode()] = pair.substr(eq + 1).uri_decode()
	return d


func _parse_multipart(body: PackedByteArray, boundary: String) -> Array:
	var delim := ("--" + boundary).to_utf8_buffer()
	var crlf2 := "\r\n\r\n".to_utf8_buffer()
	var results: Array = []
	var pos := 0
	while true:
		var d_pos := _find_bytes(body, delim, pos)
		if d_pos == -1:
			break
		pos = d_pos + delim.size()
		# Final boundary ends with "--"
		if pos + 1 < body.size() and body[pos] == 45 and body[pos + 1] == 45:
			break
		# Skip CRLF after delimiter
		if pos + 1 < body.size() and body[pos] == 13 and body[pos + 1] == 10:
			pos += 2
		# Find end of part headers
		var hdr_end := _find_bytes(body, crlf2, pos)
		if hdr_end == -1:
			break
		var hdr_text := body.slice(pos, hdr_end).get_string_from_utf8()
		pos = hdr_end + 4
		# Find next delimiter to bound the data
		var next_d := _find_bytes(body, delim, pos)
		if next_d == -1:
			break
		var data_end := next_d
		# Strip trailing CRLF before next delimiter
		if data_end >= 2 and body[data_end - 2] == 13 and body[data_end - 1] == 10:
			data_end -= 2
		results.append({"headers": hdr_text, "data": body.slice(pos, data_end)})
		pos = next_d
	return results


func _extract_filename(part_headers: String) -> String:
	var idx := part_headers.find("filename=")
	if idx == -1:
		return ""
	var rest := part_headers.substr(idx + 9)
	if rest.begins_with('"'):
		var end := rest.find('"', 1)
		return rest.substr(1, end - 1) if end != -1 else ""
	var end := rest.find("\r")
	if end == -1:
		end = rest.find("\n")
	return rest.substr(0, end if end != -1 else rest.length())


func _find_bytes(haystack: PackedByteArray, needle: PackedByteArray, from: int = 0) -> int:
	var hs := haystack.size()
	var ns := needle.size()
	if ns == 0 or hs < ns:
		return -1
	for i in range(from, hs - ns + 1):
		var ok := true
		for j in range(ns):
			if haystack[i + j] != needle[j]:
				ok = false
				break
		if ok:
			return i
	return -1


func _send_text(peer: StreamPeerTCP, code: int, content_type: String, body: String) -> void:
	var body_bytes := body.to_utf8_buffer()
	var status_map := {
		200: "OK", 201: "Created", 400: "Bad Request",
		403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"
	}
	var status: String = status_map.get(code, "Unknown")
	var hdr := "HTTP/1.1 %d %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
			   % [code, status, content_type, body_bytes.size()]
	peer.put_data(hdr.to_utf8_buffer())
	peer.put_data(body_bytes)


# ── Embedded HTML UI ──────────────────────────────────────────────────────────

const _HTML := """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RetroVR Files</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:monospace;background:#111;color:#ccc;padding:16px}
h1{color:#8af;margin-bottom:12px;font-size:20px}
#bc{margin-bottom:14px;font-size:14px}
#bc a{color:#8af;cursor:pointer;text-decoration:none}
#bc a:hover{text-decoration:underline}
.sep{color:#444;margin:0 4px}
#dz{border:2px dashed #444;border-radius:8px;padding:18px;margin-bottom:10px;
    color:#666;text-align:center;font-size:14px;transition:border-color .15s,color .15s}
#dz.over{border-color:#8af;color:#8af}
#st{min-height:18px;font-size:13px;color:#8f8;margin-bottom:10px}
table{width:100%;border-collapse:collapse}
tr{border-bottom:1px solid #1c1c1c}
tr:hover{background:#161626}
td{padding:9px 6px;font-size:14px;vertical-align:middle}
.ic{width:24px}
.nm{word-break:break-all}
.dn{color:#8af;cursor:pointer}
.dn:hover{text-decoration:underline}
.sz{color:#555;text-align:right;width:80px;white-space:nowrap}
.ac{text-align:right;width:44px}
button{background:#500;border:none;color:#f88;padding:3px 8px;border-radius:3px;cursor:pointer;font-size:13px}
button:hover{background:#800}
</style></head><body>
<h1>RetroVR Files</h1>
<div id="bc"></div>
<div id="dz">Drop files here to upload &nbsp;(multiple OK)</div>
<div id="st"></div>
<div id="pb" style="display:none;height:8px;background:#222;border-radius:4px;margin-bottom:10px;overflow:hidden"><div id="pf" style="height:100%;width:0%;background:#8af;border-radius:4px;transition:width .15s"></div></div>
<table><tbody id="tb"></tbody></table>
<script>
var cur='';
function fmt(b){
  if(b<1024)return b+' B';
  if(b<1048576)return (b/1024).toFixed(1)+' KB';
  if(b<1073741824)return (b/1048576).toFixed(1)+' MB';
  return (b/1073741824).toFixed(2)+' GB';
}
function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function parent_of(p){var i=p.lastIndexOf('/');return i>0?p.substring(0,i):'';}
function go(p){
  cur=p;
  var bc=document.getElementById('bc');
  var parts=p?p.split('/').filter(Boolean):[];
  var h='<a data-nav="">root</a>';
  var acc='';
  parts.forEach(function(s){acc+='/'+s;h+='<span class="sep">/</span><a data-nav="'+acc+'">'+esc(s)+'</a>';});
  bc.innerHTML=h;
  fetch('/api/list?path='+encodeURIComponent(p)).then(function(r){return r.json();}).then(draw);
}
function draw(d){
  var tb=document.getElementById('tb');
  var h='';
  if(cur){h+='<tr><td class="ic">📁</td><td class="nm dn" data-nav="'+esc(parent_of(cur))+'">..</td><td class="sz"></td><td class="ac"></td></tr>';}
  (d.dirs||[]).forEach(function(n){
    var cp=cur?cur+'/'+n:n;
    h+='<tr><td class="ic">📁</td><td class="nm dn" data-nav="'+esc(cp)+'">'+esc(n)+'</td><td class="sz">—</td><td class="ac"></td></tr>';
  });
  (d.files||[]).forEach(function(f){
    var fp=cur?cur+'/'+f.name:f.name;
    h+='<tr><td class="ic">📄</td><td class="nm">'+esc(f.name)+'</td><td class="sz">'+fmt(f.size)+'</td><td class="ac"><button data-del="'+esc(fp)+'">✕</button></td></tr>';
  });
  if(!h)h='<tr><td colspan="4" style="color:#333;padding:20px;text-align:center">Empty</td></tr>';
  tb.innerHTML=h;
}
document.addEventListener('click',function(e){
  if(e.target.hasAttribute('data-nav'))go(e.target.getAttribute('data-nav'));
  if(e.target.hasAttribute('data-del')){
    var p=e.target.getAttribute('data-del');
    if(confirm('Delete '+p.split('/').pop()+'?'))
      fetch('/api/delete?path='+encodeURIComponent(p),{method:'DELETE'}).then(function(){go(cur);});
  }
});
var dz=document.getElementById('dz');
dz.addEventListener('dragover',function(e){e.preventDefault();dz.classList.add('over');});
dz.addEventListener('dragleave',function(){dz.classList.remove('over');});
dz.addEventListener('drop',function(e){
  e.preventDefault();
  dz.classList.remove('over');
  var files=e.dataTransfer.files;
  var st=document.getElementById('st');
  var pb=document.getElementById('pb');
  var pf=document.getElementById('pf');
  var i=0;
  function uploadNext(){
    if(i>=files.length){
      st.textContent='Done \u2014 uploaded '+files.length+' file(s).';
      pb.style.display='none';
      pf.style.width='0%';
      go(cur);
      return;
    }
    var file=files[i];
    st.textContent='Uploading '+(i+1)+' of '+files.length+': '+file.name;
    pb.style.display='block';
    pf.style.width='0%';
    var fd=new FormData();
    fd.append('file',file);
    var xhr=new XMLHttpRequest();
    var pollTimer=null;
    function stopPoll(){if(pollTimer){clearInterval(pollTimer);pollTimer=null;}}
    xhr.upload.onprogress=function(ev){
      if(ev.lengthComputable){
        var pct=Math.round(ev.loaded/ev.total*100);
        pf.style.width=pct+'%';
        if(pct>=100&&!pollTimer){
          pollTimer=setInterval(function(){
            fetch('/api/progress').then(function(r){return r.json();}).then(function(d){
              if(d.total&&d.total>0){
                var wpct=Math.round(d.written/d.total*100);
                pf.style.width=wpct+'%';
                st.textContent='Saving to disk: '+d.filename+' ('+wpct+'%)';
              } else {
                st.textContent='Uploading '+(i+1)+' of '+files.length+': '+file.name+' (100%) \u2014 waiting for server\u2026';
              }
            }).catch(function(){});
          },100);
        } else {
          st.textContent='Uploading '+(i+1)+' of '+files.length+': '+file.name+' ('+pct+'%)';
        }
      }
    };
    xhr.onload=function(){stopPoll();pf.style.width='100%';i++;uploadNext();};
    xhr.onerror=function(){stopPoll();st.textContent='Error uploading '+file.name;i++;uploadNext();};
    xhr.open('POST','/api/upload?path='+encodeURIComponent(cur));
    xhr.send(fd);
  }
  uploadNext();
});
go('');
</script></body></html>"""
