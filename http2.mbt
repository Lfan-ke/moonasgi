///|
/// Why a HEADERS frame does not map onto an `HttpScope` field-by-field: an
/// HTTP/2 (RFC 7540 §8.1.2.3) or HTTP/3 request carries its request line as four
/// *pseudo-headers* — `:method`, `:scheme`, `:authority`, `:path` — interleaved
/// with the ordinary fields, and ASGI reserves no slot for them in
/// `scope["headers"]`. A conforming server must consume the pseudo-headers into
/// the scope's typed fields and hand the application only the ordinary headers,
/// with `host` synthesised from `:authority`. `moonasgi` owns that lowering so
/// every h2/h2c/h3 transport in the suite (mooncat) produces the same scope from
/// the same frame, and an app never sees a `:`-prefixed header.
///
/// A malformed pseudo-header set — a missing required one, a duplicate, an
/// unknown `:foo`, or a pseudo-header after an ordinary field — is rejected with
/// the exact `Http2HeaderError`, matching RFC 7540's "malformed request"
/// treatment, so the transport can answer `RST_STREAM(PROTOCOL_ERROR)` instead
/// of forwarding a bad scope.
pub(all) enum Http2HeaderError {
  // No `:method` pseudo-header was present.
  MissingMethod
  // No `:scheme` pseudo-header was present.
  MissingScheme
  // No `:path` pseudo-header was present.
  MissingPath
  // `:path` was present but empty (a normal request must name a target; RFC
  // 7540 §8.1.2.3 allows an empty `:path` only for `OPTIONS *`, handled by the
  // transport, not lowered to an ASGI scope).
  EmptyPath
  // The named pseudo-header appeared more than once.
  DuplicatePseudoHeader(String)
  // A `:`-prefixed header that is not one of the four request pseudo-headers.
  UnknownPseudoHeader(String)
  // A pseudo-header followed an ordinary header — RFC 7540 requires all
  // pseudo-headers to precede the regular fields.
  PseudoHeaderAfterRegular(String)
} derive(Eq)

///|
/// Lower an HTTP/2 (or HTTP/3) request's HEADERS block — pseudo-headers and
/// ordinary fields in wire order — into an `HttpScope`, the way a conforming
/// ASGI server consumes a frame. `:method`, `:scheme` and `:path` become the
/// scope's `http_method` / `scheme` / `path` (with the query string split off
/// `:path`); the returned `headers` are the ordinary fields only, with `host`
/// synthesised at the front from `:authority` (replacing any `host` the peer
/// also sent, per RFC 7540 §8.1.2.3). `http_version` defaults to `"2"`; pass
/// `"3"` for an HTTP/3 transport, which shares this pseudo-header contract.
///
/// The remaining scope fields (`root_path`, `client`, `server`, `extensions`,
/// `asgi`, `state`) are supplied by the server exactly as for `HttpScope::new`.
/// Returns `Err` naming the first violation for a malformed pseudo-header set,
/// so the SEAM never hands a framework a scope with a `:`-prefixed header or a
/// missing request-line field.
pub fn HttpScope::from_h2_headers(
  headers : Array[(String, String)],
  http_version? : String = "2",
  root_path? : String = "",
  client? : (String, Int)? = None,
  server? : (String, Int?)? = None,
  extensions? : Extensions = Extensions::none(),
  asgi? : AsgiVersion = AsgiVersion::http(),
  state? : Map[String, Json] = Map([]),
) -> Result[HttpScope, Http2HeaderError] {
  let mut meth : String? = None
  let mut scheme : String? = None
  let mut authority : String? = None
  let mut target : String? = None
  let regular : Array[(String, String)] = []
  let mut seen_regular = false
  for pair in headers {
    let name = pair.0
    if name.length() > 0 && name[0].to_int() == 58 {
      if seen_regular {
        return Err(PseudoHeaderAfterRegular(name))
      }
      if name == ":method" {
        if meth is Some(_) {
          return Err(DuplicatePseudoHeader(name))
        }
        meth = Some(pair.1)
      } else if name == ":scheme" {
        if scheme is Some(_) {
          return Err(DuplicatePseudoHeader(name))
        }
        scheme = Some(pair.1)
      } else if name == ":authority" {
        if authority is Some(_) {
          return Err(DuplicatePseudoHeader(name))
        }
        authority = Some(pair.1)
      } else if name == ":path" {
        if target is Some(_) {
          return Err(DuplicatePseudoHeader(name))
        }
        target = Some(pair.1)
      } else {
        return Err(UnknownPseudoHeader(name))
      }
    } else {
      seen_regular = true
      regular.push(pair)
    }
  }
  let http_method = match meth {
    Some(m) => m
    None => return Err(MissingMethod)
  }
  let scheme = match scheme {
    Some(s) => s
    None => return Err(MissingScheme)
  }
  let raw_target = match target {
    Some(t) => t
    None => return Err(MissingPath)
  }
  if raw_target.length() == 0 {
    return Err(EmptyPath)
  }
  let out_headers : Array[(String, String)] = []
  match authority {
    Some(a) => {
      out_headers.push(("host", a))
      for pair in regular {
        if pair.0 != "host" {
          out_headers.push(pair)
        }
      }
    }
    None => out_headers.append(regular)
  }
  let (path, query) = split_target(raw_target)
  Ok(
    HttpScope::new(
      http_method~,
      path~,
      http_version~,
      scheme~,
      raw_path=@utf8.encode(path),
      query_string=@utf8.encode(query),
      root_path~,
      headers=out_headers,
      client~,
      server~,
      asgi~,
      extensions~,
      state~,
    ),
  )
}
