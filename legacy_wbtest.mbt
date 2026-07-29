///|
/// The legacy 2.0 double-callable convention must produce exactly what the same
/// handler produces single-callably: `run_legacy` (the sync core) equals `run_http`.
/// `double_to_single_callable` is the async lift of this same two-step shape.
test "run_legacy: the two-call convention matches a single-callable app" {
  let handler : Handler = fn(req) {
    Response::new(200, [("x-m", req.http_method)], req.body)
  }
  // A legacy app: the first callable takes the scope and returns an instance that
  // folds the inbound event stream — the 2.0 double-callable shape over the sync core.
  let legacy : (Scope) -> (Array[Event]) -> Array[Event] = fn(scope) {
    fn(inbound) { run_http(handler, scope, inbound) }
  }
  let scope = Scope::Http(HttpScope::new(http_method="POST", path="/x"))
  let inbound : Array[Event] = [HttpRequest(body=b"hi", more_body=false)]
  let out = run_legacy(legacy, scope, inbound)
  assert_eq(out == run_http(handler, scope, inbound), true)
  assert_eq(out.length(), 2)
  assert_eq(
    out[0] ==
    HttpResponseStart(status=200, headers=[("x-m", "POST")], trailers=false),
    true,
  )
  assert_eq(out[1] == HttpResponseBody(body=b"hi", more_body=false), true)
}

///|
/// The first (synchronous) callable is invoked with the connection scope — the step
/// that distinguishes the double-callable convention from the single one.
test "run_legacy hands the scope to the first callable" {
  let seen : Array[String] = []
  let legacy : (Scope) -> (Array[Event]) -> Array[Event] = fn(scope) {
    match scope {
      Http(hs) => seen.push(hs.path)
      _ => ()
    }
    fn(inbound) { run_http(fn(_req) { Response::text("ok") }, scope, inbound) }
  }
  let _ = run_legacy(
    legacy,
    Scope::Http(HttpScope::new(http_method="GET", path="/deep")),
    [HttpRequest(body=b"", more_body=false)],
  )
  assert_eq(seen, ["/deep"])
}

///|
/// The convention is protocol-agnostic: a legacy websocket app over `ws_run` yields
/// the same frames as driving the handler directly.
test "run_legacy carries a websocket app too" {
  let ws_handler = WebSocketHandler::echo()
  let legacy : (Scope) -> (Array[Event]) -> Array[Event] = fn(scope) {
    fn(inbound) { ws_run(ws_handler, scope, inbound) }
  }
  let scope = Scope::WebSocket(WebSocketScope::new(path="/ws"))
  let inbound : Array[Event] = [
    WebSocketConnect,
    WebSocketReceive(text=Some("hi"), bytes=None),
  ]
  let out = run_legacy(legacy, scope, inbound)
  assert_eq(out == ws_run(ws_handler, scope, inbound), true)
  assert_eq(out[0] == WebSocketAccept(subprotocol=None, headers=[]), true)
  assert_eq(out[1] == WebSocketSendText("hi"), true)
}

///|
/// The public async surface type-checks: both a single-callable app and a legacy
/// double-callable app normalize through `guarantee_single_callable` /
/// `double_to_single_callable` to an `AsgiApp` a server can drive. (The async result
/// runs under mooncat; here the constructors and the normaliser are exercised.)
test "the legacy compatibility wrappers normalize both conventions" {
  let single_app : AsgiApp = to_asgi(fn(_req) { Response::text("ok") })
  let legacy_app : LegacyAsgiApp = fn(_scope) {
    let inst : AsgiAppInstance = (_receive, send) => ignore(send)
    inst
  }
  // guarantee_single_callable accepts either variant and yields an AsgiApp; the
  // built values below would fail to type-check if the wiring were wrong.
  let normalized : Array[AsgiApp] = [
    guarantee_single_callable(Single(single_app)),
    guarantee_single_callable(Legacy(legacy_app)),
    double_to_single_callable(legacy_app),
  ]
  assert_eq(normalized.length(), 3)
}
