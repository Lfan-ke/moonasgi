///|
/// Why an outbound event stream is malformed. ASGI pins the order an application
/// may emit messages in — a body before the response starts, a second start, a
/// websocket frame before the handshake is accepted, and so on are all protocol
/// violations. `validate_events` walks a stream and names the first violation it
/// finds; a well-formed stream returns `None`. A server can run this over its own
/// emissions to catch a buggy app early, and the conformance harness drives a
/// negative table through it.
pub(all) enum EventOrderError {
  // HTTP response ordering.
  BodyBeforeStart
  DuplicateResponseStart
  EarlyHintAfterStart
  BodyAfterComplete
  UnexpectedTrailers
  TrailersBeforeBody
  MissingResponseStart
  IncompleteBody
  MissingTrailers
  EventAfterComplete
  // WebSocket ordering.
  FrameBeforeAccept
  DuplicateAccept
  EventAfterClose
  DenialBodyBeforeStart
  DenialAfterAccept
  AcceptAfterDenial
  IncompleteDenial
  MissingHandshakeReply
  // Lifespan ordering.
  DuplicateLifespanReply
  ShutdownBeforeStartup
  // An event from the wrong message set for this scope (e.g. a websocket frame
  // in an http response stream).
  NonResponseEvent
} derive(Eq)

///|
/// A one-line human description of the violation, used in conformance failure
/// names and server logs.
pub fn EventOrderError::describe(self : EventOrderError) -> String {
  match self {
    BodyBeforeStart => "response body before http.response.start"
    DuplicateResponseStart => "a second http.response.start"
    EarlyHintAfterStart => "http.response.early_hint after the response started"
    BodyAfterComplete => "a body message after the response was complete"
    UnexpectedTrailers =>
      "http.response.trailers when start did not promise them"
    TrailersBeforeBody => "http.response.trailers before the body was complete"
    MissingResponseStart => "stream ended with no http.response.start"
    IncompleteBody => "stream ended before a final body (more_body was true)"
    MissingTrailers => "start promised trailers but none were sent"
    EventAfterComplete => "an event after the response was fully sent"
    FrameBeforeAccept => "a websocket frame before websocket.accept"
    DuplicateAccept => "a second websocket.accept"
    EventAfterClose => "an event after the websocket was closed"
    DenialBodyBeforeStart => "websocket.http.response.body before its start"
    DenialAfterAccept =>
      "websocket.http.response after the handshake was accepted"
    AcceptAfterDenial => "websocket.accept after a denial response started"
    IncompleteDenial => "a denial response with no final body"
    MissingHandshakeReply =>
      "the connect was never answered (accept/close/deny)"
    DuplicateLifespanReply => "a second reply to the same lifespan phase"
    ShutdownBeforeStartup => "a shutdown reply before the startup reply"
    NonResponseEvent => "an event from the wrong message set for this scope"
  }
}

///|
/// Validate the outbound event stream an application emits for an http request,
/// against ASGI's http response ordering: at most one `HttpResponseStart`, no
/// body or pathsend/zerocopysend before it, early hints only ahead of it, a body
/// stream that terminates once (`more_body: false`), trailers only when the start
/// promised them and only after the body completes, and nothing after the
/// response is fully sent. `HttpResponseDebug` carries no protocol meaning and is
/// accepted anywhere; `HttpResponsePush` is accepted before or during the
/// response. Returns the first violation, or `None` for a well-formed complete
/// response.
pub fn validate_http_response(events : Array[Event]) -> EventOrderError? {
  let mut started = false
  let mut complete = false
  let mut trailers_promised = false
  let mut trailers_done = false
  for ev in events {
    let finished = complete && (!trailers_promised || trailers_done)
    match ev {
      HttpResponseDebug(..) => ()
      HttpResponseEarlyHint(..) =>
        if started {
          return Some(EarlyHintAfterStart)
        }
      HttpResponseStart(trailers~, ..) => {
        if started {
          return Some(DuplicateResponseStart)
        }
        started = true
        trailers_promised = trailers
      }
      HttpResponseBody(more_body~, ..) => {
        if !started {
          return Some(BodyBeforeStart)
        }
        if complete {
          return Some(BodyAfterComplete)
        }
        if !more_body {
          complete = true
        }
      }
      HttpResponseZeroCopySend(more_body~, ..) => {
        if !started {
          return Some(BodyBeforeStart)
        }
        if complete {
          return Some(BodyAfterComplete)
        }
        if !more_body {
          complete = true
        }
      }
      HttpResponsePathSend(..) => {
        if !started {
          return Some(BodyBeforeStart)
        }
        if complete {
          return Some(BodyAfterComplete)
        }
        complete = true
      }
      HttpResponsePush(..) => if finished { return Some(EventAfterComplete) }
      HttpResponseTrailers(more_trailers~, ..) => {
        if !trailers_promised {
          return Some(UnexpectedTrailers)
        }
        if !complete {
          return Some(TrailersBeforeBody)
        }
        if trailers_done {
          return Some(EventAfterComplete)
        }
        if !more_trailers {
          trailers_done = true
        }
      }
      _ => return Some(NonResponseEvent)
    }
  }
  if !started {
    return Some(MissingResponseStart)
  }
  if !complete {
    return Some(IncompleteBody)
  }
  if trailers_promised && !trailers_done {
    return Some(MissingTrailers)
  }
  None
}

///|
/// Validate the outbound event stream an application emits for a websocket
/// connection, against ASGI's handshake ordering: the connect must be answered
/// with an `WebSocketAccept`, a `WebSocketClose`, or a denial
/// (`WebSocketHttpResponseStart` + body); frames are only legal once accepted;
/// nothing follows a close or a completed denial; a denial cannot mix with an
/// accept. Returns the first violation, or `None` for a well-formed stream.
pub fn validate_ws_response(events : Array[Event]) -> EventOrderError? {
  let mut accepted = false
  let mut closed = false
  let mut denial_started = false
  let mut denial_complete = false
  for ev in events {
    if closed || denial_complete {
      return Some(EventAfterClose)
    }
    match ev {
      WebSocketAccept(..) => {
        if accepted {
          return Some(DuplicateAccept)
        }
        if denial_started {
          return Some(AcceptAfterDenial)
        }
        accepted = true
      }
      WebSocketSendText(_) | WebSocketSendBytes(_) =>
        if !accepted {
          return Some(FrameBeforeAccept)
        }
      WebSocketClose(..) => closed = true
      WebSocketHttpResponseStart(..) => {
        if accepted {
          return Some(DenialAfterAccept)
        }
        if denial_started {
          return Some(DuplicateResponseStart)
        }
        denial_started = true
      }
      WebSocketHttpResponseBody(more_body~, ..) => {
        if !denial_started {
          return Some(DenialBodyBeforeStart)
        }
        if !more_body {
          denial_complete = true
        }
      }
      _ => return Some(NonResponseEvent)
    }
  }
  if denial_started && !denial_complete {
    return Some(IncompleteDenial)
  }
  if not_answered(accepted, closed, denial_started) {
    return Some(MissingHandshakeReply)
  }
  None
}

///|
/// Whether a websocket connect went unanswered — no accept, no close, no denial.
fn not_answered(accepted : Bool, closed : Bool, denial_started : Bool) -> Bool {
  !accepted && !closed && !denial_started
}

///|
/// Validate the outbound replies an application emits for a lifespan run: a
/// startup reply (`LifespanStartupComplete` / `LifespanStartupFailed`) before a
/// shutdown reply (`LifespanShutdownComplete` / `LifespanShutdownFailed`), each
/// phase answered at most once. Returns the first violation, or `None`.
pub fn validate_lifespan_replies(events : Array[Event]) -> EventOrderError? {
  let mut startup_replied = false
  let mut shutdown_replied = false
  for ev in events {
    match ev {
      LifespanStartupComplete | LifespanStartupFailed(..) => {
        if startup_replied {
          return Some(DuplicateLifespanReply)
        }
        startup_replied = true
      }
      LifespanShutdownComplete | LifespanShutdownFailed(..) => {
        if !startup_replied {
          return Some(ShutdownBeforeStartup)
        }
        if shutdown_replied {
          return Some(DuplicateLifespanReply)
        }
        shutdown_replied = true
      }
      _ => return Some(NonResponseEvent)
    }
  }
  None
}

///|
/// Validate an outbound event stream against the ordering rules for its scope,
/// dispatching to the http / websocket / lifespan validator. The public entry a
/// server calls to check an application's emissions before writing them to the
/// wire.
pub fn validate_events(
  scope : Scope,
  events : Array[Event],
) -> EventOrderError? {
  match scope {
    Http(_) => validate_http_response(events)
    WebSocket(_) => validate_ws_response(events)
    Lifespan(_) => validate_lifespan_replies(events)
  }
}
