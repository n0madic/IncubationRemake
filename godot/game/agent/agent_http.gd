class_name AgentHttpServer
extends RefCounted

## A minimal HTTP/1.1 server over [TCPServer], for the agent bridge.
##
## **It knows nothing about the game.** Requests come out of [method poll] as
## plain dictionaries and answers go back in through [method respond]; what a
## path means is the bridge's business (`game/agent/agent_bridge.gd`). That is
## what lets `tests/test_agent.gd` drive the whole transport with a stub over
## the loopback address, with no window, no world and no frames.
##
## The one property the rest of the design rests on: **a connection is held
## open until it is answered**. A `POST /command` that runs for four hundred
## frames is a socket sitting in `_conns` for four hundred frames, while every
## other request that arrives is accepted and answered in the frame it lands.
## The directory protocol this replaced could not do that at all -- a reply was
## a file written after the batch, so "what does the screen look like right
## now" was a question with no way to ask it.
##
## Four details that `curl` and `urllib` will find if they are missing:
## [method StreamPeerTCP.set_no_delay] on an accepted peer, [method
## StreamPeerTCP.poll] before every status read, accumulating bytes until the
## head terminator and then exactly `Content-Length` more, and an answer that
## always carries `Content-Length` and `Connection: close`.

## A body larger than this is refused with 413 rather than buffered.
const MAX_BODY: int = 1 << 20

## A header block larger than this is refused with 431. It also bounds a peer
## that connects and sends a stream that never terminates.
const MAX_HEAD: int = 16 * 1024

## Connections held at once. The ninth is answered 503 and dropped: a driver
## that leaks sockets should be told so, not silently starve the game.
const MAX_CONNS: int = 8

## A connection that has not completed a request in this long is dropped.
const IDLE_MSEC: int = 120 * 1000

const CRLF: String = "\r\n"

## `Content-Type` of the server's own error bodies.
const TYPE_JSON: String = "application/json"


## One accepted socket. **No pointer back to the server**: a `RefCounted`
## cycle is never collected by Godot and turns a green run into
## `N resources still in use at exit` (docs/92 section 10.4).
class Conn extends RefCounted:
	var id: int = 0
	var peer: StreamPeerTCP = null
	var buffer: PackedByteArray = PackedByteArray()
	var opened_msec: int = 0
	var delivered: bool = false
	var continued: bool = false


var _server: TCPServer = null
var _conns: Array[Conn] = []
var _next_id: int = 0
var _port: int = 0


## Binds the loopback address. A non-`OK` return is the caller's to report; the
## game must keep running when a port is taken.
func listen(port: int, address: String = "127.0.0.1") -> Error:
	stop()
	_server = TCPServer.new()
	var opened: Error = _server.listen(port, address)
	if opened != OK:
		_server = null
		return opened
	_port = _server.get_local_port()
	if _port <= 0:
		_port = port
	return OK


func is_listening() -> bool:
	return _server != null and _server.is_listening()


## The port actually bound, which is not the requested one when 0 was asked
## for: `--agent-port=0` is how two driving sessions run side by side.
func port() -> int:
	return _port


## Accepts, reads, and returns every request completed in this frame.
##
## Malformed and oversized requests are answered here and are not returned --
## the bridge routes requests, it does not spell HTTP.
func poll() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _server == null:
		return out
	_accept()
	# **Forward, so `out` is in arrival order.** Walking backwards to make the
	# removals cheap put two requests that landed in the same frame into the
	# reply array newest-first, so of two `POST /command` the later one would
	# take the batch and the earlier one be refused 409. The dead entries are
	# collected instead.
	var dead: PackedInt32Array = PackedInt32Array()
	for index: int in range(_conns.size()):
		var conn: Conn = _conns[index]
		if _service(conn, out):
			continue
		_close(conn)
		dead.append(index)
	var back: int = dead.size() - 1
	while back >= 0:
		_conns.remove_at(dead[back])
		back -= 1
	return out


## Writes one answer and closes the connection it belongs to.
##
## An id that is not held is ignored, which is what makes answering a peer that
## went away while a batch ran a no-op rather than an error.
func respond(id: int, status: int, content_type: String,
		body: PackedByteArray, extra: Dictionary = {}) -> void:
	var index: int = _index_of(id)
	if index < 0:
		return
	var conn: Conn = _conns[index]
	_write(conn, status, content_type, body, extra)
	_close(conn)
	_conns.remove_at(index)


## The ids accepted and not yet answered, oldest first.
func pending() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for conn: Conn in _conns:
		if conn.delivered:
			out.append(conn.id)
	return out


func stop() -> void:
	for conn: Conn in _conns:
		_close(conn)
	_conns.clear()
	if _server != null:
		_server.stop()
	_server = null
	_port = 0


# --- the parser --------------------------------------------------------------

## One request out of a byte buffer. **Pure and static**, so the suite pins the
## grammar without a socket (docs/92 section 7.16 D4).
##
## Returns `complete`, `head_complete`, `error` (empty when fine) and the
## `status` an error should be answered with, beside `method`, `path`,
## `query`, `headers` (names lowercased), `body` and `consumed`. An incomplete
## request is **not** an error: it is the normal state of a body that arrived
## in two packets.
static func parse_request(bytes: PackedByteArray) -> Dictionary:
	var out: Dictionary = {
		"complete": false,
		"head_complete": false,
		"error": "",
		"status": 200,
		"method": "",
		"target": "",
		"path": "",
		"query": {},
		"headers": {},
		"body": PackedByteArray(),
		"consumed": 0,
	}
	var split: Vector2i = _head_end(bytes)
	if split.x < 0:
		if bytes.size() > MAX_HEAD:
			out["error"] = "header block too large"
			out["status"] = 431
		return out
	var head: String = bytes.slice(0, split.x).get_string_from_utf8()
	var lines: PackedStringArray = head.replace(CRLF, "\n").split("\n")
	if lines.is_empty():
		out["error"] = "empty request"
		out["status"] = 400
		return out
	var request_line: PackedStringArray = lines[0].split(" ", false)
	if request_line.size() < 2:
		out["error"] = "malformed request line"
		out["status"] = 400
		return out
	out["method"] = request_line[0].to_upper()
	out["target"] = request_line[1]
	var target: Dictionary = split_target(request_line[1])
	out["path"] = target["path"]
	out["query"] = target["query"]
	var headers: Dictionary = {}
	for i: int in range(1, lines.size()):
		var line: String = lines[i]
		var colon: int = line.find(":")
		if colon <= 0:
			continue
		headers[line.substr(0, colon).strip_edges().to_lower()] = \
			line.substr(colon + 1).strip_edges()
	out["headers"] = headers
	out["head_complete"] = true
	if headers.has("transfer-encoding"):
		# Chunked bodies are not read. Nothing this serves sends one, and a
		# half-supported framing is worse than a named refusal.
		out["error"] = "transfer-encoding is not supported"
		out["status"] = 501
		return out
	var length: int = 0
	if headers.has("content-length"):
		length = DictRead.as_string(headers["content-length"]).to_int()
	if length < 0 or length > MAX_BODY:
		out["error"] = "body too large"
		out["status"] = 413
		return out
	if bytes.size() - split.y < length:
		return out
	out["body"] = bytes.slice(split.y, split.y + length)
	out["consumed"] = split.y + length
	out["complete"] = true
	return out


## `/shot?save=a%20b` as a path and a percent-decoded `String -> String` map.
static func split_target(target: String) -> Dictionary:
	var query: Dictionary = {}
	var mark: int = target.find("?")
	if mark < 0:
		return {"path": target, "query": query}
	for pair: String in target.substr(mark + 1).split("&", false):
		var equals: int = pair.find("=")
		if equals < 0:
			query[pair.uri_decode()] = ""
			continue
		query[pair.substr(0, equals).uri_decode()] = \
			pair.substr(equals + 1).uri_decode()
	return {"path": target.substr(0, mark), "query": query}


static func status_text(status: int) -> String:
	match status:
		200: return "OK"
		400: return "Bad Request"
		404: return "Not Found"
		405: return "Method Not Allowed"
		403: return "Forbidden"
		409: return "Conflict"
		413: return "Payload Too Large"
		431: return "Request Header Fields Too Large"
		500: return "Internal Server Error"
		501: return "Not Implemented"
		503: return "Service Unavailable"
	return "OK"


# --- the socket --------------------------------------------------------------

func _accept() -> void:
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		if peer == null:
			return
		# Without this a small answer sits in the kernel's send buffer waiting
		# for a segment that never comes, and `curl` looks like it hung.
		peer.set_no_delay(true)
		var conn: Conn = Conn.new()
		_next_id += 1
		conn.id = _next_id
		conn.peer = peer
		conn.opened_msec = Time.get_ticks_msec()
		if _conns.size() >= MAX_CONNS:
			_write(conn, 503, TYPE_JSON,
				_error_body("too many connections"), {})
			_close(conn)
			continue
		_conns.append(conn)


## Reads one connection. Returns false when it should be dropped.
func _service(conn: Conn, out: Array[Dictionary]) -> bool:
	if conn.peer == null:
		return false
	conn.peer.poll()
	var status: StreamPeerTCP.Status = conn.peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		# A peer that went away while its batch ran takes its id with it; the
		# answer for it then lands nowhere, which `respond` allows.
		return status == StreamPeerTCP.STATUS_CONNECTING
	if conn.delivered:
		return true
	var available: int = conn.peer.get_available_bytes()
	if available > 0:
		var got: Array = conn.peer.get_partial_data(available)
		var code: int = got[0]
		if code != OK:
			return false
		var chunk: PackedByteArray = got[1]
		conn.buffer.append_array(chunk)
	if conn.buffer.is_empty():
		return Time.get_ticks_msec() - conn.opened_msec < IDLE_MSEC
	var request: Dictionary = parse_request(conn.buffer)
	var error: String = DictRead.as_string(request["error"])
	if error != "":
		_write(conn, DictRead.as_int(request["status"]), TYPE_JSON,
			_error_body(error), {})
		return false
	if not DictRead.as_bool(request["complete"]):
		if DictRead.as_bool(request["head_complete"]) and not conn.continued:
			# `curl` waits a full second for this before sending a body over
			# about a kilobyte, which reads as a stall on every long command.
			var headers: Dictionary = DictRead.as_dict(request["headers"])
			if DictRead.as_string(headers.get("expect", "")).to_lower() \
					== "100-continue":
				conn.continued = true
				var line: String = "HTTP/1.1 100 Continue" + CRLF + CRLF
				var sent: Error = conn.peer.put_data(line.to_utf8_buffer())
				if sent != OK:
					return false
		return Time.get_ticks_msec() - conn.opened_msec < IDLE_MSEC
	conn.delivered = true
	out.append({
		"id": conn.id,
		"method": request["method"],
		"path": request["path"],
		"query": request["query"],
		"headers": request["headers"],
		"body": request["body"],
	})
	return true


func _write(conn: Conn, status: int, content_type: String,
		body: PackedByteArray, extra: Dictionary) -> void:
	if conn.peer == null or conn.peer.get_status() \
			!= StreamPeerTCP.STATUS_CONNECTED:
		return
	var head: String = "HTTP/1.1 %d %s%s" % [status, status_text(status), CRLF]
	head += "Content-Type: %s%s" % [content_type, CRLF]
	head += "Content-Length: %d%s" % [body.size(), CRLF]
	head += "Cache-Control: no-store" + CRLF
	head += "Connection: close" + CRLF
	for name: Variant in extra.keys():
		head += "%s: %s%s" % [DictRead.as_string(name),
			DictRead.as_string(extra[name]), CRLF]
	head += CRLF
	var bytes: PackedByteArray = head.to_utf8_buffer()
	bytes.append_array(body)
	# `put_data` blocks until the whole buffer is taken, and this runs inside
	# `_process`: a peer that stops reading a multi-megabyte `/shot` can park
	# the frame. It has not been reproduced on loopback, but a **short or
	# failed** write must not be silent -- the client was promised a
	# `Content-Length` it would then never receive.
	var sent: Error = conn.peer.put_data(bytes)
	if sent != OK:
		push_warning("agent: answer to %d not delivered (%d)" % [conn.id, sent])


func _close(conn: Conn) -> void:
	if conn.peer == null:
		return
	conn.peer.disconnect_from_host()
	conn.peer = null


func _index_of(id: int) -> int:
	for i: int in range(_conns.size()):
		if _conns[i].id == id:
			return i
	return -1


static func _error_body(message: String) -> PackedByteArray:
	return JSON.stringify({"error": message}).to_utf8_buffer()


## Where the head ends and the body begins, as `(head_end, body_start)`.
##
## `\n\n` is accepted beside `\r\n\r\n`: a request typed by hand or sent by a
## three-line client would otherwise sit in the buffer until `MAX_HEAD`.
##
## The scan stops at [constant MAX_HEAD] rather than running to the end of the
## buffer. A body arriving over several frames is re-parsed on each of them,
## and without the bound a megabyte of `POST` body would be swept for a
## terminator that cannot be past the first sixteen kilobytes -- a head longer
## than that is refused by the caller anyway.
static func _head_end(bytes: PackedByteArray) -> Vector2i:
	var size: int = mini(bytes.size(), MAX_HEAD + 1)
	for i: int in range(size):
		if bytes[i] != 10:
			continue
		if i >= 1 and bytes[i - 1] == 10:
			return Vector2i(i - 1, i + 1)
		if i >= 3 and bytes[i - 1] == 13 and bytes[i - 2] == 10 \
				and bytes[i - 3] == 13:
			return Vector2i(i - 3, i + 1)
	return Vector2i(-1, -1)
