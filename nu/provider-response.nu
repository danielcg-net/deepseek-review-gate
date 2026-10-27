# Private, bounded non-streaming provider boundary. Never print response values.
const MAX_RESPONSE_BYTES = 8388608

def record? [value: any] { ($value | describe) | str starts-with 'record' }

def failure [stage: string, status: any, request_ref: any, envelope: string] {
  { ok: false, diagnostic: { stage: $stage, http_status: $status, request_ref: $request_ref, envelope: $envelope } }
}

def request-reference [headers: any] {
  if not (($headers | describe) | str starts-with 'table') { return null }
  let candidates = $headers | where {|row|
    (($row.name? | describe) == 'string') and (($row.name | str lowercase) in ['x-request-id', 'request-id'])
  }
  if ($candidates | length) != 1 { return null }
  let value = $candidates.0.value?
  if ($value | describe) != 'string' { return null }
  if (($value | str length) < 1) or (($value | str length) > 128) or ($value !~ '^[A-Za-z0-9_-]+$') { return null }
  # A header is not trusted data. Only its fingerprint may leave this boundary.
  $value | hash sha256
}

def envelope [body: any] {
  if not (record? $body) { return 'invalid' }
  if ('error' in ($body | columns)) and ($body.error != null) { return 'error' }
  if ('choices' in ($body | columns)) { return 'chat_completion' }
  if ('message' in ($body | columns)) { return 'message' }
  'invalid'
}

# Fetch exactly once, force the bounded body within catch, and return only fixed
# diagnostics on failure. Valid parsed responses remain private to the caller.
export def request-provider-review [url: string, headers: record, payload: record, timeout: duration] {
  let http = try {
    http post -e -r -m $timeout -H $headers -t application/json $url $payload
      # Limit the ByteStream BEFORE $in/metadata access materializes its value.
      | first ($MAX_RESPONSE_BYTES + 1)
      | metadata access {|meta|
          let body = $in
          { status: $meta.http_response.status?, headers: $meta.http_response.headers?, body: $body }
        }
  } catch {
    return (failure 'transport' null null 'unknown')
  }
  let status = $http.status
  if (($status | describe) != 'int') or ($status < 100) or ($status > 599) {
    return (failure 'response_shape' null null 'unknown')
  }
  let request_ref = request-reference $http.headers
  if ($http.body | bytes length) > $MAX_RESPONSE_BYTES {
    return (failure 'body_limit' $status $request_ref 'unknown')
  }
  let text = try { $http.body | decode utf-8 } catch { return (failure 'decode' $status $request_ref 'invalid') }
  if ($text | encode utf-8) != $http.body { return (failure 'decode' $status $request_ref 'invalid') }
  if ($text | str trim | is-empty) {
    return (failure (if ($status < 200) or ($status >= 300) { 'http_status' } else { 'response_shape' }) $status $request_ref 'empty')
  }
  let parsed = try { $text | from json --strict } catch {
    if ($status < 200) or ($status >= 300) { return (failure 'http_status' $status $request_ref 'non_json') }
    return (failure 'response_shape' $status $request_ref (if ($text | str trim | is-empty) { 'empty' } else { 'non_json' }))
  }
  let kind = envelope $parsed
  if ($status < 200) or ($status >= 300) { return (failure 'http_status' $status $request_ref $kind) }
  if $kind == 'error' { return (failure 'provider_error' $status $request_ref $kind) }
  if $kind not-in ['chat_completion', 'message'] { return (failure 'response_shape' $status $request_ref $kind) }
  let extracted = try {
    let message = $parsed | get -o choices.0.message
    { message: $message, review: ($message.content? | default ($parsed | get -o message.content)) }
  } catch { return (failure 'response_shape' $status $request_ref $kind) }
  let message = $extracted.message
  let review = $extracted.review
  if ($review | describe) != 'string' { return (failure 'review_missing' $status $request_ref $kind) }
  if ($review | str trim | is-empty) { return (failure 'review_missing' $status $request_ref $kind) }
  let reasoning = $message.reasoning_content? | default $message.reasoning?
  if ($reasoning != null) and (($reasoning | describe) != 'string') { return (failure 'response_shape' $status $request_ref $kind) }
  { ok: true, response: $parsed, review: $review, message: $message,
    diagnostic: { stage: 'complete', http_status: $status, request_ref: $request_ref, envelope: $kind } }
}
