extends TestSuite

## The agent control server -- docs/92 section 7.16.
##
## Oracle boundary: **specification-only**, and it can be nothing else. This is
## the remake's own protocol; there is no original behaviour to diff against.
## What is checked is the half that can rot silently: the request grammar, the
## routing decision, the command-line flags, the line grammar, and that the
## verb table and the dispatch table are the **same set** -- the header table
## of the directory driver this replaced had drifted to sixteen entries of
## thirty, and nothing noticed.
##
## The last group is a real round trip over the loopback address. `--headless`
## has no renderer, which is why `capture_png` is not exercised here, but it
## has full TCP: what a socket does is checked with a socket.

## Long enough that a loaded machine does not fail the run, short enough that a
## broken socket is a failing check rather than a hung suite.
const DEADLINE_MSEC: int = 3000


func run(h: TestHarness) -> void:
	h.begin("agent", TestHarness.ORACLE_SPEC)
	_parse_requests(h)
	_parse_partial(h)
	_parse_refusals(h)
	_targets(h)
	_routes(h)
	_flags(h)
	_lines(h)
	_verbs(h)
	_shot_names(h)
	_boot_gate(h)
	_loopback(h)
	_loopback_body(h)
	_slow_reader(h)


# --- the request grammar -----------------------------------------------------

func _parse_requests(h: TestHarness) -> void:
	var get_request: Dictionary = AgentHttpServer.parse_request(
		_bytes("GET /state HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	h.check("get.complete", DictRead.as_bool(get_request["complete"]))
	h.equal("get.method", get_request["method"], "GET")
	h.equal("get.path", get_request["path"], "/state")
	h.equal("get.error", get_request["error"], "")
	var empty: PackedByteArray = get_request["body"]
	h.equal("get.body_empty", empty.size(), 0)

	var post: Dictionary = AgentHttpServer.parse_request(_bytes(
		"POST /command HTTP/1.1\r\nContent-Length: 5\r\n"
		+ "Content-Type: text/plain\r\n\r\nidle\n"))
	h.check("post.complete", DictRead.as_bool(post["complete"]))
	h.equal("post.method", post["method"], "POST")
	var body: PackedByteArray = post["body"]
	h.equal("post.body", body.get_string_from_utf8(), "idle\n")

	# **Header names are lowercased at parse time**, so no caller anywhere has
	# to spell a case; `curl` sends `Content-Length`, `urllib` sends
	# `Content-length`, and a hand-written client sends whatever it likes.
	var shouted: Dictionary = AgentHttpServer.parse_request(_bytes(
		"POST /command HTTP/1.1\r\nCONTENT-LENGTH: 2\r\n\r\nhi"))
	var headers: Dictionary = DictRead.as_dict(shouted["headers"])
	h.equal("post.header_case", headers.get("content-length", ""), "2")
	h.check("post.header_case.complete", DictRead.as_bool(shouted["complete"]))

	# An LF-only head is accepted beside CRLF: a three-line client that forgets
	# the carriage returns would otherwise sit in the buffer until the head
	# limit, which reads as a hang rather than as a mistake.
	var bare: Dictionary = AgentHttpServer.parse_request(
		_bytes("GET /help HTTP/1.1\nHost: x\n\n"))
	h.check("lf_only.complete", DictRead.as_bool(bare["complete"]))
	h.equal("lf_only.path", bare["path"], "/help")

	# A pipelined second request must not be eaten by the first.
	var head: String = "GET /health HTTP/1.1\r\n\r\n"
	var pair: Dictionary = AgentHttpServer.parse_request(
		_bytes(head + "GET /state HTTP/1.1\r\n\r\n"))
	h.equal("pipelined.consumed", pair["consumed"], head.length())


func _parse_partial(h: TestHarness) -> void:
	# The body one byte short. **Not an error** -- it is the normal state of a
	# request whose second packet has not landed yet, and treating it as one
	# would answer 400 to every large command.
	var first: PackedByteArray = _bytes(
		"POST /command HTTP/1.1\r\nContent-Length: 8\r\n\r\nidle")
	var early: Dictionary = AgentHttpServer.parse_request(first)
	h.check("partial.incomplete", not DictRead.as_bool(early["complete"]))
	h.check("partial.head_complete", DictRead.as_bool(early["head_complete"]))
	h.equal("partial.no_error", early["error"], "")

	var whole: PackedByteArray = first.duplicate()
	whole.append_array(_bytes(" 600"))
	var late: Dictionary = AgentHttpServer.parse_request(whole)
	h.check("partial.completes", DictRead.as_bool(late["complete"]))
	var body: PackedByteArray = late["body"]
	h.equal("partial.body", body.get_string_from_utf8(), "idle 600")

	# A head with no terminator at all is incomplete and silent, whatever it
	# looks like.
	var truncated: Dictionary = AgentHttpServer.parse_request(
		_bytes("GET /state HTTP/1.1\r\nHost: local"))
	h.check("truncated.incomplete",
		not DictRead.as_bool(truncated["complete"]))
	h.check("truncated.head_incomplete",
		not DictRead.as_bool(truncated["head_complete"]))
	h.equal("truncated.no_error", truncated["error"], "")


func _parse_refusals(h: TestHarness) -> void:
	var garbage: Dictionary = AgentHttpServer.parse_request(
		_bytes("not-a-request\r\n\r\n"))
	h.check("garbage.error", DictRead.as_string(garbage["error"]) != "")
	h.equal("garbage.status", garbage["status"], 400)

	var chunked: Dictionary = AgentHttpServer.parse_request(_bytes(
		"POST /command HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
	h.equal("chunked.status", chunked["status"], 501)

	var huge: Dictionary = AgentHttpServer.parse_request(_bytes(
		"POST /command HTTP/1.1\r\nContent-Length: %d\r\n\r\n"
		% (AgentHttpServer.MAX_BODY + 1)))
	h.equal("oversize.status", huge["status"], 413)

	# A head that never terminates is refused rather than buffered forever.
	var flood: PackedByteArray = _bytes("GET / HTTP/1.1\r\nX: ")
	flood.resize(AgentHttpServer.MAX_HEAD + 2)
	var over: Dictionary = AgentHttpServer.parse_request(flood)
	h.equal("head_flood.status", over["status"], 431)


func _targets(h: TestHarness) -> void:
	var plain: Dictionary = AgentHttpServer.split_target("/shot")
	h.equal("target.path", plain["path"], "/shot")
	h.equal("target.query_empty",
		DictRead.as_dict(plain["query"]).size(), 0)

	var pairs: Dictionary = AgentHttpServer.split_target("/shot?a=1&b=2")
	h.equal("target.a", DictRead.as_dict(pairs["query"]).get("a", ""), "1")
	h.equal("target.b", DictRead.as_dict(pairs["query"]).get("b", ""), "2")
	h.equal("target.path_before_query", pairs["path"], "/shot")

	var escaped: Dictionary = AgentHttpServer.split_target("/shot?save=a%20b")
	h.equal("target.decoded",
		DictRead.as_dict(escaped["query"]).get("save", ""), "a b")

	var bare: Dictionary = AgentHttpServer.split_target("/state?verbose")
	h.equal("target.valueless",
		DictRead.as_dict(bare["query"]).get("verbose", "-"), "")

	var request: Dictionary = AgentHttpServer.parse_request(
		_bytes("GET /shot?save=one HTTP/1.1\r\n\r\n"))
	h.equal("request.query_reaches_the_caller",
		DictRead.as_dict(request["query"]).get("save", ""), "one")


# --- the routes --------------------------------------------------------------

func _routes(h: TestHarness) -> void:
	for path: String in ["/health", "/state", "/shot", "/help"]:
		var chosen: Dictionary = AgentBridge.route("GET", path)
		h.equal("route.get%s" % path, chosen["action"],
			path.substr(1))
		h.equal("route.get%s.status" % path, chosen["status"], 200)
	h.equal("route.post_command",
		AgentBridge.route("POST", "/command")["action"],
		AgentBridge.ROUTE_COMMAND)

	# **The point of the whole change**: a read is answered while a command is
	# running. The directory protocol could not be asked at all.
	for path: String in ["/health", "/state", "/shot", "/help"]:
		var busy: Dictionary = AgentBridge.route("GET", path, true)
		h.equal("route.busy%s" % path, busy["action"], path.substr(1))

	# ...and a second command is not.
	var second: Dictionary = AgentBridge.route("POST", "/command", true)
	h.equal("route.second_command", second["action"],
		AgentBridge.ROUTE_REFUSED)
	h.equal("route.second_command.status", second["status"], 409)

	var wrong_verb: Dictionary = AgentBridge.route("GET", "/command")
	h.equal("route.get_command.status", wrong_verb["status"], 405)
	h.equal("route.get_command.allow", wrong_verb["allow"], "POST")

	var posted_read: Dictionary = AgentBridge.route("POST", "/state")
	h.equal("route.post_state.status", posted_read["status"], 405)
	h.equal("route.post_state.allow", posted_read["allow"], "GET")

	# `HEAD` is refused rather than answered with a body it must not carry.
	var head: Dictionary = AgentBridge.route("HEAD", "/state")
	h.equal("route.head_state.status", head["status"], 405)

	var missing: Dictionary = AgentBridge.route("GET", "/nope")
	h.equal("route.unknown.action", missing["action"],
		AgentBridge.ROUTE_REFUSED)
	h.equal("route.unknown.status", missing["status"], 404)

	# A trailing slash is the same route, because a client's URL builder often
	# adds one and a 404 for it would be a puzzle rather than a message.
	h.equal("route.trailing_slash",
		AgentBridge.route("GET", "/state/")["action"], AgentBridge.ROUTE_STATE)


func _flags(h: TestHarness) -> void:
	h.equal("port.absent", AgentBridge.port_from_args(
		PackedStringArray(["--mission=_C_140"])), 0)
	h.equal("port.given", AgentBridge.port_from_args(
		PackedStringArray(["--mission=_C_140", "--agent-port=8787"])), 8787)
	h.equal("port.garbage", AgentBridge.port_from_args(
		PackedStringArray(["--agent-port=nonsense"])), 0)
	h.equal("port.out_of_range", AgentBridge.port_from_args(
		PackedStringArray(["--agent-port=70000"])), 0)
	h.equal("port.zero_is_auto", AgentBridge.port_from_args(
		PackedStringArray(["--agent-port=0"])), AgentBridge.PORT_AUTO)
	h.equal("port.auto", AgentBridge.port_from_args(
		PackedStringArray(["--agent-port=auto"])), AgentBridge.PORT_AUTO)

	h.equal("dir.default", AgentBridge.dir_from_args(PackedStringArray()),
		AgentSession.DEFAULT_SHOT_DIR)
	h.equal("dir.given", AgentBridge.dir_from_args(
		PackedStringArray(["--agent-dir=/tmp/shots"])), "/tmp/shots")
	h.equal("dir.empty_is_the_default", AgentBridge.dir_from_args(
		PackedStringArray(["--agent-dir="])), AgentSession.DEFAULT_SHOT_DIR)

	# A flag that is ignored in silence costs the caller its whole timeout with
	# nothing to read, which is why `boot_choice` warns on a bad `--mission=`.
	h.equal("port.no_warning_when_absent",
		AgentBridge.port_warning(PackedStringArray(["--mission=_C_140"])), "")
	h.equal("port.no_warning_when_good",
		AgentBridge.port_warning(PackedStringArray(["--agent-port=8787"])), "")
	h.check("port.warns_on_garbage", AgentBridge.port_warning(
		PackedStringArray(["--agent-port=nonsense"])).contains("nonsense"))
	h.check("port.warns_out_of_range", AgentBridge.port_warning(
		PackedStringArray(["--agent-port=70000"])) != "")


# --- the command grammar -----------------------------------------------------

func _lines(h: TestHarness) -> void:
	var lines: PackedStringArray = AgentSession.parse_lines(
		"# a comment\n\nclick_unit 0\r\n   idle 30  \n\n# another\nquit\n")
	h.equal("lines.count", lines.size(), 3)
	h.equal("lines.first", lines[0], "click_unit 0")
	h.equal("lines.trimmed", lines[1], "idle 30")
	h.equal("lines.last", lines[2], "quit")
	h.equal("lines.empty", AgentSession.parse_lines("").size(), 0)
	h.equal("lines.comments_only",
		AgentSession.parse_lines("# nothing\n#\n").size(), 0)
	# A `#` inside a line is **not** a comment: `note` carries prose.
	var noted: PackedStringArray = AgentSession.parse_lines("note bug #12\n")
	h.equal("lines.inline_hash", noted[0], "note bug #12")


## Every verb has a handler, every handler has a help line, and a word outside
## the table is refused.
##
## This is the check the directory driver never had: its header table listed
## sixteen of thirty verbs and drifted for two slices without failing anything.
func _verbs(h: TestHarness) -> void:
	var session: AgentSession = AgentSession.new(null, null, "")
	var handled: PackedStringArray = session.handled()
	handled.sort()
	var documented: PackedStringArray = PackedStringArray()
	for verb: String in AgentSession.VERBS.keys():
		documented.append(verb)
	documented.sort()
	h.check("verbs.some", documented.size() >= 25,
		"%d verbs" % documented.size())
	h.equal("verbs.dispatch_equals_help",
		", ".join(handled), ", ".join(documented))
	for verb: String in documented:
		h.check("verbs.help.%s" % verb,
			DictRead.as_string(AgentSession.VERBS[verb]).begins_with(verb),
			"the help line must name its own verb")

	# A word outside the table is named rather than swallowed.
	session.run_line("definitely-not-a-verb 1 2")
	var log_lines: PackedStringArray = session.log_lines()
	h.equal("verbs.unknown.logged", log_lines.size(), 1)
	h.check("verbs.unknown.named",
		log_lines.size() == 1 and log_lines[0].begins_with(AgentSession.UNKNOWN),
		"got %s" % (log_lines[0] if not log_lines.is_empty() else "nothing"))
	# A session with no game answers `/state` with an empty document rather
	# than taking the process down: `/state` is served from the first frame.
	h.equal("verbs.state_without_a_game", session.state().size(), 0)
	h.check("verbs.not_booted", not session.booted())
	session = null


## `?save=` and `shot NAME` become a file name under `--agent-dir=`, and the
## name arrives off the network -- so it must be a name and not a path.
func _shot_names(h: TestHarness) -> void:
	h.equal("shot_name.plain", AgentSession.safe_shot_name("before"), "before")
	h.equal("shot_name.dotted",
		AgentSession.safe_shot_name("turn-3.after"), "turn-3.after")
	h.check("shot_name.parent_refused",
		AgentSession.safe_shot_name("../PWNED") != "../PWNED")
	h.check("shot_name.absolute_refused",
		AgentSession.safe_shot_name("/etc/PWNED") != "/etc/PWNED")
	h.check("shot_name.backslash_refused",
		AgentSession.safe_shot_name("..\\PWNED") != "..\\PWNED")
	h.equal("shot_name.dots_alone", AgentSession.safe_shot_name(".."), "")
	h.equal("shot_name.dot_alone", AgentSession.safe_shot_name("."), "")


## The boot gate must be a wait and not a wedge.
##
## A batch runs only once the game is up, so a click sent the moment the port
## answers does not run against nothing -- but a command can take the world
## down legitimately, and a gate that kept waiting would park the batch for
## ever, hold its socket open and answer every later command, `quit` included,
## with 409. Here the game never comes up at all, which is the same shape.
func _boot_gate(h: TestHarness) -> void:
	var session: AgentSession = AgentSession.new(null, null, "")
	session.submit(PackedStringArray(["note held"]))
	h.check("boot_gate.runs", session.is_running())
	h.check("boot_gate.waits", not session.step(), "it ran before a world")
	var finished: bool = false
	for _frame: int in range(AgentSession.BOOT_LIMIT + 40):
		if session.step():
			finished = true
			break
	h.check("boot_gate.finishes", finished,
		"the batch never ended: every later command would be 409")
	var reply: Dictionary = session.take_reply()
	h.check("boot_gate.not_running", not session.is_running())
	var lines: PackedStringArray = session.log_lines()
	h.check("boot_gate.says_why", ", ".join(lines).contains("no world"),
		"the giving-up must be in the log, not silent")
	h.check("boot_gate.ran_the_line", ", ".join(lines).contains("held"))
	h.equal("boot_gate.reply_index", reply["index"], 1)

	# **And it is not paid twice.** A second batch on a session that has given
	# up once runs at once: the gate is for the start-up, which happens once.
	session.submit(PackedStringArray(["note again"]))
	var second: bool = false
	for _again: int in range(4):
		if session.step():
			second = true
			break
	h.check("boot_gate.second_batch_is_not_gated", second,
		"a later batch waited for the boot all over again")
	session = null


# --- a real round trip -------------------------------------------------------

func _loopback(h: TestHarness) -> void:
	var server: AgentHttpServer = AgentHttpServer.new()
	var opened: Error = server.listen(0)
	h.check("loopback.listen", opened == OK, "listen(0) -> %d" % opened)
	if opened != OK:
		server.stop()
		return
	h.check("loopback.port", server.port() > 0, "port %d" % server.port())
	h.check("loopback.is_listening", server.is_listening())

	var client: StreamPeerTCP = StreamPeerTCP.new()
	var dialled: Error = client.connect_to_host("127.0.0.1", server.port())
	h.check("loopback.connect", dialled == OK, "connect -> %d" % dialled)

	var request: Dictionary = _exchange(server, client,
		_bytes("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
	h.check("loopback.arrived", not request.is_empty(), "no request in time")
	if request.is_empty():
		_shut(server, client)
		return
	h.equal("loopback.method", request["method"], "GET")
	h.equal("loopback.path", request["path"], "/health")

	# **The connection is held until it is answered.** That is the property the
	# long-command design rests on: a batch that runs for four hundred frames
	# is a socket parked for four hundred frames.
	var id: int = DictRead.as_int(request["id"])
	var repeats: int = 0
	for _round: int in range(20):
		repeats += server.poll().size()
		OS.delay_msec(1)
	h.equal("loopback.no_repeat", repeats, 0,
		"a delivered request came back")
	h.equal("loopback.pending", server.pending().size(), 1)
	h.equal("loopback.pending_id", server.pending()[0], id)

	var body: PackedByteArray = _bytes("{\"ok\":true}")
	h.check("loopback.nothing_to_deliver_before_the_answer",
		not server.delivering())
	server.respond(id, 200, "application/json", body)
	h.equal("loopback.answered", server.pending().size(), 0)
	# **Queued is not sent.** `respond` writes the bytes into the connection
	# and `poll` puts them on the wire, so a `quit` that left on the next
	# frame delivered its reply only by luck -- [AgentBridge] polls until
	# this goes false.
	h.check("loopback.the_answer_is_still_to_deliver", server.delivering(),
		"respond only queues; poll sends")

	var answer: String = _read(server, client).get_string_from_utf8()
	h.check("loopback.delivered_once_read", not server.delivering(),
		"the last byte left, and the connection closed with it")
	h.check("loopback.status_line", answer.begins_with("HTTP/1.1 200 OK"),
		"got %s" % answer.substr(0, 40))
	h.check("loopback.length_header",
		answer.contains("Content-Length: %d" % body.size()),
		"no matching Content-Length")
	h.check("loopback.close_header", answer.contains("Connection: close"))
	h.check("loopback.body", answer.ends_with("{\"ok\":true}"),
		"got %s" % answer.substr(maxi(0, answer.length() - 20)))

	server.stop()
	h.check("loopback.stopped", not server.is_listening())
	client.disconnect_from_host()
	_loopback_order(h)


## Two requests landing in one frame come out **oldest first**.
##
## The read loop used to walk the connection table backwards, so of two
## `POST /command` in one frame the later one took the batch and the earlier
## one was refused 409 -- the opposite of arrival order.
func _loopback_order(h: TestHarness) -> void:
	var server: AgentHttpServer = AgentHttpServer.new()
	if server.listen(0) != OK:
		h.check("order.listen", false, "cannot bind a loopback port")
		return
	var first: StreamPeerTCP = StreamPeerTCP.new()
	var second: StreamPeerTCP = StreamPeerTCP.new()
	var _a: Error = first.connect_to_host("127.0.0.1", server.port())
	var arrived: Dictionary = _exchange(server, first,
		_bytes("GET /state HTTP/1.1\r\n\r\n"))
	h.check("order.first_arrived", not arrived.is_empty())
	var _b: Error = second.connect_to_host("127.0.0.1", server.port())
	var later: Dictionary = _exchange(server, second,
		_bytes("GET /help HTTP/1.1\r\n\r\n"))
	h.check("order.second_arrived", not later.is_empty())
	if not arrived.is_empty() and not later.is_empty():
		h.check("order.oldest_first",
			DictRead.as_int(arrived["id"]) < DictRead.as_int(later["id"]),
			"the later connection was given the smaller id")
	h.equal("order.both_pending", server.pending().size(), 2)
	var waiting: PackedInt32Array = server.pending()
	h.check("order.pending_oldest_first", waiting[0] < waiting[1])
	server.stop()
	first.disconnect_from_host()
	second.disconnect_from_host()


## A body split across two writes must arrive **once**, complete. A buffer
## assembled in memory cannot prove this; two `put_data` calls with a poll
## between them can.
func _loopback_body(h: TestHarness) -> void:
	var server: AgentHttpServer = AgentHttpServer.new()
	if server.listen(0) != OK:
		h.check("split.listen", false, "cannot bind a loopback port")
		return
	var client: StreamPeerTCP = StreamPeerTCP.new()
	var _dialled: Error = client.connect_to_host("127.0.0.1", server.port())

	var head: PackedByteArray = _bytes(
		"POST /command HTTP/1.1\r\nContent-Length: 9\r\n\r\nclick 5")
	var arrived: Dictionary = _exchange(server, client, head, 300)
	h.check("split.not_yet", arrived.is_empty(),
		"a half-written body was delivered")

	var request: Dictionary = _exchange(server, client, _bytes(" 6"))
	h.check("split.arrived", not request.is_empty(), "no request in time")
	if not request.is_empty():
		var body: PackedByteArray = request["body"]
		h.equal("split.body", body.get_string_from_utf8(), "click 5 6")
		h.equal("split.path", request["path"], "/command")
		server.respond(DictRead.as_int(request["id"]), 200, "text/plain",
			PackedByteArray())
	_shut(server, client)


## A screenshot-sized response to a client that stops reading must return to
## the caller immediately, and another request must still reach the server.
## The old `put_data` implementation blocked here once the kernel send buffer
## filled, freezing both the game and every other connection.
func _slow_reader(h: TestHarness) -> void:
	var server: AgentHttpServer = AgentHttpServer.new()
	if server.listen(0) != OK:
		h.check("slow_reader.listen", false, "cannot bind a loopback port")
		return
	var slow: StreamPeerTCP = StreamPeerTCP.new()
	var _dialled: Error = slow.connect_to_host("127.0.0.1", server.port())
	var request: Dictionary = _exchange(server, slow,
		_bytes("GET /shot HTTP/1.1\r\n\r\n"))
	h.check("slow_reader.arrived", not request.is_empty())
	if request.is_empty():
		_shut(server, slow)
		return
	var large: PackedByteArray = PackedByteArray()
	large.resize(4 * 1024 * 1024)
	var started: int = Time.get_ticks_msec()
	server.respond(DictRead.as_int(request["id"]), 200,
		"application/octet-stream", large)
	var elapsed: int = Time.get_ticks_msec() - started
	h.check("slow_reader.respond_does_not_block", elapsed < 100,
		"queuing the response took %d ms" % elapsed)

	var other: StreamPeerTCP = StreamPeerTCP.new()
	var _other_dialled: Error = other.connect_to_host(
		"127.0.0.1", server.port())
	var health: Dictionary = _exchange(server, other,
		_bytes("GET /health HTTP/1.1\r\n\r\n"))
	h.check("slow_reader.other_request_arrives", not health.is_empty(),
		"the unread response held the server")
	if not health.is_empty():
		server.respond(DictRead.as_int(health["id"]), 200, "text/plain",
			_bytes("ok"))
		var answer: String = _read(server, other).get_string_from_utf8()
		h.check("slow_reader.other_request_is_answered", answer.ends_with("ok"))
	server.stop()
	slow.disconnect_from_host()
	other.disconnect_from_host()


# --- socket plumbing for the two above ---------------------------------------

## Sends `payload` and polls both ends until a request completes or the
## deadline passes. An expiry is an empty dictionary, never a hang.
func _exchange(server: AgentHttpServer, client: StreamPeerTCP,
		payload: PackedByteArray, limit: int = DEADLINE_MSEC) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + limit
	var sent: bool = false
	while Time.get_ticks_msec() < deadline:
		client.poll()
		if not sent and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var _wrote: Error = client.put_data(payload)
			sent = true
		var arrived: Array[Dictionary] = server.poll()
		if not arrived.is_empty():
			return arrived[0]
		OS.delay_msec(2)
	return {}


## One whole answer: the head, and then exactly `Content-Length` bytes.
##
## It stops on the length rather than on the close. Reading until the peer goes
## away means calling [method StreamPeer.get_available_bytes] on a socket the
## other end has already shut, which Godot answers with `-1` **and an error
## line** -- and `run_tests.sh` fails a run on an error line whether or not a
## check noticed.
func _read(server: AgentHttpServer, client: StreamPeerTCP) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	var deadline: int = Time.get_ticks_msec() + DEADLINE_MSEC
	while Time.get_ticks_msec() < deadline:
		var _requests: Array[Dictionary] = server.poll()
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var available: int = client.get_available_bytes()
		if available > 0:
			var got: Array = client.get_partial_data(available)
			var chunk: PackedByteArray = got[1]
			out.append_array(chunk)
			if _answer_complete(out):
				break
			continue
		OS.delay_msec(2)
	return out


## True once the buffer holds a head and the body its `Content-Length` names.
static func _answer_complete(bytes: PackedByteArray) -> bool:
	var text: String = bytes.get_string_from_utf8()
	var end: int = text.find("\r\n\r\n")
	if end < 0:
		return false
	var length: int = 0
	for line: String in text.substr(0, end).split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			length = line.substr(line.find(":") + 1).strip_edges().to_int()
	return bytes.size() >= end + 4 + length


func _shut(server: AgentHttpServer, client: StreamPeerTCP) -> void:
	server.stop()
	client.disconnect_from_host()


func _bytes(text: String) -> PackedByteArray:
	return text.to_utf8_buffer()
