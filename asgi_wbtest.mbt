///|
test "request header lookup" {
  let req : Request = {
    http_method: "GET",
    path: "/hello",
    query_string: b"name=leo",
    headers: [("host", "localhost"), ("accept", "text/plain")],
    body: b"",
  }
  assert_eq(req.header("host"), Some("localhost"))
  assert_eq(req.header("accept"), Some("text/plain"))
  assert_eq(req.header("missing"), None)
}

///|
test "response builder and header" {
  let resp = Response::new(200, [("content-type", "text/plain")], b"hi")
  assert_eq(resp.status, 200)
  assert_eq(resp.body.length(), 2)
  assert_eq(resp.header("content-type"), Some("text/plain"))
}

///|
test "middleware composition is outermost-first" {
  let base : Handler = fn(_req) {
    Response::new(200, [("x-order", "base")], b"")
  }
  let tag = fn(label : String) -> Middleware {
    fn(next) {
      fn(req) {
        let r = next(req)
        Response::new(r.status, [("x-order", label), ..r.headers], r.body)
      }
    }
  }
  let h = compose([tag("outer"), tag("inner")], base)
  let req : Request = {
    http_method: "GET",
    path: "/",
    query_string: b"",
    headers: [],
    body: b"",
  }
  let resp = h(req)
  assert_eq(resp.header("x-order"), Some("outer"))
}

///|
test "SEAM scope and event variants construct" {
  let hs : HttpScope = {
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
    raw_path: b"/",
    query_string: b"",
    root_path: "",
    headers: [],
    client: Some(("127.0.0.1", 51000)),
    server: Some(("127.0.0.1", 8000)),
    state: Map([]),
  }
  let ws : WebSocketScope = {
    http_version: "1.1",
    scheme: "ws",
    path: "/ws",
    raw_path: b"/ws",
    query_string: b"",
    root_path: "",
    headers: [],
    client: None,
    server: None,
    subprotocols: ["chat"],
    state: Map([]),
  }
  let scopes : Array[Scope] = [
    Scope::Http(hs),
    Scope::WebSocket(ws),
    Scope::Lifespan({ state: Map([]) }),
  ]
  assert_eq(scopes.length(), 3)
  let events : Array[Event] = [
    Event::HttpRequest(body=b"", more_body=false),
    Event::HttpDisconnect,
    Event::HttpResponseStart(status=200, headers=[]),
    Event::HttpResponseBody(body=b"ok", more_body=false),
    Event::WebSocketConnect,
    Event::WebSocketReceive(text=Some("hi"), bytes=None),
    Event::WebSocketDisconnect(code=1000),
    Event::WebSocketAccept(subprotocol=None, headers=[]),
    Event::WebSocketSendText("hi"),
    Event::WebSocketSendBytes(b"hi"),
    Event::WebSocketClose(code=1000, reason=""),
    Event::LifespanStartup,
    Event::LifespanShutdown,
    Event::LifespanStartupComplete,
    Event::LifespanStartupFailed(message="boom"),
    Event::LifespanShutdownComplete,
    Event::LifespanShutdownFailed(message="boom"),
  ]
  assert_eq(events.length(), 17)
  assert_eq(Event::HttpDisconnect == Event::HttpDisconnect, true)
  assert_eq(events[0] == Event::HttpRequest(body=b"", more_body=false), true)
}
