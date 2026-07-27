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
/// HTTP connection scope (ASGI `type == "http"`). `raw_path` / `query_string`
/// stay `Bytes` because they are not guaranteed valid UTF-8; header names follow
/// ASGI's lowercased-latin1 convention. `state` is per-connection scratch copied
/// from the lifespan state.
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
  state : Map[String, Json]
}

///|
/// WebSocket connection scope (ASGI `type == "websocket"`). `scheme` is
/// `"ws"`/`"wss"`; `subprotocols` are the client-offered values.
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
  state : Map[String, Json]
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
/// lifespan message sets in both directions.
pub(all) enum Event {
  HttpRequest(body~ : Bytes, more_body~ : Bool)
  HttpDisconnect
  HttpResponseStart(status~ : Int, headers~ : Array[(String, String)])
  HttpResponseBody(body~ : Bytes, more_body~ : Bool)
  WebSocketConnect
  WebSocketReceive(text~ : String?, bytes~ : Bytes?)
  WebSocketDisconnect(code~ : Int)
  WebSocketAccept(subprotocol~ : String?, headers~ : Array[(String, String)])
  WebSocketSendText(String)
  WebSocketSendBytes(Bytes)
  WebSocketClose(code~ : Int, reason~ : String)
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
