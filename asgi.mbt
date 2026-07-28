///|
/// The connection scope: one value per HTTP request, WebSocket connection, or
/// lifespan run. It carries the immutable connection metadata a server hands to
/// an application, mirroring ASGI 3.0's `scope` dict as a typed sum.
pub(all) enum Scope {
  Http(HttpScope)
  WebSocket(WebSocketScope)
  Lifespan(LifespanScope)
}

///|
/// The `asgi` sub-dict every scope carries: the ASGI protocol `version`
/// (`"3.0"`) and the `spec_version` of the concrete http / websocket / lifespan
/// sub-spec the server implements. Applications negotiate optional behaviour
/// against `spec_version` with `at_least`.
pub(all) struct AsgiVersion {
  version : String
  spec_version : String
} derive(Eq)

///|
/// The default ASGI handshake: protocol `3.0`, sub-spec `2.4` (the current
/// HTTP / WebSocket spec revision).
pub fn AsgiVersion::default() -> AsgiVersion {
  { version: "3.0", spec_version: "2.4" }
}

///|
/// Strict `spec_version` negotiation: is this scope's sub-spec at least
/// `major.minor`? Parses the dotted `spec_version` (non-digit runs count as 0)
/// and compares numerically, so `"2.4".at_least(major=2, minor=3)` is true.
/// An application guards a version-gated feature with this instead of string
/// equality.
pub fn AsgiVersion::at_least(
  self : AsgiVersion,
  major~ : Int,
  minor~ : Int,
) -> Bool {
  let mut maj = 0
  let mut min = 0
  let mut after_dot = false
  for i in 0..<self.spec_version.length() {
    let c = self.spec_version[i].to_int()
    if c == 46 {
      after_dot = true
    } else if c >= 48 && c <= 57 {
      if after_dot {
        min = min * 10 + (c - 48)
      } else {
        maj = maj * 10 + (c - 48)
      }
    }
  }
  maj > major || (maj == major && min >= minor)
}

///|
/// The `tls` extension's per-connection data (ASGI TLS extension). Present in a
/// scope's `extensions` only when the connection is TLS-terminated by the
/// server. Certificates are PEM text; `tls_version` / `cipher_suite` are the
/// numeric IANA identifiers, `None` when the server does not expose them.
pub(all) struct TlsExtension {
  server_cert : String?
  client_cert_chain : Array[String]
  client_cert_name : String?
  client_cert_error : String?
  tls_version : Int?
  cipher_suite : Int?
} derive(Eq)

///|
/// The scope's `extensions` map, modelled as typed capability flags plus the
/// one extension that carries data (`tls`). A server sets a flag to advertise
/// that it will honour the matching outbound event — an application checks the
/// flag before emitting `HttpResponsePush` / `HttpResponsePathSend` /
/// `HttpResponseTrailers` / `WebSocketHttpResponseStart`, exactly as an ASGI
/// app tests `"http.response.push" in scope["extensions"]`.
pub(all) struct Extensions {
  tls : TlsExtension?
  http_response_push : Bool
  http_response_trailers : Bool
  http_response_pathsend : Bool
  websocket_http_response : Bool
} derive(Eq)

///|
/// No extensions advertised: every capability off, no TLS data. The starting
/// point servers and tests build from with the `enable_*` / `with_tls` helpers.
pub fn Extensions::none() -> Extensions {
  {
    tls: None,
    http_response_push: false,
    http_response_trailers: false,
    http_response_pathsend: false,
    websocket_http_response: false,
  }
}

///|
/// Advertise the server-push extension (`http.response.push`).
pub fn Extensions::enable_push(self : Extensions) -> Extensions {
  { ..self, http_response_push: true }
}

///|
/// Advertise the response-trailers extension (`http.response.trailers`).
pub fn Extensions::enable_trailers(self : Extensions) -> Extensions {
  { ..self, http_response_trailers: true }
}

///|
/// Advertise the path-send extension (`http.response.pathsend`).
pub fn Extensions::enable_pathsend(self : Extensions) -> Extensions {
  { ..self, http_response_pathsend: true }
}

///|
/// Advertise the WebSocket-denial-with-response extension
/// (`websocket.http.response`).
pub fn Extensions::enable_websocket_http_response(
  self : Extensions,
) -> Extensions {
  { ..self, websocket_http_response: true }
}

///|
/// Attach `tls` extension data to a connection scope.
pub fn Extensions::with_tls(
  self : Extensions,
  tls : TlsExtension,
) -> Extensions {
  { ..self, tls: Some(tls) }
}

///|
/// HTTP connection scope (ASGI `type == "http"`). `raw_path` / `query_string`
/// stay `Bytes` because they are not guaranteed valid UTF-8; header names follow
/// ASGI's lowercased-latin1 convention. `asgi` carries the version handshake,
/// `extensions` the advertised server capabilities, and `state` is
/// per-connection scratch copied from the lifespan state.
pub(all) struct HttpScope {
  http_version : String
  http_method : String
  scheme : String
  path : String
  raw_path : Bytes
  query_string : Bytes
  root_path : String
  headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int)?
  asgi : AsgiVersion
  extensions : Extensions
  state : Map[String, Json]
}

///|
/// Build an `HttpScope` with ASGI's usual defaults filled in — `http_version`
/// `"1.1"`, `scheme` `"http"`, empty query/headers/state, the default `asgi`
/// handshake, and no extensions. `raw_path` defaults to the UTF-8 encoding of
/// `path`. The ergonomic constructor servers and the `TestClient` build scopes
/// through, so callers spell only what differs from the common case.
pub fn HttpScope::new(
  http_method~ : String,
  path~ : String,
  http_version? : String = "1.1",
  scheme? : String = "http",
  raw_path? : Bytes,
  query_string? : Bytes = b"",
  root_path? : String = "",
  headers? : Array[(String, String)] = [],
  client? : (String, Int)? = None,
  server? : (String, Int)? = None,
  asgi? : AsgiVersion = AsgiVersion::default(),
  extensions? : Extensions = Extensions::none(),
  state? : Map[String, Json] = Map([]),
) -> HttpScope {
  {
    http_version,
    http_method,
    scheme,
    path,
    raw_path: raw_path.unwrap_or(@utf8.encode(path)),
    query_string,
    root_path,
    headers,
    client,
    server,
    asgi,
    extensions,
    state,
  }
}

///|
/// WebSocket connection scope (ASGI `type == "websocket"`). `scheme` is
/// `"ws"`/`"wss"`; `subprotocols` are the client-offered values. Carries the
/// same `asgi` handshake and `extensions` capabilities as an http scope.
pub(all) struct WebSocketScope {
  http_version : String
  scheme : String
  path : String
  raw_path : Bytes
  query_string : Bytes
  root_path : String
  headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int)?
  subprotocols : Array[String]
  asgi : AsgiVersion
  extensions : Extensions
  state : Map[String, Json]
}

///|
/// Build a `WebSocketScope` with ASGI's usual defaults filled in — `scheme`
/// `"ws"`, empty query/headers/subprotocols/state, the default `asgi`
/// handshake, and no extensions. `raw_path` defaults to the UTF-8 encoding of
/// `path`.
pub fn WebSocketScope::new(
  path~ : String,
  http_version? : String = "1.1",
  scheme? : String = "ws",
  raw_path? : Bytes,
  query_string? : Bytes = b"",
  root_path? : String = "",
  headers? : Array[(String, String)] = [],
  client? : (String, Int)? = None,
  server? : (String, Int)? = None,
  subprotocols? : Array[String] = [],
  asgi? : AsgiVersion = AsgiVersion::default(),
  extensions? : Extensions = Extensions::none(),
  state? : Map[String, Json] = Map([]),
) -> WebSocketScope {
  {
    http_version,
    scheme,
    path,
    raw_path: raw_path.unwrap_or(@utf8.encode(path)),
    query_string,
    root_path,
    headers,
    client,
    server,
    subprotocols,
    asgi,
    extensions,
    state,
  }
}

///|
/// Lifespan scope (ASGI `type == "lifespan"`): a single run spanning process
/// startup and shutdown, whose `state` seeds every request scope.
pub(all) struct LifespanScope {
  state : Map[String, Json]
}

///|
/// A protocol event flowing between server and application. Replaces ASGI's
/// stringly-typed message dicts with a typed sum covering the http / websocket /
/// lifespan message sets in both directions, including the standard extension
/// messages (server push, path-send, response trailers, and WebSocket denial
/// with a full HTTP response).
pub(all) enum Event {
  HttpRequest(body~ : Bytes, more_body~ : Bool)
  HttpDisconnect
  HttpResponseStart(
    status~ : Int,
    headers~ : Array[(String, String)],
    trailers~ : Bool
  )
  HttpResponseBody(body~ : Bytes, more_body~ : Bool)
  // `http.response.trailers` extension: trailing headers sent after the body,
  // only valid when `HttpResponseStart.trailers` was `true`.
  HttpResponseTrailers(
    headers~ : Array[(String, String)],
    more_trailers~ : Bool
  )
  // `http.response.push` extension: a server-initiated push promise for `path`.
  HttpResponsePush(path~ : String, headers~ : Array[(String, String)])
  // `http.response.pathsend` extension: hand a file `path` to the server to
  // serve zero-copy, emitted after `HttpResponseStart`.
  HttpResponsePathSend(path~ : String)
  WebSocketConnect
  WebSocketReceive(text~ : String?, bytes~ : Bytes?)
  WebSocketDisconnect(code~ : Int)
  WebSocketAccept(subprotocol~ : String?, headers~ : Array[(String, String)])
  WebSocketSendText(String)
  WebSocketSendBytes(Bytes)
  WebSocketClose(code~ : Int, reason~ : String)
  // `websocket.http.response` extension: deny the handshake with a real HTTP
  // response instead of a bare close (start + body, mirroring the http path).
  WebSocketHttpResponseStart(status~ : Int, headers~ : Array[(String, String)])
  WebSocketHttpResponseBody(body~ : Bytes, more_body~ : Bool)
  LifespanStartup
  LifespanShutdown
  LifespanStartupComplete
  LifespanStartupFailed(message~ : String)
  LifespanShutdownComplete
  LifespanShutdownFailed(message~ : String)
} derive(Eq)

///|
/// Pull the next inbound event. The async awaitable an application calls to read
/// request body chunks, websocket frames, or lifespan signals.
pub type Receive = async () -> Event

///|
/// Push an outbound event. The async awaitable an application calls to emit
/// response start/body, websocket frames, or lifespan completion.
pub type Send = async (Event) -> Unit

///|
/// The load-bearing ASGI callable: `(scope, receive, send)`. Every server binds
/// to this shape and every framework in the suite ultimately compiles down to it.
pub type AsgiApp = async (Scope, Receive, Send) -> Unit
