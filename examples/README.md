# Examples

A guided tour of the public `@moonasgi` seam. Each folder is a runnable `main`
package that uses the library's real API - read it, then run it.

```bash
moon run examples/00-hello
```

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | A `Handler` returns `200 hello`; the in-process `TestClient` drives it, then the same handler is dropped onto the raw `Scope`/`Event` seam and lifted onto the async `AsgiApp`. | `Handler`, `Response::text`/`Response::new`, `TestClient::new`/`get`/`post`, `Scope::Http`, `HttpScope::new`, `Event`, `run_http`, `to_asgi`/`AsgiApp` |

The `TestClient` needs no socket and runs on every backend, so the same example
checks and runs under `moon check --target all` unchanged - the seam is
transport-agnostic by construction.
