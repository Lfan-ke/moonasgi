///|
/// The ASGI 3.0 conformance harness runs clean: every Event variant and every
/// Scope field round-trips through run_http / ws_run / TestClient with no
/// failures. This is the DoD conformance gate — a red check names itself.
test "ASGI 3.0 conformance harness is all-green" {
  let report = run_conformance()
  // Surface any failing check by name before asserting.
  assert_eq(report.failures, [])
  assert_eq(report.ok(), true)
  assert_eq(report.passed, report.total)
  // The battery is substantial: 25 event self-checks + 300 pairwise-distinct
  // checks + the http/ws/scope/extension/streaming/version tables + the
  // positive/negative event-ordering tables.
  assert_eq(report.total > 350, true)
}
