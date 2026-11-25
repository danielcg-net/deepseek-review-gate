# Opt-in immutable review inputs and evidence. No contributor checkout or execution.

def fail [message: string] { error make { msg: $message } }

export def expected-review-binding [repo: string, pr: string, head: string, base: string] {
  if ($head | is-empty) and ($base | is-empty) { return null }
  if not ($repo =~ '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') or not ($pr =~ '^[1-9][0-9]*$') {
    fail 'Immutable review requires a repository and pull request number.'
  }
  if not ($head =~ '^[a-f0-9]{40}$') or not ($base =~ '^[a-f0-9]{40}$') {
    fail 'Immutable review requires both full lowercase expected commit SHAs.'
  }
  { repository: $repo, pr: ($pr | into int), head: $head, base: $base }
}

export def assert-review-binding [binding: record, pull: record] {
  if $pull.number? != $binding.pr or $pull.state? != 'open' or $pull.locked? != false or (
    $pull.head.sha? != $binding.head) or $pull.base.sha? != $binding.base or (
    $pull.head.repo.full_name? != $binding.repository) or $pull.base.repo.full_name? != $binding.repository {
    fail 'Immutable review pull request identity changed or is unavailable.'
  }
}

def headers [] {
  [Authorization $'Bearer ($env.GH_TOKEN)' Accept application/vnd.github+json X-GitHub-Api-Version '2022-11-28']
}

export def read-review-binding [binding: record] {
  let pull = http get -H (headers) $'https://api.github.com/repos/($binding.repository)/pulls/($binding.pr)'
  assert-review-binding $binding $pull
  $pull
}

# Never include Git output: it can contain credentials, remote data, or paths.
def git-safe [...args: string] {
  let result = ^git ...$args | complete
  if $result.exit_code != 0 { fail 'Immutable review Git object operation failed.' }
  $result.stdout
}

# Testable with a local bare repository; the two immutable objects are the only inputs.
export def immutable-git-diff [directory: string, merge_base: string, head: string] {
  if not ($merge_base =~ '^[a-f0-9]{40}$') or not ($head =~ '^[a-f0-9]{40}$') {
    fail 'Immutable diff requires full commit SHAs.'
  }
  # Disable executable diff/textconv helpers, custom rename thresholds and submodule traversal.
  git-safe -- --git-dir $directory -c core.quotePath=true -c color.ui=false diff --no-ext-diff --no-textconv --find-renames=50% --full-index --submodule=short --ignore-submodules=none --src-prefix=a/ --dst-prefix=b/ $merge_base $head --
}

export def fetch-immutable-review-source [binding: record] {
  read-review-binding $binding | ignore
  let comparison = http get -H (headers) $'https://api.github.com/repos/($binding.repository)/compare/($binding.base)...($binding.head)?per_page=1'
  let merge_base = $comparison.merge_base_commit.sha? | default ''
  if not ($merge_base =~ '^[a-f0-9]{40}$') or $comparison.base_commit.sha? != $binding.base {
    fail 'Immutable review merge base is unavailable.'
  }
  let directory = mktemp -d
  # A fresh bare object store never creates a worktree. Git config, hooks,
  # replace refs and prompts cannot select contributor-supplied executables.
  let null_file = if $nu.os-info.name == 'windows' { 'NUL' } else { '/dev/null' }
  let git_env = {
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: $null_file, GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'http.https://github.com/.extraheader',
    GIT_CONFIG_VALUE_0: $'AUTHORIZATION: basic ((["x-access-token:" $env.GH_TOKEN] | str join) | encode base64)',
    GIT_TERMINAL_PROMPT: '0', GIT_NO_REPLACE_OBJECTS: '1', GIT_ATTR_NOSYSTEM: '1',
    GIT_CONFIG_PARAMETERS: '', GIT_CONFIG_SYSTEM: $null_file,
  }
  let result = try {
    with-env $git_env {
      hide-env -i GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_SHALLOW_FILE GIT_CONFIG GIT_NAMESPACE
      git-safe -- -c $'core.hooksPath=($null_file)' init --bare --template= $directory | ignore
      git-safe -- --git-dir $directory -c $'core.hooksPath=($null_file)' -c credential.helper= -c http.followRedirects=false -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 fetch --quiet --no-tags --depth=1 $'https://github.com/($binding.repository).git' $binding.head $merge_base | ignore
      let content = immutable-git-diff $directory $merge_base $binding.head
      { ok: true, content: $content }
    }
  } catch { { ok: false } }
  rm -rf $directory
  if not $result.ok { fail 'Immutable review could not read the complete Git diff.' }
  read-review-binding $binding | ignore
  { binding: ($binding | insert mergeBase $merge_base), content: $result.content }
}

# Run the guard before every write, including stale-thread resolution. A final
# guard prevents successful evidence after a head/base change during the last write.
export def apply-guarded-thread-plan [plan: record, guard: closure, create: closure, resolve: closure, --resolve-stale] {
  for finding in $plan.create { do $guard; do $create $finding }
  if $resolve_stale { for id in $plan.resolve { do $guard; do $resolve $id } }
  do $guard
}

export def immutable-review-evidence [binding: record, source: string, content: string, include: string, exclude: string, outcome: string] {
  if $outcome not-in ['reviewed', 'empty-selection'] or ($outcome == 'empty-selection' and ($content | is-not-empty)) {
    fail 'Immutable review has no completed outcome.'
  }
  $binding | merge {
    version: 1, sourceDiffSha256: ($source | hash sha256), diffSha256: ($content | hash sha256),
    includePatterns: $include, excludePatterns: $exclude, outcome: $outcome, complete: true,
  }
}
