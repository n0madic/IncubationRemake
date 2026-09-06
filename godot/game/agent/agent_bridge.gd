class_name AgentBridge
extends Node

## The control server's policy layer: routing, one batch at a time, and the
## frame loop that ties the socket to the game (docs/92 section 7.16).
##
## It attaches to a **normal** launch:
##
##     godot --path godot -- --mission=_C_140 --agent-port=8787
##
## and is inert without the flag, which is why it ships inside `game/` rather
## than beside a driver the export preset excludes. What is driven is then the
## build a player runs, not a driver-shaped copy of it.
##
## The order inside [method _process] is the whole design: every request that
## arrived is routed and answered **first**, and the session is stepped after.
## A `GET /state` therefore comes back in the frame it landed even while a
## `POST /command` has been running for four hundred frames -- the question the
## directory protocol that preceded this could not be asked at all.

const PORT_ARG: String = "--agent-port="

## [method port_from_args] for `--agent-port=0` and `--agent-port=auto`: bind
## whatever the kernel gives. It is not 0, because 0 is how "no flag" is said.
const PORT_AUTO: int = -1

const DIR_ARG: String = "--agent-dir="

## Higher runs later, so the snapshot is read after [method SliceMain._process]
## has moved the frame on. Child-after-parent tree order gives that already;
## this makes it a decision rather than luck.
const PRIORITY: int = 1000

const ROUTE_HEALTH: String = "health"
const ROUTE_STATE: String = "state"
const ROUTE_SHOT: String = "shot"
const ROUTE_HELP: String = "help"
const ROUTE_COMMAND: String = "command"

## `route` answers with this when the request is to be refused; `status` says
## with what.
const ROUTE_REFUSED: String = "refused"

const TYPE_JSON: String = "application/json"
const TYPE_PNG: String = "image/png"

## The header `GET /shot?save=NAME` answers with.
const SHOT_HEADER: String = "X-Agent-Shot"

var _main: SliceMain = null
var _http: AgentHttpServer = null
var _session: AgentSession = null
var _parked: int = -1
var _quit_in: int = 0


func _init() -> void:
	set_process(false)


## Opens the socket. A non-`OK` return is the caller's to report: a game must
## never fail to start because a port was taken.
func begin(main: SliceMain, port: int, directory: String) -> Error:
	_main = main
	var root: Window = main.get_tree().root
	_http = AgentHttpServer.new()
	var opened: Error = _http.listen(maxi(port, 0))
	if opened != OK:
		_http = null
		return opened
	_session = AgentSession.new(main, root, directory)
	set_process(true)
	# Printed because `--agent-port=0` takes a free port, and a driver that
	# started several sessions has no other way to learn which.
	print("agent: listening on 127.0.0.1:%d" % _http.port())
	return OK


func port() -> int:
	return _http.port() if _http != null else 0


func _exit_tree() -> void:
	if _http != null:
		_http.stop()
	_http = null
	_session = null
	_main = null


func _process(_delta: float) -> void:
	if _http == null or _session == null:
		return
	if _quit_in > 0:
		_quit_in -= 1
		if _quit_in == 0:
			# The reply is already on the wire and its socket is closed. The
			# quit itself goes through `SliceMain`, which awaits the audio
			# shutdown first: leaving in the same frame the Ogg stream is
			# released leaks it (docs/97 section 14).
			_main._quit()
			return
	for request: Dictionary in _http.poll():
		_serve(request)
	if not _session.step():
		return
	var reply: Dictionary = _session.take_reply()
	if _parked >= 0:
		_http.respond(_parked, 200, TYPE_JSON,
			JSON.stringify(reply, "  ").to_utf8_buffer())
		_parked = -1
	if _session.is_leaving():
		_quit_in = 1


# --- the routes --------------------------------------------------------------

## Which handler a method and a path name, and with what status a refusal is
## answered.
##
## **Static and pure**, on [method SliceMain.boot_choice]'s precedent: "a read
## is answered while a command runs" and "a second command is 409" are then
## pinned by a suite rather than only tried by hand.
##
## Returns `{"action": String, "status": int, "allow": String}`.
static func route(method: String, path: String,
		running: bool = false) -> Dictionary:
	var clean: String = path
	if clean.length() > 1 and clean.ends_with("/"):
		clean = clean.trim_suffix("/")
	match clean:
		"/health":
			return _reads(method, ROUTE_HEALTH)
		"/state":
			return _reads(method, ROUTE_STATE)
		"/shot":
			return _reads(method, ROUTE_SHOT)
		"/help":
			return _reads(method, ROUTE_HELP)
		"/command":
			if method != "POST":
				return {"action": ROUTE_REFUSED, "status": 405, "allow": "POST"}
			if running:
				return {"action": ROUTE_REFUSED, "status": 409, "allow": ""}
			return {"action": ROUTE_COMMAND, "status": 200, "allow": ""}
	return {"action": ROUTE_REFUSED, "status": 404, "allow": ""}


## `GET` and nothing else. `HEAD` is refused rather than served, because the
## answer is built before the method is looked at again and a `HEAD` carrying a
## body is a worse answer than an honest 405.
static func _reads(method: String, action: String) -> Dictionary:
	if method != "GET":
		return {"action": ROUTE_REFUSED, "status": 405, "allow": "GET"}
	return {"action": action, "status": 200, "allow": ""}


## What `--agent-port=` asks for: a port number, **0** when the flag is absent,
## unreadable or out of range -- which means the bridge is not raised at all --
## and [constant PORT_AUTO] for `=0` and `=auto`, a free port the kernel picks.
##
## The bridge prints the number it was actually given, which is how several
## driving sessions run side by side without agreeing on ports in advance.
static func port_from_args(args: PackedStringArray) -> int:
	for arg: String in args:
		if not arg.begins_with(PORT_ARG):
			continue
		var value: String = arg.substr(PORT_ARG.length())
		if value == "auto":
			return PORT_AUTO
		if not value.is_valid_int():
			return 0
		var port: int = value.to_int()
		if port == 0:
			return PORT_AUTO
		if port < 1 or port > 65535:
			return 0
		return port
	return 0


## Why nothing is listening, when the flag was given and [method
## port_from_args] still answered 0. Empty when there is nothing to say.
##
## `SliceMain.boot_choice` warns on an unknown `--mission=` for the same
## reason: a flag that is silently ignored costs the caller its whole timeout
## with nothing to read.
static func port_warning(args: PackedStringArray) -> String:
	if port_from_args(args) != 0:
		return ""
	for arg: String in args:
		if arg.begins_with(PORT_ARG):
			return "agent: %s is not a port in 1..65535; no server started" % arg
	return ""


## `--agent-dir=PATH` -- where `shot NAME` and `?save=` write. It moves the
## screenshots and **nothing else**: a driven session writes its saves and its
## settings into the live `user://`, exactly as a played one does.
static func dir_from_args(args: PackedStringArray,
		fallback: String = AgentSession.DEFAULT_SHOT_DIR) -> String:
	for arg: String in args:
		if arg.begins_with(DIR_ARG):
			var value: String = arg.substr(DIR_ARG.length())
			if value != "":
				return value
	return fallback


# --- serving -----------------------------------------------------------------

func _serve(request: Dictionary) -> void:
	var id: int = DictRead.as_int(request["id"])
	var method: String = DictRead.as_string(request["method"])
	var path: String = DictRead.as_string(request["path"])
	# **A request from a web page is refused outright.** Loopback is not the
	# barrier it looks like: while the flag is set, any page the player has
	# open can fire a `POST` or an `<img src>` at 127.0.0.1, and omitting the
	# CORS header only stops it *reading* the answer, not sending the request.
	# A browser stamps `Origin` on exactly those, and no client of this server
	# ever sends one.
	if DictRead.as_dict(request["headers"]).has("origin"):
		_error(id, 403, "a browser is not a client of this server")
		return
	var chosen: Dictionary = route(method, path, _session.is_running())
	var action: String = DictRead.as_string(chosen["action"])
	match action:
		ROUTE_HEALTH:
			_json(id, {
				"ok": true,
				"port": _http.port(),
				"frame": _session.frame(),
				"index": _session.index(),
				"booted": _session.booted(),
				"busy": _session.busy(),
				"running": _session.is_running(),
			})
		ROUTE_STATE:
			_json(id, {
				"frame": _session.frame(),
				"running": _session.is_running(),
				"state": _session.state(),
			})
		ROUTE_HELP:
			_json(id, {
				"routes": {
					"GET /health": "liveness, answered before the world is up",
					"GET /state": "the snapshot, answered while a command runs",
					"GET /shot": "the current frame as PNG; ?save=NAME files it",
					"GET /help": "this",
					"POST /command": "a batch of verbs; 409 while one runs",
				},
				"verbs": AgentSession.VERBS,
			})
		ROUTE_SHOT:
			_shot(id, DictRead.as_dict(request["query"]))
		ROUTE_COMMAND:
			_command(id, request)
		_:
			_refuse(id, DictRead.as_int(chosen["status"]),
				DictRead.as_string(chosen["allow"]))


func _shot(id: int, query: Dictionary) -> void:
	var bytes: PackedByteArray = _session.capture_png()
	if bytes.is_empty():
		# `--headless` has no renderer, and a zero-byte PNG would be reported
		# by a client as an empty picture rather than as no picture at all.
		_error(id, 503, "no renderer")
		return
	var extra: Dictionary = {}
	var name: String = DictRead.as_string(query.get("save", ""))
	if name != "" and AgentSession.safe_shot_name(name) != name:
		# It becomes a file name under `--agent-dir=`; `..%2Fx` is a write
		# outside it, and this ships in the export.
		_error(id, 400, "save wants a file name, not a path")
		return
	if name != "":
		var written: String = _session.write_shot(name, bytes)
		if written == "":
			_error(id, 500, "cannot write %s" % name)
			return
		extra[SHOT_HEADER] = written
	_http.respond(id, 200, TYPE_PNG, bytes, extra)


func _command(id: int, request: Dictionary) -> void:
	var body: PackedByteArray = request["body"]
	var headers: Dictionary = DictRead.as_dict(request["headers"])
	var content: String = DictRead.as_string(headers.get("content-type", ""))
	var lines: PackedStringArray = PackedStringArray()
	if content.begins_with(TYPE_JSON):
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Array:
			lines = _to_lines(parsed)
		elif parsed is Dictionary:
			var document: Dictionary = parsed
			lines = _to_lines(document.get("lines", []))
		else:
			_error(id, 400, "the body is not JSON")
			return
	else:
		lines = AgentSession.parse_lines(body.get_string_from_utf8())
	_session.submit(lines)
	_parked = id


static func _to_lines(value: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry: Variant in DictRead.as_array(value):
		out.append(DictRead.as_string(entry))
	return out


func _json(id: int, document: Dictionary) -> void:
	_http.respond(id, 200, TYPE_JSON,
		JSON.stringify(document, "  ").to_utf8_buffer())


func _refuse(id: int, status: int, allow: String) -> void:
	var extra: Dictionary = {}
	if allow != "":
		extra["Allow"] = allow
	if status == 409:
		extra["Retry-After"] = "1"
		_http.respond(id, status, TYPE_JSON, JSON.stringify({
			"error": "a command is already running",
			"busy": true,
			"index": _session.index(),
			"frame": _session.frame(),
		}).to_utf8_buffer(), extra)
		return
	_http.respond(id, status, TYPE_JSON,
		JSON.stringify({"error": AgentHttpServer.status_text(status)})
			.to_utf8_buffer(), extra)


func _error(id: int, status: int, message: String) -> void:
	_http.respond(id, status, TYPE_JSON,
		JSON.stringify({"error": message}).to_utf8_buffer())
