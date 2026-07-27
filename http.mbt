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
