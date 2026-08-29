///|
/// The event stream the seam itself emits for a real request is spec-compliant:
/// run a handler through `run_http`, then validate the outbound events. If the
/// serialisation ever emitted a body before the start, or dropped the final
/// body, `validate_events` would name the violation.
test "run_http output validates as a well-formed http response" {
  let handler : Handler = fn(req) {
    Response::new(200, [("x-echo", req.path)], req.body)
  }
  let scope = Http(HttpScope::new(http_method="POST", path="/echo"))
  let out = run_http(handler, scope, [
    HttpRequest(body=b"hello", more_body=false),
  ])
  assert_eq(validate_events(scope, out) is None, true)
}

///|
/// A streaming response with early hints, a chunked body, and trailers lowers to
/// an ordering the validator accepts — hints before start, start promising
/// trailers, chunks, then a terminating trailers frame.
test "streaming response with trailers validates" {
  let sr = StreamingResponse::new(
    chunks=[b"a", b"b"],
    trailers=[("digest", "x")],
    early_hints=[["</a.css>"]],
  )
  let events = sr.events()
  assert_eq(validate_http_response(events) is None, true)
}

///|
/// The websocket driver's real output validates for each handshake outcome:
/// accept-then-echo, bare reject, and deny-with-response.
test "ws_run output validates for accept, reject, and deny" {
  let scope = WebSocket(WebSocketScope::new(path="/ws"))
  let accept_out = ws_run(WebSocketHandler::echo(), scope, [
    WebSocketConnect,
    WebSocketReceive(text=Some("hi"), bytes=None),
    WebSocketDisconnect(code=1000, reason=None),
  ])
  assert_eq(validate_ws_response(accept_out) is None, true)
  let reject_out = ws_run(
    WebSocketHandler::new(on_connect=fn(_s) { Reject(code=4403, reason="no") }),
    scope,
    [WebSocketConnect],
  )
  assert_eq(validate_ws_response(reject_out) is None, true)
  let deny_out = ws_run(
    WebSocketHandler::new(on_connect=fn(_s) {
      DenyHttp(status=401, headers=[], body=b"no")
    }),
    scope,
    [WebSocketConnect],
  )
  assert_eq(validate_ws_response(deny_out) is None, true)
}

///|
/// A direct malformed stream is rejected with the exact violation, and a
/// well-formed one passes — the two halves the negative table rides on.
test "validator names the violation and passes a clean stream" {
  let start = HttpResponseStart(status=200, headers=[], trailers=false)
  let body = HttpResponseBody(body=b"x", more_body=false)
  assert_eq(validate_http_response([start, body]) is None, true)
  assert_eq(validate_http_response([body]) == Some(BodyBeforeStart), true)
  assert_eq(
    validate_http_response([start, start]) == Some(DuplicateResponseStart),
    true,
  )
  assert_eq(
    validate_http_response([start, body, body]) == Some(BodyAfterComplete),
    true,
  )
  // A promised-trailers response that never sends them is incomplete.
  assert_eq(
    validate_http_response([
      HttpResponseStart(status=200, headers=[], trailers=true),
      body,
    ]) ==
    Some(MissingTrailers),
    true,
  )
}

///|
/// The disconnect event carries the ASGI 2.5 `reason`, and the handler's
/// `on_disconnect` receives both code and reason.
test "on_disconnect receives the 2.5 close code and reason" {
  let seen : Array[(Int, String?)] = []
  let scope = WebSocket(WebSocketScope::new(path="/ws"))
  let _ = ws_run(
    WebSocketHandler::new(on_disconnect=fn(code, reason) {
      seen.push((code, reason))
      []
    }),
    scope,
    [
      WebSocketConnect,
      WebSocketDisconnect(code=1001, reason=Some("going away")),
    ],
  )
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].0, 1001)
  assert_eq(seen[0].1, Some("going away"))
}

///|
/// The zero-copy send and debug extensions round-trip through the TestClient:
/// an app emits both after the response starts, and the client captures the fd /
/// offset / count and every debug payload.
test "zerocopysend and debug extensions round-trip through the TestClient" {
  let app : (Request) -> Array[Event] = fn(_req) {
    [
      HttpResponseStart(status=200, headers=[], trailers=false),
      HttpResponseDebug(info={ "handler": "files" }.to_json()),
      HttpResponseZeroCopySend(
        fd=11,
        offset=Some(4),
        count=Some(1024),
        more_body=false,
      ),
    ]
  }
  let client = TestClient::from_app(app)
  let r = client.get("/download")
  assert_eq(r.status, 200)
  match r.zerocopysend {
    Some(z) => {
      assert_eq(z.fd, 11)
      assert_eq(z.offset, Some(4))
      assert_eq(z.count, Some(1024))
    }
    None => abort("expected a zerocopysend capture")
  }
  assert_eq(r.debug.length(), 1)
  assert_eq(r.debug[0], { "handler": "files" }.to_json())
}

///|
/// A message type the server and application agreed on privately rides through the
/// validator: the spec lets them invent their own, so an unknown type is not the
/// same thing as a message from the wrong scope.
test "a custom event type is neither rejected nor counted" {
  let scope = Scope::Http(
    HttpScope::new(http_method="GET", path="/", http_version="1.1"),
  )
  let ok = validate_events(scope, [
    Event::HttpResponseStart(status=200, headers=[], trailers=false),
    Event::Other(type_="mychat.message", payload={ "text": "hhh" }.to_json()),
    Event::HttpResponseBody(body=b"", more_body=false),
  ])
  assert_eq(ok is None, true)
  // It does not stand in for the response either.
  let missing = validate_events(scope, [
    Event::Other(type_="mychat.message", payload=Json::null()),
  ])
  assert_eq(missing is Some(MissingResponseStart), true)
}

///|
/// A server advertises an extension this seam does not name, and an application
/// finds it by name.
test "custom extensions are advertised and read back by name" {
  let ext = Extensions::none().enable(
    "mychat.presence",
    value={ "max": 233 }.to_json(),
  )
  assert_eq(ext.get("mychat.presence") is Some(_), true)
  assert_eq(ext.get("nope") is None, true)
}
