use std/assert
use std/testing *
use ../nu/review-threads.nu [annotate-review-threads, collect-review-threads, machine-reviewer-matches, parse-active-fingerprints, parse-graphql-response, parse-machine-findings, plan-thread-reconciliation, serialize-active-fingerprints]

const FINDING = {
  severity: 'warning'
  path: 'nu/review.nu'
  line: 254
  rule: 'machine-output-contract'
  message: 'Return structured findings before attempting thread reconciliation.'
}

def thread-fixture [id: int, --author: string = 'github-actions[bot]', --body: string = 'unmarked'] {
  { id: ($id | into string), isResolved: false, comments: { nodes: [{ author: { login: $author }, body: $body }] } }
}

@test
def 'pagination：collects zero and exactly 100 threads' [] {
  assert equal (collect-review-threads {|cursor|
    assert equal $cursor null
    { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } }
  }) []
  let threads = 1..100 | each {|id| thread-fixture $id }
  assert equal (collect-review-threads {|cursor|
    assert equal $cursor null
    { nodes: $threads, pageInfo: { hasNextPage: false, endCursor: 'last' } }
  }) $threads
}

@test
def 'pagination：collects 101 and multiple pages with exact cursors' [] {
  for total in [101, 205] {
    let threads = 1..$total | each {|id| thread-fixture $id }
    let collected = collect-review-threads {|cursor|
      let offset = if $cursor == null { 0 } else { $cursor | into int }
      assert ($offset in [0, 100, 200])
      { nodes: ($threads | skip $offset | take 100), pageInfo: {
        hasNextPage: (($offset + 100) < $total), endCursor: (($offset + 100) | into string)
      } }
    }
    assert equal $collected $threads
  }
}

@test
def 'pagination：fails closed on API errors after a valid first page' [] {
  let failed = try {
    collect-review-threads {|cursor|
      if $cursor != null { error make { msg: 'API unavailable' } }
      { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: true, endCursor: 'next' } }
    }
    false
  } catch {|err| $err.msg == 'API unavailable' }
  assert $failed
}

@test
def 'pagination：rejects malformed pages and missing cursors' [] {
  let invalid_pages = [
    {}
    { nodes: null, pageInfo: { hasNextPage: false } }
    { nodes: [], pageInfo: { hasNextPage: 'false' } }
    { nodes: [], pageInfo: { hasNextPage: true, endCursor: 'next' } }
    { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: true } }
    { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: true, endCursor: ' ' } }
    { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: true, endCursor: 1 } }
    { nodes: [{ id: '1' }], pageInfo: { hasNextPage: false } }
  ]
  for page in $invalid_pages {
    let failed = try { collect-review-threads {|_| $page }; false } catch { true }
    assert $failed
  }
}

@test
def 'pagination：rejects repeated cyclic cursors and duplicate threads' [] {
  for next_cursor in ['a', 'b'] {
    let failed = try {
      collect-review-threads {|cursor|
        match $cursor {
          null => { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: true, endCursor: 'a' } }
          'a' => { nodes: [(thread-fixture 2)], pageInfo: { hasNextPage: true, endCursor: $next_cursor } }
          _ => { nodes: [(thread-fixture 3)], pageInfo: { hasNextPage: true, endCursor: 'a' } }
        }
      }
      false
    } catch {|err| $err.msg == 'GitHub review-thread pagination did not advance.' }
    assert $failed
  }
  let duplicate = try {
    collect-review-threads {|cursor|
      { nodes: [(thread-fixture 1)], pageInfo: { hasNextPage: ($cursor == null), endCursor: 'next' } }
    }
    false
  } catch {|err| $err.msg == 'GitHub returned a duplicate review thread; retry reconciliation.' }
  assert $duplicate
}

@test
def 'pagination：preserves marker and reviewer ownership across pages' [] {
  let fingerprint = (parse-machine-findings ({ findings: [$FINDING] } | to json) | first).fingerprint
  let marker = $'<!-- deepseek-review-gate:fingerprint=($fingerprint) -->'
  let threads = collect-review-threads {|cursor|
    if $cursor == null {
      { nodes: (1..100 | each {|id| thread-fixture $id --author 'human' --body $marker }), pageInfo: { hasNextPage: true, endCursor: 'next' } }
    } else {
      assert equal $cursor 'next'
      { nodes: [
        (thread-fixture 101 --body $marker)
        (thread-fixture 102 --author 'different-bot' --body $marker)
        (thread-fixture 103)
      ], pageInfo: { hasNextPage: false, endCursor: 'last' } }
    }
  }
  let annotated = annotate-review-threads $threads 'github-actions[bot]'
  assert equal ($annotated | where fingerprint != null | get id) ['101']
  assert equal ($annotated | length) 103
  let finding = parse-machine-findings ({ findings: [$FINDING] } | to json)
  assert equal (plan-thread-reconciliation $annotated [$fingerprint] $finding) { create: [], resolve: [] }
  assert equal (plan-thread-reconciliation $annotated [] []) { create: [], resolve: ['101'] }
  let resolved = $annotated | update isResolved true
  assert equal (plan-thread-reconciliation $resolved [] $finding) { create: $finding, resolve: [] }
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
def 'machine findings：accepts a single fenced JSON response' [] {
  let review = ['```json', ({ findings: [$FINDING] } | to json), '```'] | str join (char nl)
  let result = parse-machine-findings $review
  assert equal ($result | length) 1
  assert equal ($result | first | get rule) 'machine-output-contract'
}

@test
def 'machine findings：preserves actionable findings with missing or blank rules' [] {
  let missing = $FINDING | reject rule
  let blank = $FINDING | update rule '   '
  for finding in [$missing, $blank] {
    let parsed = parse-machine-findings ({ findings: [$finding] } | to json) | first
    assert equal $parsed.rule 'unspecified-review-rule'
    assert ($parsed.fingerprint =~ '^[a-f0-9]{64}$')
  }
  let missing_fingerprint = (parse-machine-findings ({ findings: [$missing] } | to json) | first).fingerprint
  let blank_fingerprint = (parse-machine-findings ({ findings: [$blank] } | to json) | first).fingerprint
  assert equal $missing_fingerprint $blank_fingerprint
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
def 'machine findings：normalizes only GitHub Actions reviewer aliases' [] {
  assert equal (machine-reviewer-matches 'github-actions' 'github-actions[bot]') true
  assert equal (machine-reviewer-matches 'github-actions[bot]' 'github-actions') true
  assert equal (machine-reviewer-matches 'github-actions' 'other-bot[bot]') false
  assert equal (machine-reviewer-matches 'other-bot[bot]' 'other-bot[bot]') true
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
