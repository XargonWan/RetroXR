## WebFileServer — lightweight HTTP file manager.
## Serves the retrovr user data directory (roms + cores) over a local HTTP port.
## Supports directory listing, multi-file drag-and-drop upload, and deletion.
class_name WebFileServer
extends Node

const DEFAULT_PORT := 8080

var _tcp := TCPServer.new()
## Each entry: { peer: StreamPeerTCP, buf: PackedByteArray }
var _connections: Array = []
var _running := false
var _thread: Thread = null


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

	_dispatch(c["peer"] as StreamPeerTCP, method, path, query, hdrs, body)
	return true


func _dispatch(peer: StreamPeerTCP, method: String, path: String,
			   query: Dictionary, headers: Dictionary, body: PackedByteArray) -> void:
	if method == "GET" and path == "/":
		_send_text(peer, 200, "text/html", _HTML)
	elif method == "GET" and path == "/api/list":
		_handle_list(peer, query.get("path", ""))
	elif method == "POST" and path == "/api/upload":
		_handle_upload(peer, query.get("path", ""), headers, body)
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


func _handle_upload(peer: StreamPeerTCP, rel: String,
					headers: Dictionary, body: PackedByteArray) -> void:
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
	var saved := 0
	for part: Dictionary in parts:
		var filename := _extract_filename(part["headers"] as String)
		if filename.is_empty():
			continue
		var dest := abs.path_join(filename.get_file())
		var f := FileAccess.open(dest, FileAccess.WRITE)
		if f:
			f.store_buffer(part["data"])
			saved += 1
			print("[WebFileServer] Saved %s (%d bytes)" % [dest, (part["data"] as PackedByteArray).size()])
	_send_text(peer, 200, "application/json", '{"saved":%d}' % saved)


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
    xhr.upload.onprogress=function(ev){
      if(ev.lengthComputable){
        var pct=Math.round(ev.loaded/ev.total*100);
        pf.style.width=pct+'%';
        st.textContent='Uploading '+(i+1)+' of '+files.length+': '+file.name+' ('+pct+'%)';
      }
    };
    xhr.onload=function(){i++;uploadNext();};
    xhr.onerror=function(){st.textContent='Error uploading '+file.name;i++;uploadNext();};
    xhr.open('POST','/api/upload?path='+encodeURIComponent(cur));
    xhr.send(fd);
  }
  uploadNext();
});
go('');
</script></body></html>"""
