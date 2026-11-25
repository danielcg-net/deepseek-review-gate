use std/assert
use std/testing *
use ../nu/review-proof.nu *
use ../nu/diff.nu [apply-file-filters]

def binding [] {
  expected-review-binding 'owner/repo' '42' ('a' | fill -c a -w 40) ('b' | fill -c b -w 40)
}

def pull [] {
  let b = binding
  { number: 42, state: 'open', locked: false, head: {sha: $b.head, repo: {full_name: $b.repository}}, base: {sha: $b.base, repo: {full_name: $b.repository}} }
}

@test
def 'binding：legacy is opt-out but partial and unsafe immutable inputs fail' [] {
  assert equal (expected-review-binding 'owner/repo' '42' '' '') null
  for args in [
    ['owner/repo' '42' 'a' 'b']
    ['owner/repo' '42' ('a' | fill -c a -w 40) '']
    ['owner/repo' '42' '' ('b' | fill -c b -w 40)]
    ['../repo?x=y' '42' ('a' | fill -c a -w 40) ('b' | fill -c b -w 40)]
    ['owner/repo' '0' ('a' | fill -c a -w 40) ('b' | fill -c b -w 40)]
  ] {
    assert (try { expected-review-binding $args.0 $args.1 $args.2 $args.3; false } catch { true })
  }
}

@test
def 'binding：head base repository PR lock and unavailable state fail closed' [] {
  assert-review-binding (binding) (pull)
  for bad in [
    (pull | update head.sha ('c' | fill -c c -w 40))
    (pull | update base.sha ('c' | fill -c c -w 40))
    (pull | update head.repo.full_name 'fork/repo')
    (pull | update base.repo.full_name 'other/repo')
    (pull | update state 'closed')
    (pull | update number 43)
    (pull | update locked true)
    (pull | reject locked)
    {}
  ] { assert (try { assert-review-binding (binding) $bad; false } catch { true }) }
}

@test
def 'thread guard：a stale first identity performs no writes' [] {
  let result = try {
    apply-guarded-thread-plan {create: [{path:'file'}], resolve:['thread']} {|| error make {msg:'stale'} } {|_| error make {msg:'UNSAFE CREATE'} } {|_| error make {msg:'UNSAFE RESOLVE'} } --resolve-stale
    'unexpected success'
  } catch {|e| $e.msg }
  assert equal $result 'stale'
}

@test
def 'thread guard：checks before each create and resolve and after the final write' [] {
  # A temporary append-only log observes order without mutable captured variables.
  let log = mktemp
  let write = {|text| $'($text)(char nl)' | save --append $log }
  apply-guarded-thread-plan {create: [{path:'one'} {path:'two'}], resolve:['old']} {|| do $write guard } {|f| do $write $f.path } {|id| do $write $id } --resolve-stale
  assert equal (open -r $log | lines) [guard one guard two guard old guard]
  rm $log
}

@test
def 'thread guard：identity changes after a write stop later mutations' [] {
  let log = mktemp
  let result = try {
    apply-guarded-thread-plan {create: [{path:'one'} {path:'two'}], resolve:['old']} {||
      if (open -r $log | is-not-empty) { error make {msg:'stale'} }
    } {|f| $f.path | save --append $log } {|_| error make {msg:'UNSAFE RESOLVE'} } --resolve-stale
    'unexpected success'
  } catch {|e| $e.msg }
  assert equal $result 'stale'
  assert equal (open -r $log) one
  rm $log
}

@test
def 'evidence：binds source projection refs and explicit empty outcome without source text' [] {
  let b = binding | insert mergeBase ('c' | fill -c c -w 40)
  let evidence = immutable-review-evidence $b 'private source' 'selected content' '' '*.lock' reviewed
  assert equal $evidence.version 1
  assert equal $evidence.sourceDiffSha256 ('private source' | hash sha256)
  assert equal $evidence.diffSha256 ('selected content' | hash sha256)
  assert equal $evidence.excludePatterns '*.lock'
  assert equal $evidence.complete true
  assert equal $evidence.outcome reviewed
  assert equal $evidence.head $b.head
  assert not ($evidence | to json --raw | str contains 'private source')
  let empty = immutable-review-evidence $b 'source' '' '' '*.lock' empty-selection
  assert equal $empty.diffSha256 ('' | hash sha256)
  assert equal $empty.outcome empty-selection
  for outcome in [skipped failed truncated] {
    assert (try { immutable-review-evidence $b source '' '' '' $outcome; false } catch { true })
  }
  assert (try { immutable-review-evidence $b source content '' '' empty-selection; false } catch { true })
}

@test
def 'immutable diff：reads pinned objects after ref moves with no checkout helpers' [] {
  let directory = mktemp -d
  ^git init -q $directory
  ^git -C $directory config user.name Test
  ^git -C $directory config user.email test@example.invalid
  'old' | save ($directory | path join 'file with spaces.txt')
  ^git -C $directory add .
  ^git -C $directory -c commit.gpgsign=false commit -qm old
  let base = ^git -C $directory rev-parse HEAD | str trim
  'new' | save -f ($directory | path join 'file with spaces.txt')
  ^git -C $directory -c commit.gpgsign=false commit -qam new
  let head = ^git -C $directory rev-parse HEAD | str trim
  let bare = mktemp -d
  ^git clone -q --bare --no-hardlinks $directory $bare
  let content = immutable-git-diff $bare $base $head
  assert ($content | str contains '+new')
  # Configured external diff and text conversion must not execute.
  ^git --git-dir $bare config diff.external 'DO-NOT-EXECUTE'
  ^git --git-dir $bare config diff.custom.textconv 'DO-NOT-EXECUTE'
  '* diff=custom' | save ($directory | path join .gitattributes)
  ^git --git-dir $bare config core.attributesFile ($directory | path join .gitattributes)
  'later' | save -f ($directory | path join 'file with spaces.txt')
  ^git -C $directory add .
  ^git -C $directory -c commit.gpgsign=false commit -qm later
  assert equal (immutable-git-diff $bare $base $head) $content
  assert (try { immutable-git-diff $bare '--bad-ref' $head; false } catch { true })
  rm -rf $bare
  rm -rf $directory
}

@test
def 'projection：default lockfile exclusion remains deterministic including empty selection' [] {
  let lock = "diff --git a/package-lock.json b/package-lock.json\n--- a/package-lock.json\n+++ b/package-lock.json\n@@ -1 +1 @@\n-old\n+new\n"
  assert equal (apply-file-filters $lock --include '' --exclude 'pnpm-lock.yaml,package-lock.json,*.lock') ''
  assert equal (apply-file-filters $lock --include '' --exclude '') $lock
}

@test
def 'immutable invocation：partial refs length limits and missing tokens fail without evidence' [] {
  let output = mktemp
  let head = binding | get head
  let base = binding | get base
  for snippet in [
    $'deepseek-review fake --repo owner/repo --pr-number 42 --expected-head-sha ($head)'
    $'deepseek-review fake --repo owner/repo --pr-number 42 --expected-head-sha ($head) --expected-base-sha ($base) --max-length 1'
    $'deepseek-review "" --repo owner/repo --pr-number 42 --expected-head-sha ($head) --expected-base-sha ($base)'
  ] {
    let result = with-env {GITHUB_ACTIONS:'true', GITHUB_OUTPUT:$output} {
      ^$nu.current-exe -n -c $'use nu/review.nu [deepseek-review]; ($snippet)' | complete
    }
    assert ($result.exit_code != 0)
    assert not ($result.stdout | str contains 'Posting review')
    assert equal (open -r $output) ''
  }
  rm $output
}
