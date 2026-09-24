#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="$repo_root/.github/actions/setup-autogov/action.yaml"
setup_script="$repo_root/.github/actions/setup-autogov/setup.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

requested_sha=ff839e23f922e176897232c5b4148dc1d4c1b983
resolved_commit=1111111111111111111111111111111111111111
special_tag='release/#1+%é'
fixture="$test_root/fixture"
printf 'fixture-autogov\n' > "$fixture"
fixture_size="$(wc -c < "$fixture" | tr -d ' ')"
if command -v sha256sum >/dev/null 2>&1; then
  fixture_sha="$(sha256sum "$fixture" | awk '{ print $1 }')"
else
  fixture_sha="$(shasum -a 256 "$fixture" | awk '{ print $1 }')"
fi
fixture_digest="sha256:$fixture_sha"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "did not expect '$2' in $1"
  fi
}
assert_required_input() {
  awk -v wanted="  $2:" '
    $0 == wanted { in_input = 1; next }
    in_input && $0 ~ /^  [a-zA-Z0-9-]+:$/ { exit }
    in_input && $0 == "    required: true" { found = 1 }
    END { exit !found }
  ' "$1" || fail "expected $2 to be required in $1"
}
output_value() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print }' "$1"
}

[ -f "$action" ] || fail "missing setup-autogov action metadata"
[ -x "$setup_script" ] || fail "missing executable setup-autogov script"
assert_required_input "$action" autogov-version
assert_contains "$action" "GH_TOKEN: \${{ inputs.github-token || github.token }}"
assert_contains "$action" "AUTOGOV_VERSION: \${{ inputs.autogov-version }}"
assert_contains "$action" "AUTOGOV_REPO: \${{ inputs.autogov-repo }}"
assert_contains "$action" 'path:'
assert_contains "$action" 'release-tag:'
assert_contains "$action" 'commit-sha:'
assert_contains "$action" 'sha256:'

# Execute the YAML-decoded command, as Actions does, with spaces in the action
# directory. Ruby's standard YAML parser avoids testing YAML source as shell.
action_entry="$test_root/action-entry.sh"
ruby -ryaml -e '
  action = YAML.load_file(ARGV.fetch(0))
  puts action.fetch("runs").fetch("steps").find { |step| step["id"] == "setup" }.fetch("run")
' "$action" > "$action_entry"
action_dir="$test_root/action with spaces"
mkdir -p "$action_dir"
cp "$setup_script" "$action_dir/setup.sh"

stub_bin="$test_root/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'gh'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$GH_CALLS"

emit_release() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

if [ "$1" = --version ]; then
  [ "$GH_SCENARIO" != gh-version-failure ] || exit 19
  printf '%s\n' "$GH_VERSION_OUTPUT" 'https://github.com/cli/cli/releases'
elif [ "$1" = api ] && [ "$2" = --paginate ]; then
  endpoint="$3"
  case "$endpoint" in
    *'/releases?'*)
      [ "$GH_SCENARIO" != api-failure ] || exit 17
      case "$GH_SCENARIO" in
        special-tag)
          emit_release "$SPECIAL_TAG" true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        numeric-tags)
          emit_release 1 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          emit_release 01 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          emit_release 1.0 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        numeric-only-one)
          emit_release 1 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        numeric-sha-*)
          emit_release 01 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        mutable)
          emit_release v1.2.3 false 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        no-match)
          emit_release v1.3.0 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        multiple)
          emit_release v1.3.0 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          emit_release v1.3.1 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        missing-asset)
          emit_release v1.3.0 true 0 - 0
          ;;
        duplicate-asset)
          emit_release v1.3.0 true 2 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
        checksum-mismatch)
          emit_release v1.3.0 true 1 \
            sha256:0000000000000000000000000000000000000000000000000000000000000000 \
            "$FIXTURE_SIZE"
          ;;
        *)
          emit_release v1.3.0 true 1 "$FIXTURE_DIGEST" "$FIXTURE_SIZE"
          ;;
      esac
      ;;
    *'/tags?'*)
      case "$GH_SCENARIO" in
        numeric-sha-mismatch)
          printf '1\t%s\n' "$REQUESTED_SHA"
          ;;
        numeric-sha-success)
          printf '1\t%s\n01\t%s\n1.0\t%s\n' \
            "$RESOLVED_COMMIT" "$REQUESTED_SHA" "$RESOLVED_COMMIT"
          ;;
        no-match)
          printf 'v1.3.0\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
          ;;
        multiple)
          printf 'v1.3.0\t%s\nv1.3.1\t%s\n' "$REQUESTED_SHA" "$REQUESTED_SHA"
          ;;
        *)
          printf 'v1.3.0\t%s\n' "$REQUESTED_SHA"
          ;;
      esac
      ;;
    *)
      exit 2
      ;;
  esac
elif [ "$1" = api ]; then
  case "$2" in
    *'/commits/refs%2Ftags%2Fv1.3.0'|*'/commits/refs%2Ftags%2F01'|*'/commits/refs%2Ftags%2F1.0')
      if [[ "$GH_SCENARIO" = sha-success || "$GH_SCENARIO" = numeric-sha-* ]]; then
        printf '%s\n' "$REQUESTED_SHA"
      else
        printf '%s\n' "$RESOLVED_COMMIT"
      fi
      ;;
    *'/commits/refs%2Ftags%2Frelease%2F%231%2B%25%C3%A9')
      printf '%s\n' "$RESOLVED_COMMIT"
      ;;
    *'/commits/v1.3.0')
      # An unqualified name can select a branch with the same name as the tag.
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
      ;;
    *)
      exit 2
      ;;
  esac
elif [ "$1 $2" = 'release download' ]; then
  download_dir=
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        download_dir="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [ -n "$download_dir" ] || exit 3
  mkdir -p "$download_dir"
  if [ "$GH_SCENARIO" = empty-binary ]; then
    : > "$download_dir/autogov"
  else
    printf 'fixture-autogov\n' > "$download_dir/autogov"
  fi
elif [ "$1 $2" = 'release verify-asset' ]; then
  [ "$GH_SCENARIO" != signature-failure ] || exit 23
else
  exit 2
fi
STUB
chmod +x "$stub_bin/gh"

run_case() {
  local label="$1" version="$2" scenario="$3" expected="$4"
  local expected_tag="${5:-}"
  local repo="${6:-liatrio/autogov}" runner_os="${7:-Linux}" runner_arch="${8:-X64}"
  local gh_version="${9-gh version 2.101.0 (2026-09-15)}"
  local work="$test_root/$label" calls="$test_root/$label.calls" log="$test_root/$label.log"
  local expected_commit="$resolved_commit"
  if [[ "$scenario" = sha-success || "$scenario" = numeric-sha-* ]]; then
    expected_commit="$requested_sha"
  fi
  mkdir -p "$work/runner"
  : > "$calls"
  : > "$work/output"
  : > "$work/path"

  if env \
    PATH="$stub_bin:$PATH" \
    AUTOGOV_VERSION="$version" \
    AUTOGOV_REPO="$repo" \
    GH_TOKEN=test-token \
    GH_SCENARIO="$scenario" \
    GH_VERSION_OUTPUT="$gh_version" \
    GH_CALLS="$calls" \
    REQUESTED_SHA="$requested_sha" \
    SPECIAL_TAG="$special_tag" \
    RESOLVED_COMMIT="$resolved_commit" \
    FIXTURE_DIGEST="$fixture_digest" \
    FIXTURE_SIZE="$fixture_size" \
    RUNNER_OS="$runner_os" \
    RUNNER_ARCH="$runner_arch" \
    RUNNER_TEMP="$work/runner" \
    GITHUB_OUTPUT="$work/output" \
    GITHUB_PATH="$work/path" \
    GITHUB_ACTION_PATH="$action_dir" \
    bash "$action_entry" > "$log" 2>&1; then
    [ "$expected" = success ] || fail "$label unexpectedly succeeded"
    installed="$(output_value "$work/output" path)"
    [ -x "$installed" ] || fail "$label did not install an executable"
    cmp "$fixture" "$installed" || fail "$label installed different bytes"
    [ "$(output_value "$work/output" release-tag)" = "$expected_tag" ] ||
      fail "$label returned the wrong release tag"
    [ "$(output_value "$work/output" commit-sha)" = "$expected_commit" ] ||
      fail "$label returned the wrong commit"
    [ "$(output_value "$work/output" sha256)" = "$fixture_digest" ] ||
      fail "$label returned the wrong digest"
    [ "$(cat "$work/path")" = "$(dirname "$installed")" ] ||
      fail "$label did not add the install directory to PATH"
    assert_contains "$calls" 'gh <release> <verify-asset>'
  else
    [ "$expected" = failure ] || fail "$label unexpectedly failed: $(cat "$log")"
    [ ! -e "$work/runner/setup-autogov/bin/autogov" ] ||
      fail "$label retained an unverified binary"
    [ ! -s "$work/output" ] || fail "$label wrote action outputs after failure"
    [ ! -s "$work/path" ] || fail "$label wrote PATH additions after failure"
  fi
}

run_case sha-success "$requested_sha" sha-success success v1.3.0
assert_contains "$test_root/sha-success.calls" 'releases?per_page=100'
assert_contains "$test_root/sha-success.calls" 'tags?per_page=100'
run_case tag-success v1.3.0 tag-success success v1.3.0
assert_not_contains "$test_root/tag-success.calls" 'tags?per_page=100'
run_case branch-collision v1.3.0 branch-collision success v1.3.0
assert_contains "$test_root/branch-collision.calls" '<repos/liatrio/autogov/commits/refs%2Ftags%2Fv1.3.0>'
run_case special-tag "$special_tag" special-tag success "$special_tag"
assert_contains "$test_root/special-tag.calls" '<repos/liatrio/autogov/commits/refs%2Ftags%2Frelease%2F%231%2B%25%C3%A9>'
assert_contains "$test_root/special-tag.calls" "gh <release> <download> <$special_tag>"

run_case numeric-leading-zero 01 numeric-tags success 01
run_case numeric-decimal 1.0 numeric-tags success 1.0
run_case numeric-leading-zero-missing 01 numeric-only-one failure
run_case numeric-decimal-missing 1.0 numeric-only-one failure
run_case numeric-sha-success "$requested_sha" numeric-sha-success success 01
run_case numeric-sha-mismatch "$requested_sha" numeric-sha-mismatch failure
assert_not_contains "$test_root/numeric-sha-mismatch.calls" '/commits/'

run_case changed-commit "$requested_sha" changed-commit failure
assert_contains "$test_root/changed-commit.log" 'no longer resolves to requested commit'
assert_not_contains "$test_root/changed-commit.calls" 'gh <release> <download>'
assert_not_contains "$test_root/changed-commit.calls" 'gh <release> <verify-asset>'

run_case gh-minimum v1.3.0 tag-success success v1.3.0 liatrio/autogov Linux X64 'gh version 2.93.0 (2026-05-12)'
run_case gh-new-major v1.3.0 tag-success success v1.3.0 liatrio/autogov Linux X64 'gh version 3.0.0'
for old_or_invalid_version in \
  'gh version 2.92.0' 'gh version 2.92.99' 'gh version 1.100.0' \
  'gh version 2.93.0-rc.1' 'gh version 2.93' 'gh version garbage' \
  'unknown version 2.101.0' ''; do
  run_case gh-rejected v1.3.0 tag-success failure '' liatrio/autogov Linux X64 "$old_or_invalid_version"
  assert_contains "$test_root/gh-rejected.log" 'GitHub CLI 2.93.0 or newer'
  assert_not_contains "$test_root/gh-rejected.calls" 'gh <api>'
  assert_not_contains "$test_root/gh-rejected.calls" 'gh <release>'
done
run_case gh-version-failure v1.3.0 gh-version-failure failure
assert_contains "$test_root/gh-version-failure.log" 'GitHub CLI 2.93.0 or newer'
assert_not_contains "$test_root/gh-version-failure.calls" 'gh <api>'

run_case missing-version '' tag-success failure
assert_contains "$test_root/missing-version.log" 'autogov-version is required'
run_case invalid-repo v1.3.0 tag-success failure '' 'liatrio/autogov?ref=main'
assert_contains "$test_root/invalid-repo.log" 'autogov-repo must use owner/repo format'
run_case unsupported-os v1.3.0 tag-success failure '' liatrio/autogov macOS ARM64
assert_contains "$test_root/unsupported-os.log" 'requires a Linux X64 runner'
run_case mutable v1.2.3 mutable failure
assert_contains "$test_root/mutable.log" 'must identify an immutable published release'
run_case no-match cccccccccccccccccccccccccccccccccccccccc no-match failure
assert_contains "$test_root/no-match.log" 'must identify exactly one immutable published release'
run_case multiple "$requested_sha" multiple failure
assert_contains "$test_root/multiple.log" 'must identify exactly one immutable published release'
run_case api-failure v1.3.0 api-failure failure
run_case missing-asset v1.3.0 missing-asset failure
assert_contains "$test_root/missing-asset.log" "must contain exactly one 'autogov' asset"
run_case duplicate-asset v1.3.0 duplicate-asset failure
assert_contains "$test_root/duplicate-asset.log" "must contain exactly one 'autogov' asset"
run_case empty-binary v1.3.0 empty-binary failure
assert_contains "$test_root/empty-binary.log" 'downloaded autogov binary is not a non-empty regular file'
run_case checksum-mismatch v1.3.0 checksum-mismatch failure
assert_contains "$test_root/checksum-mismatch.log" 'autogov asset checksum mismatch'
assert_not_contains "$test_root/checksum-mismatch.calls" 'gh <release> <verify-asset>'
run_case signature-failure v1.3.0 signature-failure failure
assert_contains "$test_root/signature-failure.calls" 'gh <release> <verify-asset>'

echo 'setup-autogov fixture tests passed'
