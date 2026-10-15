use std/assert
use std/testing *
const SECRET = 'PRIVATE_PROVIDER_BODY_SENTINEL'
const INPUT_SECRET = 'PRIVATE_DIFF_PROMPT_SENTINEL'
# [strategy]
def serial-provider []: nothing -> record { { threads: 1 } }
@before-all
def setup [] { let dir = $nu.temp-dir | path join $'provider-response-(random chars -l 8)'; mkdir $dir; { dir: $dir } }
@after-all
def teardown [] { rm -rf $in.dir }

def start [dir: string, mode: string] {
  let log = $dir | path join $'($mode).log'
  let observation = $dir | path join $'($mode).json'
  let job = job spawn { ^node tests/resources/provider-response-server.mjs $mode $observation out+err> $log }
  for _ in 1..100 {
    sleep 50ms
    let text = try { open -r $log } catch { '' }
    if ($text | str contains 'PORT=') { return {job: $job, port: ($text | parse -r 'PORT=(?<p>\d+)' | get 0.p), observation: $observation} }
  }
  job kill $job
  error make { msg: 'Synthetic provider did not start.' }
}
def cli [dir: string, port: string, action: bool, debug: bool] {
  let patch = $dir | path join 'synthetic.diff'
  $'diff --git a/example.js b/example.js(char nl)--- a/example.js(char nl)+++ b/example.js(char nl)@@ -1 +1 @@(char nl)-old(char nl)+($INPUT_SECRET)(char nl)' | save -f $patch
  let output = $dir | path join 'review.md'
  if ($output | path exists) { rm $output }
  let debug_arg = if $debug { '--debug' } else { '' }
  ^$nu.current-exe -n -c $"
    $env.GITHUB_ACTIONS = '($action)'; $env.GITHUB_TOKEN = null; $env.GH_TOKEN = null
    use nu/review.nu [deepseek-review]
    deepseek-review sk-mock-token --patch-file '($patch)' --chat-url 'http://127.0.0.1:($port)/chat' --model deepseek-v4-pro --temperature 0 --request-timeout 500ms --sys-prompt '($INPUT_SECRET)' --user-prompt '($INPUT_SECRET)' --output '($output)' ($debug_arg)
  " | complete
}
def safe [result: record] {
  let text = $'($result.stdout)(char nl)($result.stderr)' | ansi strip
  for value in [$SECRET, 'sk-mock-token', 'safe_Ref-123', 'set-cookie'] { assert equal ($text | str contains $value) false }
  $text
}
def diagnostic [result: record] { safe $result | lines | where {|line| $line | str starts-with '{"stage":' } | last | from json }
def wire [mock: record] { assert equal (open $mock.observation | select count auth model stream temperature thinking) {count: 1, auth: true, model: true, stream: true, temperature: true, thinking: true} }

@test
def 'HTTP errors and provider error envelopes reject before review parsing' [] {
  let ctx = $in
  for mode in ['http401', 'http429', 'http500', 'http503', 'http503-completion', 'provider-error'] {
    let m = start $ctx.dir $mode; let r = cli $ctx.dir $m.port false false; job kill $m.job
    assert equal $r.exit_code 3
    let d = diagnostic $r
    assert equal $d.stage (if $mode == 'provider-error' { 'provider_error' } else { 'http_status' })
    assert equal $d.http_status (if $mode == 'provider-error' { 200 } else if $mode == 'http503-completion' { 503 } else { $mode | str substring 4.. | into int })
    assert equal $d.request_ref ('safe_Ref-123' | hash sha256)
    assert equal $d.envelope (if $mode == 'http503-completion' { 'chat_completion' } else { 'error' })
    assert equal (($ctx.dir | path join 'review.md') | path exists) false
    wire $m
  }
}
@test
def 'Empty malformed nonJSON invalidUTF8 and truncated responses stay private' [] {
  let ctx = $in
  for mode in ['zero200', 'zero204', 'empty-choices', 'null-content', 'empty-content', 'malformed-choices', 'malformed-content', 'malformed-reasoning', 'text', 'malformed-json', 'invalid-utf8', 'truncated'] {
    let m = start $ctx.dir $mode; let r = cli $ctx.dir $m.port false true; job kill $m.job
    assert equal $r.exit_code 3
    let d = diagnostic $r
    assert ($d.stage in ['review_missing', 'response_shape', 'decode', 'transport'])
    if $mode in ['zero200', 'zero204'] {
      assert equal $d.stage 'response_shape'
      assert equal $d.envelope 'empty'
      assert equal $d.http_status (if $mode == 'zero204' { 204 } else { 200 })
    }
    assert equal (($ctx.dir | path join 'review.md') | path exists) false
    wire $m
  }
}
@test
def 'Noheader and midbody timeout and oversized streams are bounded in actual CLI' [] {
  let ctx = $in
  for mode in ['hang', 'midbody-hang', 'oversize', 'slow-oversize'] {
    let m = start $ctx.dir $mode; let began = date now; let r = cli $ctx.dir $m.port false false; let elapsed = (date now) - $began
    if $mode == 'slow-oversize' {
      # Wait for server close metadata BEFORE killing it. Reading the complete
      # advertised body and rejecting afterward must fail this regression.
      for _ in 1..100 {
        let observed = open $m.observation
        if $observed.responseClosed { break }
        sleep 20ms
      }
      let observed = open $m.observation
      assert equal $observed.responseClosed true
      assert ($observed.responseBytesWritten > 0)
      assert ($observed.responseBytesWritten < $observed.advertisedResponseBytes)
      assert equal $observed.advertisedResponseBytes 12582912
    }
    job kill $m.job
    assert equal $r.exit_code 3
    assert equal (diagnostic $r).stage (if $mode in ['hang', 'midbody-hang'] { 'transport' } else { 'body_limit' })
    assert ($elapsed < 5sec)
    wire $m
  }
}
@test
def 'Action debug never prints diff prompt body or exception before strict rejection' [] {
  let ctx = $in
  for mode in ['http401', 'text', 'malformed-review', 'hang'] {
    let m = start $ctx.dir $mode; let r = cli $ctx.dir $m.port true true; job kill $m.job
    assert ($r.exit_code != 0)
    let text = safe $r
    for forbidden in [$INPUT_SECRET, 'Code Changes:', 'DeepSeek Model Response:'] { assert equal ($text | str contains $forbidden) false }
    assert ($text | str contains 'Action debug: request and response content are redacted.')
    wire $m
  }
}
@test
def 'Valid completion fallback and keepalive preserve file output and wire payload' [] {
  let ctx = $in
  for mode in ['success', 'fallback', 'keepalive', 'unsafe-ref', 'duplicate-ref', 'dual-ref', 'oversize-ref', 'no-ref'] {
    let m = start $ctx.dir $mode; let r = cli $ctx.dir $m.port false false; job kill $m.job
    assert equal $r.exit_code 0
    safe $r | ignore
    let content = open -r ($ctx.dir | path join 'review.md')
    assert ($content | str contains '{"findings":[]}')
    if $mode != 'fallback' { assert ($content | str contains 'SYNTHETIC_REASONING') }
    wire $m
  }
}
@test
def 'Request references are hashes or absent and unchanged strict parser accepts valid review' [] {
  let ctx = $in
  for mode in ['success', 'unsafe-ref', 'duplicate-ref', 'dual-ref', 'oversize-ref', 'no-ref'] {
    let m = start $ctx.dir $mode
    let r = ^$nu.current-exe -n -c $"
      use nu/provider-response.nu [request-provider-review]; use nu/review-threads.nu [parse-machine-findings]
      let r = request-provider-review 'http://127.0.0.1:($m.port)/chat' {Authorization: 'Bearer sk-mock-token'} {model: deepseek-v4-pro, stream: false, temperature: 0, thinking: {type: disabled}} 500ms
      if not $r.ok { exit 3 }
      {diagnostic: $r.diagnostic, findings: \(parse-machine-findings $r.review\)} | to json --raw
    " | complete
    job kill $m.job
    assert equal $r.exit_code 0
    let parsed = $r.stdout | from json
    assert equal $parsed.findings []
    assert equal $parsed.diagnostic.request_ref (if $mode == 'success' { 'safe_Ref-123' | hash sha256 } else { null })
    safe $r | ignore
    wire $m
  }
}
