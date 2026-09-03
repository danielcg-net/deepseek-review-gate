# Deterministic lifecycle for actionable machine-review threads.

const MARKER_PREFIX = '<!-- deepseek-review-gate:fingerprint='
const MARKER_SUFFIX = ' -->'
const GRAPHQL_URL = 'https://api.github.com/graphql'

def github-headers [] {
  [
    Authorization $'Bearer ($env.GH_TOKEN)'
    Accept application/vnd.github+json
    X-GitHub-Api-Version '2022-11-28'
    User-Agent curl/8.9
  ]
}

def fail [message: string] {
  error make { msg: $message }
}

def finding-fingerprint [finding: record] {
  {
    severity: $finding.severity
    path: $finding.path
    line: $finding.line
    rule: $finding.rule
    message: $finding.message
  } | to json | hash sha256
}

# Parses the strict provider response. Invalid output is an error, never a
# harmless empty review: a required machine gate must fail closed.
export def parse-machine-findings [review: string] {
  let parsed = try { $review | from json } catch { fail 'Machine review must be a JSON object with a findings array.' }
  let findings = $parsed.findings?
  if $findings == null { fail 'Machine review JSON is missing findings.' }
  let findings_type = $findings | describe
  if not (($findings_type | str starts-with 'list') or ($findings_type | str starts-with 'table')) { fail 'Machine review findings must be an array.' }

  let normalized = $findings | each {|finding|
    let severity = $finding.severity? | default '' | into string | str downcase
    let path = $finding.path? | default '' | into string | str trim
    let line = try { $finding.line? | into int } catch { 0 }
    let rule = $finding.rule? | default '' | into string | str trim
    let message = $finding.message? | default '' | into string | str trim
    if $severity not-in ['critical', 'warning', 'suggestion'] { fail 'Machine finding severity must be critical, warning, or suggestion.' }
    if ($path | is-empty) { fail 'Machine finding path must not be empty.' }
    if $line < 1 { fail 'Machine finding line must be a positive changed-file line.' }
    if ($rule | is-empty) { fail 'Machine finding rule must not be empty.' }
    if ($message | is-empty) { fail 'Machine finding message must not be empty.' }
    let base = { severity: $severity, path: $path, line: $line, rule: $rule, message: $message }
    $base | insert fingerprint (finding-fingerprint $base)
  }
  let fingerprints = $normalized | get fingerprint
  if (($fingerprints | uniq | length) != ($fingerprints | length)) { fail 'Machine review emitted duplicate findings.' }
  $normalized
}

export def parse-active-fingerprints [serialized: string] {
  let parsed = try { $serialized | from json } catch { fail 'active-fingerprints must be a JSON array.' }
  if not (($parsed | describe) | str starts-with 'list') { fail 'active-fingerprints must be a JSON array.' }
  $parsed | each {|fingerprint|
    let fingerprint = $fingerprint | into string
    if not ($fingerprint =~ '^[a-f0-9]{64}$') { fail 'active-fingerprints contains an invalid fingerprint.' }
    $fingerprint
  }
}

# Serialize fingerprints as a single JSON line suitable for GitHub's GITHUB_OUTPUT file.
export def serialize-active-fingerprints [fingerprints: list<string>] {
  $fingerprints | to json --raw
}

def split-repo [repo: string] {
  let parts = $repo | split row '/'
  if (($parts | length) != 2) { fail 'repo must be owner/name.' }
  { owner: ($parts | get 0), name: ($parts | get 1) }
}

export def parse-graphql-response [response: any] {
  # `http post --full` returns `{ status, headers, body }`; allow direct payloads
  # as well so the boundary is testable without a network call.
  let body = $response.body? | default $response
  let payload = if (($body | describe) | str starts-with 'string') {
    try { $body | from json } catch { fail 'GitHub GraphQL returned a non-JSON response body.' }
  } else { $body }
  if ($payload.errors? | is-not-empty) { fail $'GitHub GraphQL returned errors: ($payload.errors | to json)' }
  let data = $payload.data?
  if $data == null { fail $'GitHub GraphQL response has no data: ($payload | to json)' }
  $data
}

def graphql [query: string, variables: record] {
  let response = try {
    http post -e -f -t application/json -H (github-headers) $GRAPHQL_URL { query: $query, variables: $variables }
  } catch {|err| fail $'GitHub GraphQL request failed: ($err.msg? | default $err)' }
  parse-graphql-response $response
}

export def machine-reviewer-matches [actual: string, configured: string] {
  if $configured in ['github-actions', 'github-actions[bot]'] {
    $actual in ['github-actions', 'github-actions[bot]']
  } else {
    $actual == $configured
  }
}

def thread-fingerprint [thread: record, reviewer_login: string] {
  let root = $thread.comments.nodes? | default [] | first | default {}
  if not (machine-reviewer-matches ($root.author.login? | default '') $reviewer_login) { return null }
  let body = $root.body? | default ''
  if not ($body | str contains $MARKER_PREFIX) { return null }
  let fingerprint = ($body | split row $MARKER_PREFIX | last | split row $MARKER_SUFFIX | first | str trim)
  if not ($fingerprint =~ '^[a-f0-9]{64}$') { return null }
  $fingerprint
}

def owned-review-threads [repo: string, pr_number: int, reviewer_login: string] {
  let parts = split-repo $repo
  let query = 'query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 100) { nodes { author { login } body } } } pageInfo { hasNextPage } } } } }'
  let threads = graphql $query { owner: $parts.owner, name: $parts.name, number: $pr_number } | get repository.pullRequest.reviewThreads
  if $threads.pageInfo.hasNextPage { fail 'More than 100 review threads require pagination; refusing incomplete reconciliation.' }
  $threads.nodes | each {|thread| $thread | insert fingerprint (thread-fingerprint $thread $reviewer_login) }
}

def finding-body [finding: record] {
  [
    $'### DeepSeek review — ($finding.severity)'
    ''
    $'**Rule:** ($finding.rule)'
    ''
    $finding.message
    ''
    $'($MARKER_PREFIX)($finding.fingerprint)($MARKER_SUFFIX)'
  ] | str join "\n"
}

def create-review-thread [repo: string, pr_number: int, head_sha: string, finding: record] {
  let url = $'https://api.github.com/repos/($repo)/pulls/($pr_number)/comments'
  try {
    http post -e -f -t application/json -H (github-headers) $url {
      body: (finding-body $finding)
      commit_id: $head_sha
      path: $finding.path
      line: $finding.line
      side: 'RIGHT'
    } | ignore
  } catch {|err| fail $'Creating machine review thread failed for ($finding.path):($finding.line): ($err.msg? | default $err)' }
}

def resolve-thread [thread_id: string] {
  let mutation = 'mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } } }'
  let result = graphql $mutation { threadId: $thread_id }
  if not ($result.resolveReviewThread.thread.isResolved) { fail $'GitHub did not resolve machine review thread ($thread_id).' }
}

# Creates a real inline GitHub review thread for each new actionable finding,
# then resolves only this action's stale unresolved threads. Human threads and
# threads created by a different bot are never touched.
export def reconcile-machine-review-threads [
  repo: string,
  pr_number: int,
  active_fingerprints: list<string>,
  findings?: list<record>,
  --reviewer-login: string = 'github-actions[bot]'
  --resolve-stale
] {
  let threads = owned-review-threads $repo $pr_number $reviewer_login
  let existing_open = $threads | where { (not $in.isResolved) and ($in.fingerprint != null) } | get fingerprint
  let head = try { http get -H (github-headers) $'https://api.github.com/repos/($repo)/pulls/($pr_number)' } catch {|err| fail $'Reading pull request head failed: ($err.msg? | default $err)' }
  let head_sha = $head.head.sha? | default ''
  if ($head_sha | is-empty) { fail 'GitHub pull request response has no head SHA.' }
  for finding in ($findings | default []) {
    if $finding.fingerprint not-in $existing_open { create-review-thread $repo $pr_number $head_sha $finding }
  }
  if $resolve_stale {
    for thread in $threads {
      if (not $thread.isResolved) and ($thread.fingerprint != null) and ($thread.fingerprint not-in $active_fingerprints) {
        resolve-thread $thread.id
      }
    }
  }
}
