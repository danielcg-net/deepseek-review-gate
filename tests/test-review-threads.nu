use std/assert
use std/testing *
use ../nu/review-threads.nu [parse-active-fingerprints, parse-graphql-response, parse-machine-findings, serialize-active-fingerprints]

const FINDING = {
  severity: 'warning'
  path: 'nu/review.nu'
  line: 254
  rule: 'machine-output-contract'
  message: 'Return structured findings before attempting thread reconciliation.'
}

@test
def 'machine findings：normalizes and fingerprints stable actionable findings' [] {
  let result = parse-machine-findings ({ findings: [$FINDING] } | to json)
  assert equal ($result | length) 1
  let finding = $result | first
  assert equal $finding.severity 'warning'
  assert equal $finding.path 'nu/review.nu'
  assert equal $finding.line 254
  assert ($finding.fingerprint =~ '^[a-f0-9]{64}$')
  let rerun = parse-machine-findings ({ findings: [$FINDING] } | to json) | first
  assert equal $finding.fingerprint $rerun.fingerprint
}

@test
def 'machine findings：rejects malformed and duplicate findings fail closed' [] {
  let malformed = try { parse-machine-findings '{"findings":[{"severity":"warning"}]}' ; false } catch { true }
  assert equal $malformed true
  let duplicate = try { parse-machine-findings ({ findings: [$FINDING, $FINDING] } | to json) ; false } catch { true }
  assert equal $duplicate true
}

@test
def 'machine findings：requires a fingerprint array for reconcile-only mode' [] {
  let fingerprint = (parse-machine-findings ({ findings: [$FINDING] } | to json) | first).fingerprint
  assert equal (parse-active-fingerprints ([$fingerprint] | to json)) [$fingerprint]
  let malformed = try { parse-active-fingerprints '["not-a-fingerprint"]'; false } catch { true }
  assert equal $malformed true
}

@test
def 'machine findings：serializes action output as compact JSON on one line' [] {
  let fingerprint = (parse-machine-findings ({ findings: [$FINDING] } | to json) | first).fingerprint
  let serialized = serialize-active-fingerprints [$fingerprint]
  assert equal $serialized $'["($fingerprint)"]'
  assert equal (parse-active-fingerprints $serialized) [$fingerprint]
  assert equal (serialize-active-fingerprints []) '[]'
}

@test
def 'GitHub GraphQL：normalizes full HTTP responses and fails closed without data' [] {
  assert equal (parse-graphql-response { status: 200, body: { data: { ok: true } } }) { ok: true }
  assert equal (parse-graphql-response { data: { ok: true } }) { ok: true }
  let missing_data = try { parse-graphql-response { status: 403, body: { message: 'Resource not accessible' } }; false } catch { true }
  assert equal $missing_data true
  let graphql_error = try { parse-graphql-response { status: 200, body: { errors: [{ message: 'forbidden' }] } }; false } catch { true }
  assert equal $graphql_error true
}
