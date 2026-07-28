///|
/// A server-side push promise captured by the `TestClient`: the pushed `path`
/// and the request headers the server would send for it (`http.response.push`).
pub(all) struct PushPromise {
  path : String
  headers : Array[(String, String)]
} derive(Eq)

///|
/// First push-request header matching `name`.
pub fn PushPromise::header(self : PushPromise, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The materialised result of driving an application in-process: the response
/// status and headers, the body reassembled from every `HttpResponseBody`
/// chunk, the trailing headers gathered from `HttpResponseTrailers`, any push
/// promises, and the `pathsend` path if the app used the path-send extension.
/// The captured, sans-transport analog of what a real client would observe.
pub(all) struct TestResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  trailers : Array[(String, String)]
  pushes : Array[PushPromise]
  pathsend : String?
} derive(Eq)

///|
/// First response header matching `name` (ASGI lowercased-name convention).
pub fn TestResponse::header(self : TestResponse, name : String) -> String? {
  for pair in self.headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// First trailing header matching `name`.
pub fn TestResponse::trailer(self : TestResponse, name : String) -> String? {
  for pair in self.trailers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The response body decoded as UTF-8 (lossy: invalid sequences become the
/// replacement character), for asserting on text responses.
pub fn TestResponse::text(self : TestResponse) -> String {
  @utf8.decode_lossy(self.body[:])
}

///|
/// The response body parsed as JSON. Raises `@json.ParseError` if the body is
/// not valid JSON, mirroring a real client's `.json()`.
pub fn TestResponse::json(self : TestResponse) -> Json raise {
  @json.parse(@utf8.decode_lossy(self.body[:]))
}

///|
/// Fold an outbound event stream into a `TestResponse`: `HttpResponseStart`
/// sets status/headers, every `HttpResponseBody` appends to the body, every
/// `HttpResponseTrailers` appends to the trailers, each `HttpResponsePush`
/// records a promise, and `HttpResponsePathSend` records the served path. Other
/// events (websocket, lifespan) are ignored — the http response is what a client
/// observes.
fn reassemble(events : Array[Event]) -> TestResponse {
  let mut status = 0
  let mut headers : Array[(String, String)] = []
  let buf = Buffer()
  let trailers : Array[(String, String)] = []
  let pushes : Array[PushPromise] = []
  let mut pathsend : String? = None
  for ev in events {
    match ev {
      HttpResponseStart(status=s, headers=h, trailers=_) => {
        status = s
        headers = h
      }
      HttpResponseBody(body=b, more_body=_) => buf.write_bytes(b[:])
      HttpResponseTrailers(headers=h, more_trailers=_) =>
        for pair in h {
          trailers.push(pair)
        }
      HttpResponsePush(path=p, headers=h) =>
        pushes.push({ path: p, headers: h })
      HttpResponsePathSend(path=p) => pathsend = Some(p)
      _ => ()
    }
  }
  { status, headers, body: buf.to_bytes(), trailers, pushes, pathsend }
}

///|
/// An in-process application driver — the ASGI `TestClient` — built on the
/// synchronous `run_http_app` core, so it needs no socket and runs on every
/// backend. It builds a synthetic http scope, feeds the request body in as
/// `HttpRequest` events, runs the application, and reassembles the outbound
/// stream into a `TestResponse`. `app` is the event-emitting application; the
/// `new` / `from_stream` constructors adapt a `Handler` / `StreamHandler`.
pub(all) struct TestClient {
  app : (Request) -> Array[Event]
  root_path : String
  base_headers : Array[(String, String)]
  client : (String, Int)?
  server : (String, Int)?
  extensions : Extensions
}

///|
/// Build a `TestClient` from a raw event-emitting application (the shape
/// `run_http_app` drives). Defaults mirror a typical test harness: empty
/// `root_path`, no base headers, a `("testclient", 50000)` client peer, a
/// `("testserver", 80)` server, and no advertised extensions.
pub fn TestClient::from_app(
  app : (Request) -> Array[Event],
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int)? = Some(("testserver", 80)),
  extensions? : Extensions = Extensions::none(),
) -> TestClient {
  { app, root_path, base_headers, client, server, extensions }
}

///|
/// Build a `TestClient` from a unary `Handler`.
pub fn TestClient::new(
  handler : Handler,
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int)? = Some(("testserver", 80)),
  extensions? : Extensions = Extensions::none(),
) -> TestClient {
  TestClient::from_app(
    fn(req) { handler(req).events() },
    root_path~,
    base_headers~,
    client~,
    server~,
    extensions~,
  )
}

///|
/// Build a `TestClient` from a streaming `StreamHandler` (multi-chunk body,
/// optional trailers).
pub fn TestClient::from_stream(
  handler : StreamHandler,
  root_path? : String = "",
  base_headers? : Array[(String, String)] = [],
  client? : (String, Int)? = Some(("testclient", 50000)),
  server? : (String, Int)? = Some(("testserver", 80)),
  extensions? : Extensions = Extensions::none(),
) -> TestClient {
  TestClient::from_app(
    fn(req) { handler(req).events() },
    root_path~,
    base_headers~,
    client~,
    server~,
    extensions~,
  )
}

///|
/// Split a request target into its path and raw query string on the first `?`;
/// `"/a/b?x=1&y=2"` → `("/a/b", "x=1&y=2")`, `"/a/b"` → `("/a/b", "")`.
fn split_target(target : String) -> (String, String) {
  for i in 0..<target.length() {
    if target[i].to_int() == 63 {
      return (target[0:i].to_owned(), target[i + 1:].to_owned())
    }
  }
  (target, "")
}

///|
/// Materialise a request body into inbound `HttpRequest` events. When `chunks`
/// is given each element becomes its own event (`more_body: true` on all but the
/// last), exercising a streamed request; otherwise `body` is a single event.
fn body_events(body : Bytes, chunks : Array[Bytes]?) -> Array[Event] {
  match chunks {
    Some(cs) =>
      if cs.length() == 0 {
        [HttpRequest(body=b"", more_body=false)]
      } else {
        let out : Array[Event] = []
        for i = 0; i < cs.length(); i = i + 1 {
          out.push(HttpRequest(body=cs[i], more_body=i != cs.length() - 1))
        }
        out
      }
    None => [HttpRequest(body~, more_body=false)]
  }
}

///|
/// Drive one request through the application and capture the response. Splits
/// `path` into path + query string, merges the client's `base_headers` before
/// the per-request `headers`, builds an http scope (carrying the client's
/// `root_path` / peers / advertised `extensions`), feeds the body in, runs the
/// app, and reassembles the outbound stream. Pass `chunks` to stream the request
/// body as several `HttpRequest` events.
pub fn TestClient::request(
  self : TestClient,
  http_method~ : String,
  path~ : String,
  headers? : Array[(String, String)] = [],
  body? : Bytes = b"",
  chunks? : Array[Bytes],
) -> TestResponse {
  let (p, q) = split_target(path)
  let scope = HttpScope::new(
    http_method~,
    path=p,
    query_string=@utf8.encode(q),
    root_path=self.root_path,
    headers=[..self.base_headers, ..headers],
    client=self.client,
    server=self.server,
    extensions=self.extensions,
  )
  reassemble(run_http_app(self.app, Http(scope), body_events(body, chunks)))
}

///|
/// `GET path`.
pub fn TestClient::get(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="GET", path~, headers~)
}

///|
/// `HEAD path`.
pub fn TestClient::head(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="HEAD", path~, headers~)
}

///|
/// `DELETE path`.
pub fn TestClient::delete(
  self : TestClient,
  path : String,
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="DELETE", path~, headers~)
}

///|
/// `POST path` with `body`.
pub fn TestClient::post(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="POST", path~, headers~, body~)
}

///|
/// `PUT path` with `body`.
pub fn TestClient::put(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="PUT", path~, headers~, body~)
}

///|
/// `PATCH path` with `body`.
pub fn TestClient::patch(
  self : TestClient,
  path : String,
  body? : Bytes = b"",
  headers? : Array[(String, String)] = [],
) -> TestResponse {
  self.request(http_method="PATCH", path~, headers~, body~)
}
