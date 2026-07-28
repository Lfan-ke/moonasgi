///|
/// The outcome of the ASGI 3.0 conformance harness: how many round-trip checks
/// ran, how many `passed`, and the names of any that `failures`. A clean run has
/// an empty `failures`. Reusable beyond the test suite — a server or framework
/// built on the seam can call `run_conformance` to self-verify the wiring.
pub(all) struct ConformanceReport {
  total : Int
  passed : Int
  failures : Array[String]
} derive(Eq)

///|
/// Whether every conformance check passed (no failures recorded).
pub fn ConformanceReport::ok(self : ConformanceReport) -> Bool {
  self.failures.length() == 0
}

///|
/// One of each `Event` variant, distinct payloads — the table the harness folds
/// over to prove `Event`'s derived equality discriminates every message in the
/// http / websocket / lifespan sets in both directions (no two variants collapse).
fn all_event_variants() -> Array[Event] {
  [
    HttpRequest(body=b"body", more_body=true),
    HttpDisconnect,
    HttpResponseStart(status=200, headers=[("a", "b")], trailers=false),
    HttpResponseBody(body=b"x", more_body=false),
    HttpResponseTrailers(headers=[("t", "v")], more_trailers=false),
    HttpResponsePush(path="/p", headers=[]),
    HttpResponsePathSend(path="/f"),
    HttpResponseEarlyHint(links=["</a>; rel=preload"]),
    WebSocketConnect,
    WebSocketReceive(text=Some("hi"), bytes=None),
    WebSocketDisconnect(code=1000),
    WebSocketAccept(subprotocol=Some("chat"), headers=[]),
    WebSocketSendText("hi"),
    WebSocketSendBytes(b"hi"),
    WebSocketClose(code=1001, reason="bye"),
    WebSocketHttpResponseStart(status=403, headers=[]),
    WebSocketHttpResponseBody(body=b"no", more_body=false),
    LifespanStartup,
    LifespanShutdown,
    LifespanStartupComplete,
    LifespanStartupFailed(message="boom"),
    LifespanShutdownComplete,
    LifespanShutdownFailed(message="boom"),
  ]
}

///|
/// Run the ASGI 3.0 conformance harness: a table-driven battery that drives every
/// `Event` variant and every `Scope` field through `run_http`, `ws_run`, and the
/// `TestClient`, asserting round-trip fidelity — a value put in comes back
/// unchanged, and no two distinct events or scope shapes are confused. Returns a
/// `ConformanceReport` naming any check that failed, so the suite (and any
/// downstream server) can assert `ok()`.
pub fn run_conformance() -> ConformanceReport {
  let results : Array[(String, Bool)] = []
  let check = fn(name : String, cond : Bool) -> Unit {
    results.push((name, cond))
  }

  // A. every Event variant is self-equal and pairwise-distinct: derived equality
  //    discriminates all 23 messages, so none collapses into another.
  let evs = all_event_variants()
  check("event/count", evs.length() == 23)
  for i in 0..<evs.length() {
    check("event/self-eq[" + i.to_string() + "]", evs[i] == evs[i])
    for j in (i + 1)..<evs.length() {
      check(
        "event/distinct[" + i.to_string() + "," + j.to_string() + "]",
        evs[i] != evs[j],
      )
    }
  }

  // B. http response round-trip through the TestClient: status, headers and body
  //    survive lowering to events and reassembly.
  let http_cases : Array[(Int, Array[(String, String)], Bytes)] = [
    (200, [("content-type", "text/plain")], b"ok"),
    (404, [], b""),
    (201, [("x-a", "1"), ("x-b", "2")], b"created"),
    (500, [("x-err", "boom")], b"\x00\x01\x02"),
  ]
  for c in http_cases {
    let (status, headers, body) = c
    let client = TestClient::new(fn(_req) {
      Response::new(status, headers, body)
    })
    let r = client.get("/")
    check(
      "http/roundtrip[" + status.to_string() + "]",
      r.status == status && r.headers == headers && r.body == body,
    )
  }

  // C. request-line fields reach the handler intact: method, path, query, a
  //    streamed body, and header merge.
  let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
  for m in methods {
    let seen : Array[String] = []
    let client = TestClient::new(fn(req) {
      seen.push(req.http_method)
      Response::text("ok")
    })
    let _ = client.request(http_method=m, path="/x")
    check("http/method[" + m + "]", seen.length() == 1 && seen[0] == m)
  }
  let qseen : Array[(String, Bytes)] = []
  let qclient = TestClient::new(fn(req) {
    qseen.push((req.path, req.query_string))
    Response::text("ok")
  })
  let _ = qclient.get("/search?q=moonbit&n=3")
  check(
    "http/query-split",
    qseen.length() == 1 &&
    qseen[0].0 == "/search" &&
    qseen[0].1 == b"q=moonbit&n=3",
  )
  let bseen : Array[Bytes] = []
  let bclient = TestClient::new(fn(req) {
    bseen.push(req.body)
    Response::text("ok")
  })
  let _ = bclient.request(http_method="POST", path="/u", chunks=[
    b"chunk-1;", b"chunk-2",
  ])
  check(
    "http/streamed-body",
    bseen.length() == 1 && bseen[0] == b"chunk-1;chunk-2",
  )

  // D. every Scope field round-trips: build each scope kind with all fields set
  //    distinctively and read them back, and check the per-subprotocol
  //    spec_version defaults.
  let hs = HttpScope::new(
    http_method="POST",
    path="/deep",
    http_version="2",
    scheme="https",
    raw_path=b"/deep",
    query_string=b"k=v",
    root_path="/api",
    headers=[("host", "h")],
    client=Some(("1.2.3.4", 5)),
    server=Some(("9.8.7.6", 4)),
    extensions=Extensions::none().enable_push(),
    state=Map([("k", Json::string("v"))]),
  )
  check(
    "scope/http-fields",
    hs.http_method == "POST" &&
    hs.path == "/deep" &&
    hs.http_version == "2" &&
    hs.scheme == "https" &&
    hs.raw_path == b"/deep" &&
    hs.query_string == b"k=v" &&
    hs.root_path == "/api" &&
    hs.headers == [("host", "h")] &&
    hs.client == Some(("1.2.3.4", 5)) &&
    hs.server == Some(("9.8.7.6", 4)) &&
    hs.extensions.http_response_push &&
    hs.asgi.spec_version == "2.4",
  )
  let wss = WebSocketScope::new(
    path="/ws",
    scheme="wss",
    query_string=b"t=1",
    root_path="/rt",
    headers=[("origin", "o")],
    client=Some(("c", 1)),
    server=Some(("s", 2)),
    subprotocols=["chat", "json"],
    extensions=Extensions::none().enable_websocket_http_response(),
  )
  check(
    "scope/ws-fields",
    wss.path == "/ws" &&
    wss.scheme == "wss" &&
    wss.query_string == b"t=1" &&
    wss.root_path == "/rt" &&
    wss.headers == [("origin", "o")] &&
    wss.client == Some(("c", 1)) &&
    wss.server == Some(("s", 2)) &&
    wss.subprotocols == ["chat", "json"] &&
    wss.extensions.websocket_http_response &&
    wss.asgi.spec_version == "2.4",
  )
  let ls = LifespanScope::new(state=Map([("boot", true.to_json())]))
  check(
    "scope/lifespan-fields",
    ls.asgi.spec_version == "2.0" && ls.state.get("boot") is Some(_),
  )

  // E. websocket round-trip through ws_run / TestClient: echo, subprotocol,
  //    reject, deny-with-http, and app-initiated close.
  let echo = TestClient::new(fn(_r) { Response::text("") })
  let s_echo = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::echo(subprotocol=Some("chat")),
    send=[Text("a"), Binary(b"b"), Text("c")],
  )
  check(
    "ws/echo",
    s_echo.accepted &&
    s_echo.subprotocol == Some("chat") &&
    s_echo.messages == [Text("a"), Binary(b"b"), Text("c")] &&
    s_echo.texts() == ["a", "c"],
  )
  let s_reject = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      Reject(code=4403, reason="nope")
    }),
    send=[Text("ignored")],
  )
  check(
    "ws/reject",
    !s_reject.accepted &&
    s_reject.closed &&
    s_reject.close_code == Some(4403) &&
    s_reject.messages.length() == 0,
  )
  let s_deny = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      DenyHttp(status=401, headers=[("x", "y")], body=b"denied")
    }),
  )
  let deny_ok = match s_deny.denial {
    Some(resp) => resp.status == 401 && resp.body == b"denied"
    None => false
  }
  check("ws/deny-http", !s_deny.accepted && deny_ok)
  let s_close = echo.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_receive=fn(_m) {
      [SendText("bye"), Close(code=1000, reason="done")]
    }),
    send=[Text("first"), Text("second-should-be-ignored")],
    disconnect=None,
  )
  check("ws/app-close", s_close.messages == [Text("bye")] && s_close.closed)
  // ws_run_app escape hatch sees the full scope (subprotocols) and inbound stream.
  let s_app = echo.websocket_app(
    path="/ws",
    app=fn(scope : WebSocketScope, inbound : Array[Event]) {
      [
        WebSocketAccept(subprotocol=scope.subprotocols.get(0), headers=[
          ("x-frames", inbound.length().to_string()),
        ]),
      ]
    },
    subprotocols=["v1"],
    send=[Text("a"), Text("b")],
    disconnect=None,
  )
  check(
    "ws/run_app",
    s_app.accepted &&
    s_app.subprotocol == Some("v1") &&
    s_app.header("x-frames") == Some("3"),
  )

  // F. extension capability flags round-trip onto the scope; early-hint events
  //    are captured by the client.
  let ext = Extensions::none()
    .enable_push()
    .enable_trailers()
    .enable_pathsend()
    .enable_early_hint()
    .enable_websocket_http_response()
  check(
    "ext/flags",
    ext.http_response_push &&
    ext.http_response_trailers &&
    ext.http_response_pathsend &&
    ext.http_response_early_hint &&
    ext.websocket_http_response,
  )
  let eh_client = TestClient::from_app(fn(_req) {
    [
      HttpResponseEarlyHint(links=["</a.css>; rel=preload"]),
      HttpResponseEarlyHint(links=[
        "</b.js>; rel=preload", "</c.js>; rel=preload",
      ]),
      HttpResponseStart(status=200, headers=[], trailers=false),
      HttpResponseBody(body=b"", more_body=false),
    ]
  })
  let eh = eh_client.get("/")
  check(
    "ext/early-hint",
    eh.early_hints.length() == 2 &&
    eh.early_hints[0] == ["</a.css>; rel=preload"] &&
    eh.early_hints[1] == ["</b.js>; rel=preload", "</c.js>; rel=preload"],
  )

  // G. streaming response round-trip: early hints, chunked body, and trailers.
  let stream = StreamingResponse::new(
    status=200,
    chunks=[b"one ", b"two"],
    trailers=[("digest", "abc")],
    early_hints=[["</s.css>; rel=preload"]],
  )
  let sclient = TestClient::from_stream(fn(_r) { stream })
  let sr = sclient.get("/")
  check(
    "stream/roundtrip",
    sr.body == b"one two" &&
    sr.trailer("digest") == Some("abc") &&
    sr.early_hints == [["</s.css>; rel=preload"]],
  )

  // H. spec_version negotiation compares numerically across the dotted version.
  let ver_cases : Array[(String, Int, Int, Bool)] = [
    ("2.4", 2, 0, true),
    ("2.4", 2, 4, true),
    ("2.4", 2, 5, false),
    ("2.4", 1, 9, true),
    ("2.4", 3, 0, false),
    ("2.10", 2, 9, true),
    ("2.0", 2, 0, true),
    ("2.0", 2, 1, false),
  ]
  for vc in ver_cases {
    let (sv, maj, minr, want) = vc
    let v : AsgiVersion = { version: "3.0", spec_version: sv }
    check(
      "spec_version/" + sv + ">=" + maj.to_string() + "." + minr.to_string(),
      v.at_least(major=maj, minor=minr) == want,
    )
  }
  let failures : Array[String] = []
  for r in results {
    if !r.1 {
      failures.push(r.0)
    }
  }
  {
    total: results.length(),
    passed: results.length() - failures.length(),
    failures,
  }
}
