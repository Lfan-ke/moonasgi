///|
/// An inbound HTTP request in ergonomic form: the request line, headers, and the
/// fully-read body. The sugar over `HttpScope` plus a drained `Receive`, so a
/// `Handler` never touches the async transport directly.
pub(all) struct Request {
  http_method : String
  path : String
  query_string : Bytes
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq)

///|
/// An outbound HTTP response: status, headers, and the full body. Mutable so
/// middleware can decorate it before the server serialises it into
/// `HttpResponseStart` + `HttpResponseBody`.
pub(all) struct Response {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq)

///|
/// The ergonomic request→response function most handlers are written as. The
/// synchronous sugar the suite lifts onto `AsgiApp` at the server boundary.
pub type Handler = (Request) -> Response

///|
/// A handler transformer that wraps a downstream `Handler` to add cross-cutting
/// behaviour. Composed as an onion where the first registered is outermost.
pub type Middleware = (Handler) -> Handler

///|
/// Build a response from raw bytes.
pub fn Response::new(
  status : Int,
  headers : Array[(String, String)],
  body : Bytes,
) -> Response {
  { status, headers, body }
}

///|
/// Look up the first header matching `name`, following ASGI's lowercased-name
/// convention.
pub fn Request::header(self : Request, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Look up the first response header matching `name`, same convention as
/// `Request::header`.
pub fn Response::header(self : Response, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Compose middlewares over a base handler. The first element is the outermost
/// wrapper, matching registration order.
pub fn compose(middlewares : Array[Middleware], base : Handler) -> Handler {
  let mut handler = base
  for i = middlewares.length() - 1; i >= 0; i = i - 1 {
    handler = middlewares[i](handler)
  }
  handler
}

///|
/// A `text/plain; charset=utf-8` response whose body is the UTF-8 encoding of
/// `body`. The ergonomic constructor for the common string reply.
pub fn Response::text(status? : Int = 200, body : String) -> Response {
  {
    status,
    headers: [("content-type", "text/plain; charset=utf-8")],
    body: @utf8.encode(body),
  }
}

///|
/// An `application/json` response whose body is the UTF-8 encoding of `value`
/// serialised with `Json::stringify`. The ergonomic constructor for a JSON reply.
pub fn Response::json(status? : Int = 200, value : Json) -> Response {
  {
    status,
    headers: [("content-type", "application/json")],
    body: @utf8.encode(value.stringify()),
  }
}

///|
/// Fold one inbound event into the body buffer, returning whether more chunks
/// should be pulled. `HttpRequest` appends its bytes and continues while
/// `more_body`; any other event (a disconnect, a stray frame) ends the drain.
/// Shared by the async `to_asgi` loop and the synchronous `run_http` driver so
/// both drain identically.
fn absorb(buf : Buffer, event : Event) -> Bool {
  match event {
    HttpRequest(body~, more_body~) => {
      buf.write_bytes(body[:])
      more_body
    }
    _ => false
  }
}

///|
/// Assemble the ergonomic `Request` from an http scope and its fully-drained
/// body.
fn build_request(scope : HttpScope, body : Bytes) -> Request {
  {
    http_method: scope.http_method,
    path: scope.path,
    query_string: scope.query_string,
    headers: scope.headers,
    body,
  }
}

///|
/// Serialise a `Response` into the outbound event pair a server sends: an
/// `HttpResponseStart` carrying status and headers, then a single
/// `HttpResponseBody` with the whole body and `more_body: false`.
fn response_events(resp : Response) -> Array[Event] {
  [
    HttpResponseStart(status=resp.status, headers=resp.headers),
    HttpResponseBody(body=resp.body, more_body=false),
  ]
}

///|
/// The synchronous counterpart of `to_asgi`: drive a `Handler` over an already
/// materialised inbound event sequence and return the outbound events a server
/// would send. Drains the http body from `inbound` (accumulating `HttpRequest`
/// chunks until `more_body` is false), runs the handler, and yields
/// `[HttpResponseStart, HttpResponseBody]`. Non-http scopes yield `[]`, matching
/// `to_asgi`'s no-op. This is the sans-transport core — usable as an in-memory
/// test driver — that `to_asgi` wraps with async `receive`/`send`.
pub fn run_http(
  handler : Handler,
  scope : Scope,
  inbound : Array[Event],
) -> Array[Event] {
  match scope {
    Http(hs) => {
      let buf = Buffer()
      for event in inbound {
        if !absorb(buf, event) {
          break
        }
      }
      response_events(handler(build_request(hs, buf.to_bytes())))
    }
    _ => []
  }
}

///|
/// Lift a synchronous `Handler` onto the load-bearing `AsgiApp` the server binds
/// to. For an http scope it drains the request body — looping `receive()` and
/// accumulating `HttpRequest` chunks until `more_body` is false — assembles a
/// `Request`, runs the handler, then emits `HttpResponseStart` followed by a
/// single `HttpResponseBody`. Non-http scopes (websocket, lifespan) are no-ops:
/// this sugar covers request→response handlers only. Shares its drain, request
/// assembly, and response serialisation with `run_http`, which tests the same
/// logic without the async transport.
pub fn to_asgi(handler : Handler) -> AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => {
        let buf = Buffer()
        while absorb(buf, receive()) {

        }
        let resp = handler(build_request(hs, buf.to_bytes()))
        for event in response_events(resp) {
          send(event)
        }
      }
      _ => ()
    }
  }
}
