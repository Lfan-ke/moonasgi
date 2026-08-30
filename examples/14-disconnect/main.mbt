// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Whatever this application raises to decline a scope. ASGI names no error for
/// "I do not support lifespan" - the mechanism is the act of raising - so an app
/// brings its own.
priv suberror NoLifespan

///|
/// The two things a server and an application tell each other out of band. A peer
/// that has gone away is an error on the send side - `ClientDisconnected`, which
/// the www sub-spec has required `send()` to raise since spec_version 2.4 - and an
/// application declines a scope it does not implement by raising out of the
/// callable, which is how ASGI has it say "I do not support lifespan".
/// `run_sync_app` is the sans-transport mirror of the split a server makes between
/// the two; the async `Send` / `AsgiApp` pair carries the same contract under
/// mooncat.
///
///     moon run examples/14-disconnect
#coverage.skip
fn main {
  let written : Array[@moonasgi.Event] = []
  // A peer that hangs up once the response line is out.
  let gone : @moonasgi.Sink = ev => {
    written.push(ev)
    if written.length() == 1 {
      raise @moonasgi.ClientDisconnected
    }
  }
  let app : @moonasgi.SyncApp = (_scope, _inbound, send) => {
    send(@moonasgi.HttpResponseStart(status=200, headers=[], trailers=false))
    send(@moonasgi.HttpResponseBody(body=b"never arrives", more_body=false))
  }
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/slow"),
  )
  let outcome = try {
    let _ = @moonasgi.run_sync_app(app, scope, [], gone)
    "the app ran to the end"
  } catch {
    @moonasgi.ClientDisconnected =>
      "client gone after \{written.length()} event(s); the rest was never offered"
  }
  println(outcome)

  // The same app against a peer that is still there.
  let delivered : Array[@moonasgi.Event] = []
  let alive : @moonasgi.Sink = ev => delivered.push(ev)
  let _ = @moonasgi.run_sync_app(app, scope, [], alive) catch {
    @moonasgi.ClientDisconnected => false
  }
  println("still connected -> \{delivered.length()} events written")

  // Declining a scope. The one that raises does not support lifespan; the one that
  // replies does, and run_sync_app is where a server tells them apart.
  let boot = @moonasgi.Scope::Lifespan(@moonasgi.LifespanScope::new())
  let replies : Array[@moonasgi.Event] = []
  let sink : @moonasgi.Sink = ev => replies.push(ev)
  let with_lifespan : @moonasgi.SyncApp = (_sc, _inb, send) => {
    send(@moonasgi.LifespanStartupComplete)
  }
  let without_lifespan : @moonasgi.SyncApp = (_sc, _inb, _send) => {
    raise NoLifespan
  }
  let inbound = [@moonasgi.LifespanStartup]
  let handled = @moonasgi.run_sync_app(with_lifespan, boot, inbound, sink) catch {
    @moonasgi.ClientDisconnected => false
  }
  println(
    "app with lifespan handled the scope: \{handled} (\{replies.length()} reply)",
  )
  let declined = @moonasgi.run_sync_app(without_lifespan, boot, inbound, sink) catch {
    @moonasgi.ClientDisconnected => true
  }
  println("app without lifespan handled the scope: \{declined}")

  // raw_path is optional the same way: the seam does not claim bytes the server
  // never kept.
  let plain = @moonasgi.HttpScope::new(http_method="GET", path="/files/a/b")
  let kept = @moonasgi.HttpScope::new(
    http_method="GET",
    path="/files/a/b",
    raw_path=b"/files/a%2Fb",
  )
  println(
    "raw_path absent: \{plain.raw_path is None}, kept: \{kept.raw_path is Some(_)}",
  )
}
