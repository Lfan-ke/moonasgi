///|
/// The synchronous WebSocket core drives an echo handler in-process through the
/// TestClient: the handshake is accepted, the offered subprotocol is negotiated,
/// and every text/binary frame comes straight back — no socket, on every backend.
test "ws_run echoes text and binary frames through the TestClient" {
  let client = TestClient::new(fn(_r) { Response::text("") })
  let session = client.websocket(
    path="/chat",
    handler=WebSocketHandler::echo(subprotocol=Some("chat")),
    send=[Text("hello"), Binary(b"\x01\x02"), Text("bye")],
  )
  assert_eq(session.accepted, true)
  assert_eq(session.subprotocol, Some("chat"))
  assert_eq(
    session.messages == [Text("hello"), Binary(b"\x01\x02"), Text("bye")],
    true,
  )
  assert_eq(session.texts(), ["hello", "bye"])
}

///|
/// `ws_run` on a non-websocket scope is a no-op, mirroring `run_http` on a
/// non-http scope.
test "ws_run is a no-op for non-websocket scopes" {
  let out = ws_run(
    WebSocketHandler::echo(),
    Scope::Lifespan(LifespanScope::new()),
    [Event::LifespanStartup],
  )
  assert_eq(out.length(), 0)
}

///|
/// A handler that rejects the handshake emits a bare `WebSocketClose` with its
/// code, never accepts, and never processes any received frames.
test "ws handler can reject the handshake with a close code" {
  let client = TestClient::new(fn(_r) { Response::text("") })
  let session = client.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      Reject(code=4403, reason="forbidden")
    }),
    send=[Text("never seen")],
  )
  assert_eq(session.accepted, false)
  assert_eq(session.closed, true)
  assert_eq(session.close_code, Some(4403))
  assert_eq(session.close_reason, Some("forbidden"))
  assert_eq(session.messages.length(), 0)
}

///|
/// The `websocket.http.response` extension: a handler can deny the handshake with
/// a full HTTP response (status + headers + body) rather than a bare close, and
/// the client surfaces it as `WsTestSession.denial`.
test "ws handler can deny the handshake with a full HTTP response" {
  let client = TestClient::new(fn(_r) { Response::text("") })
  let session = client.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_connect=fn(_s) {
      DenyHttp(
        status=401,
        headers=[("www-authenticate", "Bearer")],
        body=@utf8.encode("unauthorized"),
      )
    }),
  )
  assert_eq(session.accepted, false)
  match session.denial {
    Some(resp) => {
      assert_eq(resp.status, 401)
      assert_eq(resp.header("www-authenticate"), Some("Bearer"))
      assert_eq(resp.text(), "unauthorized")
    }
    None => abort("expected a denial HTTP response")
  }
}

///|
/// A handler that closes mid-stream ends the exchange: frames it sends before the
/// `Close` are delivered, the session is marked closed, and later inbound
/// messages are never handed to `on_receive`.
test "ws handler closing mid-stream halts further receives" {
  let seen : Array[String] = []
  let client = TestClient::new(fn(_r) { Response::text("") })
  let session = client.websocket(
    path="/ws",
    handler=WebSocketHandler::new(on_receive=fn(m) {
      match m {
        Text(t) => {
          seen.push(t)
          [SendText("ack:" + t), Close(code=1000, reason="done")]
        }
        Binary(_) => []
      }
    }),
    send=[Text("first"), Text("second")],
    disconnect=None,
  )
  assert_eq(session.messages == [Text("ack:first")], true)
  assert_eq(session.closed, true)
  // on_receive ran only for the first message; the close halted the stream.
  assert_eq(seen, ["first"])
}

///|
/// The general `ws_run_app` escape hatch hands the whole inbound stream and the
/// full scope to the app, so it can read subprotocols/headers and emit any
/// sequence — here it reflects the negotiated subprotocol and the inbound frame
/// count into the accept response.
test "websocket_app exposes the full scope and inbound stream" {
  let client = TestClient::new(fn(_r) { Response::text("") })
  let session = client.websocket_app(
    path="/ws",
    app=fn(scope : WebSocketScope, inbound : Array[Event]) {
      let count = inbound.length().to_string()
      [
        WebSocketAccept(subprotocol=scope.subprotocols.get(0), headers=[
          ("x-inbound", count),
        ]),
        WebSocketSendText("frames=" + count),
      ]
    },
    subprotocols=["v2"],
    send=[Text("a"), Text("b")],
    disconnect=None,
  )
  assert_eq(session.accepted, true)
  assert_eq(session.subprotocol, Some("v2"))
  // 1 connect + 2 receive = 3 inbound frames (disconnect suppressed).
  assert_eq(session.header("x-inbound"), Some("3"))
  assert_eq(session.texts(), ["frames=3"])
}

///|
/// The `http.response.early_hint` extension round-trips: a streaming response
/// carrying early hints lowers them to `HttpResponseEarlyHint` events before the
/// start, and the client captures each `103` message's Link values.
test "early-hint extension round-trips through the TestClient" {
  let handler : StreamHandler = fn(_r) {
    StreamingResponse::new(chunks=[b"<html>"], early_hints=[
      ["</style.css>; rel=preload; as=style"],
      ["</app.js>; rel=preload; as=script"],
    ])
  }
  let client = TestClient::from_stream(handler)
  let r = client.get("/")
  assert_eq(r.body, b"<html>")
  assert_eq(r.early_hints.length(), 2)
  assert_eq(r.early_hints[0], ["</style.css>; rel=preload; as=style"])
  assert_eq(r.early_hints[1], ["</app.js>; rel=preload; as=script"])
}

///|
/// Per-subprotocol spec_version defaults: http and websocket scopes carry `2.5`,
/// a lifespan scope carries `2.0`, and each is reachable via the typed
/// constructors.
test "per-subprotocol asgi spec_version defaults" {
  assert_eq(AsgiVersion::http().spec_version, "2.5")
  assert_eq(AsgiVersion::websocket().spec_version, "2.5")
  assert_eq(AsgiVersion::lifespan().spec_version, "2.0")
  assert_eq(LifespanScope::new().asgi.spec_version, "2.0")
  assert_eq(
    HttpScope::new(http_method="GET", path="/").asgi.spec_version,
    "2.5",
  )
  assert_eq(WebSocketScope::new(path="/").asgi.spec_version, "2.5")
}
