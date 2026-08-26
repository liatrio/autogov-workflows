#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/rw-release.yaml"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
version_binding='AUTOGOV_VERSION: $'"{{ inputs.autogov-version }}"
repo_binding='AUTOGOV_REPO: $'"{{ inputs.autogov-repo }}"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_arg_pair() {
  awk -v option="$2" -v value="$3" '
    previous == option && $0 == value { found = 1 }
    { previous = $0 }
    END { exit !found }
  ' "$1" || fail "expected argument pair '$2' '$3' in $1"
}
assert_input_default_true() {
  awk -v wanted="      $2:" '
    $0 == wanted { in_input = 1; next }
    in_input && $0 ~ /^      [a-zA-Z0-9-]+:$/ { exit }
    in_input && $0 ~ /^[[:space:]]+default: true$/ { found = 1 }
    END { exit !found }
  ' "$1" || fail "expected $2 to default to true in $1"
}
assert_input_default() {
  awk -v wanted="      $2:" -v expected="$3" '
    $0 == wanted { in_input = 1; next }
    in_input && $0 ~ /^      [a-zA-Z0-9-]+:$/ { exit }
    in_input && index($0, "default: " expected) { found = 1 }
    END { exit !found }
  ' "$1" || fail "expected $2 to default to $3 in $1"
}
assert_composite_empty_default() {
  awk -v expected="    default: ''" '
    $0 == "  autogov-version:" { in_input = 1; next }
    in_input && $0 ~ /^  [a-zA-Z0-9-]+:$/ { exit }
    in_input && $0 == expected { found = 1 }
    END { exit !found }
  ' "$1" || fail "expected composite autogov-version to preserve its empty latest-release default"
}

extract_run_block() {
  local source_file="$1" step_name="$2" occurrence="$3" output="$4"
  awk -v wanted="$step_name" -v wanted_occurrence="$occurrence" '
    function indentation(line) { match(line, /[^ ]/); return RSTART == 0 ? length(line) : RSTART - 1 }
    $0 ~ /^[ ]*- name: / {
      name = $0
      sub(/^[ ]*- name: /, "", name)
      if (name == wanted) {
        seen += 1
        if (seen == wanted_occurrence) { in_step = 1; next }
      }
    }
    in_step && $0 ~ /^[ ]*run: \|$/ { in_run = 1; run_indent = indentation($0); next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if (indentation($0) <= run_indent) { exit }
      print substr($0, run_indent + 3)
    }
    in_step && $0 ~ /^[ ]*- name:/ { exit }
  ' "$source_file" > "$output"
  [ -s "$output" ] || fail "could not extract run block for '$step_name'"
  bash -n "$output"
}

normalize_script="$test_root/normalize.sh"
map_script="$test_root/map.sh"
cut_script="$test_root/cut.sh"
install_script="$test_root/install.sh"
canonical_install_script="$test_root/canonical-install.sh"
composite_install_script="$test_root/composite-install.sh"
extract_run_block "$workflow" "Normalize release artifact IDs" 1 "$normalize_script"
extract_run_block "$workflow" "Map release asset sources" 1 "$map_script"
extract_run_block "$workflow" "Run release cut" 1 "$cut_script"
extract_run_block "$workflow" "Install autogov" 1 "$install_script"
extract_run_block "$repo_root/.github/workflows/rw-verify.yaml" "Install autogov" 1 "$canonical_install_script"
extract_run_block "$repo_root/.github/actions/build-image/action.yaml" "Compute next release version for the image tag # preemptive semver tag via the autogov CLI" 1 "$composite_install_script"

assert_input_default_true "$repo_root/.github/workflows/rw-build-image.yaml" release-image
assert_input_default_true "$repo_root/.github/workflows/rw-build-blob.yaml" release-blob
assert_input_default_true "$repo_root/.github/workflows/rw-build-blob-offline.yaml" release-blob
assert_composite_empty_default "$repo_root/.github/actions/build-image/action.yaml"
for input_file in \
  rw-attest-blob-offline.yaml rw-attest-blob.yaml rw-attest-image.yaml \
  rw-build-blob-offline.yaml rw-build-blob.yaml rw-build-image.yaml \
  rw-release.yaml rw-verify-offline.yaml rw-verify.yaml; do
  assert_input_default "$repo_root/.github/workflows/$input_file" autogov-version ff839e23f922e176897232c5b4148dc1d4c1b983
done

while IFS='|' read -r installer_file expected_count; do
  [ -n "$installer_file" ] || continue
  actual_count="$(grep -c '^[[:space:]]*- name: Install autogov$' "$repo_root/.github/workflows/$installer_file")"
  [ "$actual_count" -eq "$expected_count" ] || fail "$installer_file has $actual_count installers, expected $expected_count"
  version_binding_count="$(grep -Fc "$version_binding" "$repo_root/.github/workflows/$installer_file")"
  repo_binding_count="$(grep -Fc "$repo_binding" "$repo_root/.github/workflows/$installer_file")"
  [ "$version_binding_count" -eq "$expected_count" ] || fail "$installer_file does not bind every installer to autogov-version"
  [ "$repo_binding_count" -eq "$expected_count" ] || fail "$installer_file does not bind every installer to autogov-repo"
  occurrence=1
  while [ "$occurrence" -le "$expected_count" ]; do
    candidate="$test_root/${installer_file%.yaml}-${occurrence}.sh"
    extract_run_block "$repo_root/.github/workflows/$installer_file" "Install autogov" "$occurrence" "$candidate"
    cmp "$canonical_install_script" "$candidate" || fail "$installer_file installer $occurrence differs from the executed canonical installer"
    occurrence=$((occurrence + 1))
  done
done <<'INSTALLERS'
rw-attest-blob-offline.yaml|2
rw-attest-blob.yaml|3
rw-attest-image.yaml|3
rw-verify-offline.yaml|1
rw-verify.yaml|1
INSTALLERS

[ "$(grep -Fc "$version_binding" "$workflow")" -eq 1 ] || fail 'release installer is not bound to autogov-version'
[ "$(grep -Fc 'AUTOGOV_REPO: liatrio/autogov' "$workflow")" -eq 1 ] || fail 'release installer is not bound to the trusted autogov repository'
[ "$(grep -Fc "$version_binding" "$repo_root/.github/actions/build-image/action.yaml")" -eq 1 ] || fail 'composite installer is not bound to autogov-version'
[ "$(grep -Fc "$repo_binding" "$repo_root/.github/actions/build-image/action.yaml")" -eq 1 ] || fail 'composite installer is not bound to autogov-repo'

run_normalize() {
  local vsa_ids="$1" blob_ids="$2" output="$3"
  local expected_vsa_count="${4:-0}" expected_blob_count="${5:-0}"
  : > "$output"
  env GITHUB_OUTPUT="$output" VSA_ARTIFACT_IDS="$vsa_ids" BLOB_ARTIFACT_IDS="$blob_ids" \
    EXPECTED_VSA_ARTIFACT_COUNT="$expected_vsa_count" \
    EXPECTED_BLOB_ARTIFACT_COUNT="$expected_blob_count" bash "$normalize_script"
}

normalization_output="$test_root/normalization-output"
run_normalize ' 101, ,202 ,,' ' , 303,404, ' "$normalization_output"
assert_contains "$normalization_output" 'vsa-artifact-ids=101,202'
assert_contains "$normalization_output" 'blob-artifact-ids=303,404'
run_normalize ' , , ' $'\t,  ' "$normalization_output"
assert_contains "$normalization_output" 'vsa-artifact-ids='
assert_contains "$normalization_output" 'blob-artifact-ids='
if run_normalize '101, ,' '303' "$test_root/count-output" 2 1 > "$test_root/count.log" 2>&1; then
  fail "missing required combined artifact output was accepted"
fi
assert_contains "$test_root/count.log" 'expected 2 VSA artifact IDs but received 1'
if run_normalize '101,not-an-id,202' '' "$test_root/malformed-output" > "$test_root/malformed.log" 2>&1; then
  fail "malformed artifact ID was accepted"
fi
assert_contains "$test_root/malformed.log" 'non-numeric artifact ID: not-an-id'

install_bin="$test_root/install-bin"
mkdir -p "$install_bin"
cat > "$install_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = api ]; then
  printf 'API %s\n' "$3" >> "$GH_CALLS"
  [ "$GH_SCENARIO" != api-failure ] || exit 17
  case "$3" in
    *'/releases?'*)
      case "$GH_SCENARIO" in
        sha-success) printf 'v1.3.0\ttrue\n' ;;
        hex-tag) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tfalse\n' ;;
        no-match) printf 'v1.3.0\tfalse\n' ;;
        multiple) printf 'v1.3.0\ttrue\nv1.3.1\ttrue\n' ;;
        api-tags-failure) printf 'v1.3.0\ttrue\n' ;;
        *) exit 18 ;;
      esac
      ;;
    *'/tags?'*)
      case "$GH_SCENARIO" in
        sha-success) printf 'v1.3.0\tff839e23f922e176897232c5b4148dc1d4c1b983\n' ;;
        no-match) printf 'v1.3.0\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
        multiple) printf 'v1.3.0\tcccccccccccccccccccccccccccccccccccccccc\nv1.3.1\tcccccccccccccccccccccccccccccccccccccccc\n' ;;
        api-tags-failure) exit 17 ;;
        *) exit 19 ;;
      esac
      ;;
    *) exit 2 ;;
  esac
elif [ "$1 $2" = 'release download' ]; then
  printf 'ARGS' >> "$GH_CALLS"
  printf ' %s' "$@" >> "$GH_CALLS"
  printf '\n' >> "$GH_CALLS"
  if [ "$3" = --repo ]; then
    printf 'DOWNLOAD <latest>\n' >> "$GH_CALLS"
  else
    printf 'DOWNLOAD %s\n' "$3" >> "$GH_CALLS"
  fi
  if [ "$GH_SCENARIO" = empty-binary ]; then
    : > autogov
  else
    cat > autogov <<'AUTOGOV'
#!/usr/bin/env bash
printf '%s\n' '{"next_version":"v9.9.9"}'
AUTOGOV
  fi
else
  exit 2
fi
STUB
cat > "$install_bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$SUDO_CALLS"
STUB
chmod +x "$install_bin/gh" "$install_bin/sudo"

run_install() {
  local script="$1" requested="$2" scenario="$3" label="$4" expected_result="$5" expected_download="${6:-}"
  local allow_download_on_failure="${7:-false}"
  local work="$test_root/install-$label" log="$test_root/$label.log"
  mkdir -p "$work"
  : > "$test_root/$label-gh-calls"; : > "$test_root/$label-sudo-calls"; : > "$test_root/$label-output"
  if (
    cd "$work"
    env PATH="$install_bin:$PATH" GH_TOKEN=test-token AUTOGOV_REPO=liatrio/autogov \
      AUTOGOV_VERSION="$requested" GH_SCENARIO="$scenario" GH_CALLS="$test_root/$label-gh-calls" \
      SUDO_CALLS="$test_root/$label-sudo-calls" GITHUB_OUTPUT="$test_root/$label-output" bash "$script"
  ) > "$log" 2>&1; then
    [ "$expected_result" = success ] || fail "$label unexpectedly succeeded"
    assert_contains "$test_root/$label-gh-calls" "DOWNLOAD $expected_download"
  else
    [ "$expected_result" = failure ] || fail "$label unexpectedly failed: $(cat "$log")"
    if [ "$allow_download_on_failure" != true ] && grep -Fq 'DOWNLOAD ' "$test_root/$label-gh-calls"; then
      fail "$label downloaded a release after resolver failure"
    fi
  fi
}

run_install "$canonical_install_script" ff839e23f922e176897232c5b4148dc1d4c1b983 sha-success canonical-sha success v1.3.0
run_install "$canonical_install_script" v1.2.3 tag canonical-tag success v1.2.3
if grep -Fq 'API ' "$test_root/canonical-tag-gh-calls"; then fail 'explicit non-hex tag unexpectedly called the resolver API'; fi
assert_contains "$test_root/canonical-tag-gh-calls" 'ARGS release download v1.2.3 --repo liatrio/autogov --pattern autogov'
run_install "$canonical_install_script" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa hex-tag canonical-hex-tag success aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if grep -Fq '/tags?' "$test_root/canonical-hex-tag-gh-calls"; then fail '40-hex published tag fell through to SHA resolution'; fi
run_install "$canonical_install_script" '' empty canonical-empty success '<latest>'
if grep -Fq 'API ' "$test_root/canonical-empty-gh-calls"; then fail 'empty latest-release input unexpectedly called the resolver API'; fi
run_install "$canonical_install_script" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb no-match canonical-no-match failure
assert_contains "$test_root/canonical-no-match.log" 'full 40-character SHA must identify exactly one immutable published release'
run_install "$canonical_install_script" cccccccccccccccccccccccccccccccccccccccc multiple canonical-multiple failure
assert_contains "$test_root/canonical-multiple.log" 'full 40-character SHA must identify exactly one immutable published release'
run_install "$canonical_install_script" dddddddddddddddddddddddddddddddddddddddd api-failure canonical-api-failure failure
run_install "$canonical_install_script" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee api-tags-failure canonical-tags-api-failure failure
run_install "$canonical_install_script" v1.2.3 empty-binary canonical-empty-binary failure v1.2.3 true
assert_contains "$test_root/canonical-empty-binary.log" 'downloaded autogov binary is empty'

# The release installer has a distinct privileged move suffix; execute it directly.
run_install "$install_script" ff839e23f922e176897232c5b4148dc1d4c1b983 sha-success release-sha success v1.3.0
expected_sudo_calls="$(printf '%s\n' mv autogov /usr/local/bin/autogov)"
[ "$(cat "$test_root/release-sha-sudo-calls")" = "$expected_sudo_calls" ] || fail 'release installer moved autogov to the wrong destination'
# The composite has a distinct latest-release/plan suffix; execute its empty-input path directly.
run_install "$composite_install_script" '' empty composite-empty success '<latest>'
assert_contains "$test_root/composite-empty-gh-calls" 'ARGS release download --repo liatrio/autogov --pattern autogov --clobber'

run_map() {
  env RUNNER_TEMP="$1" NORMALIZED_VSA_ARTIFACT_IDS="$2" NORMALIZED_BLOB_ARTIFACT_IDS="$3" \
    DRY_RUN="${4:-false}" bash "$map_script"
}

combined="$test_root/combined"
mkdir -p "$combined/release-artifacts/vsa/verification-summary-attestation-high-perms/nested" \
  "$combined/release-artifacts/vsa/verification-summary-attestation-low-perms/nested" "$combined/release-artifacts/blob/blob-assets/deep"
printf 'image\n' > "$combined/release-artifacts/vsa/verification-summary-attestation-high-perms/nested/vsa-PASSED.json"
printf 'offline-vsa\n' > "$combined/release-artifacts/vsa/verification-summary-attestation-low-perms/nested/vsa-PASSED.json"
printf 'bundle\n' > "$combined/release-artifacts/blob/blob-assets/deep/bundle.tar.gz"
: > "$combined/release-artifacts/blob/blob-assets/deep/empty.txt"
printf 'full\n' > "$combined/autogov.attestations.intoto.jsonl"
printf 'provenance\n' > "$combined/example.intoto.jsonl"
run_map "$combined" '101,202' '303'
mapped="$(tr '\0' '\n' < "$combined/release-asset-sources")"
expected="$(printf '%s\n' verification-summary-attestation-high-perms \
  "$combined/release-artifacts/vsa/verification-summary-attestation-high-perms" \
  verification-summary-attestation-low-perms \
  "$combined/release-artifacts/vsa/verification-summary-attestation-low-perms" \
  blob "$combined/release-artifacts/blob")"
[ "$mapped" = "$expected" ] || \
  fail "multi-artifact sources were not mapped by sorted semantic directory name"

single="$test_root/single"
mkdir -p "$single/release-artifacts/vsa/nested" "$single/release-artifacts/blob/deep"
printf 'vsa\n' > "$single/release-artifacts/vsa/nested/vsa-PASSED.json"
printf 'blob\n' > "$single/release-artifacts/blob/deep/bundle.tar.gz"
run_map "$single" '101' '303'
mapped="$(tr '\0' '\n' < "$single/release-asset-sources")"
expected="$(printf '%s\n' vsa "$single/release-artifacts/vsa" blob "$single/release-artifacts/blob")"
[ "$mapped" = "$expected" ] || \
  fail "single artifacts did not receive fixed class source IDs"

mkdir -p "$test_root/missing"
if run_map "$test_root/missing" '101' '' > "$test_root/missing.log" 2>&1; then
  fail "missing download directory was accepted"
fi
assert_contains "$test_root/missing.log" 'VSA download directory is missing'

missing_child="$test_root/missing-child"
mkdir -p "$missing_child/release-artifacts/vsa/verification-summary-attestation-high-perms"
printf 'vsa\n' > "$missing_child/release-artifacts/vsa/verification-summary-attestation-high-perms/vsa-PASSED.json"
if run_map "$missing_child" '101,102' '' > "$test_root/missing-child.log" 2>&1; then
  fail "two normalized IDs with one downloaded child source were accepted"
fi
assert_contains "$test_root/missing-child.log" 'expected 2 source artifact directories but found 1'

equals_source="$test_root/equals-source"
mkdir -p "$equals_source/release-artifacts/vsa/good-source" "$equals_source/release-artifacts/vsa/bad=source"
printf 'vsa\n' > "$equals_source/release-artifacts/vsa/good-source/vsa-PASSED.json"
printf 'vsa\n' > "$equals_source/release-artifacts/vsa/bad=source/vsa-PASSED.json"
if run_map "$equals_source" '101,102' '' > "$test_root/equals-source.log" 2>&1; then
  fail "artifact directory name containing '=' was accepted as a source ID"
fi
assert_contains "$test_root/equals-source.log" "artifact directory name cannot contain '=': 'bad=source'"

dry_run="$test_root/dry-run"
mkdir -p "$dry_run"
run_map "$dry_run" '101' '303' true
[ ! -s "$dry_run/release-asset-sources" ] || fail "dry run mapped intentionally skipped downloads"

stub_bin="$test_root/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/autogov" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo CALL >> "$AUTOGOV_CALLS"
printf '%s\n' "$@" >> "$AUTOGOV_ARGS"
printf '%s\n' '{"version":"v1.3.0","tag_name":"v1.3.0","commit_sha":"abc123","release_id":"42"}'
STUB
chmod +x "$stub_bin/autogov"

run_cut() {
  local runner_temp="$1" dry_run_value="$2" label="$3"
  local args="$test_root/$label-args" calls="$test_root/$label-calls" output="$test_root/$label-output"
  : > "$args"; : > "$calls"; : > "$output"
  (
    cd "$repo_root"
    env PATH="$stub_bin:$PATH" RUNNER_TEMP="$runner_temp" RELEASE_BRANCH=main \
      MUTATIONS_CONFIG=.autogov-release.yaml DRY_RUN="$dry_run_value" AUTOGOV_ARGS="$args" \
      AUTOGOV_CALLS="$calls" GITHUB_OUTPUT="$output" GITHUB_REPOSITORY=liatrio/example bash "$cut_script"
  )
  [ "$(grep -c '^CALL$' "$calls")" -eq 1 ] || fail "$label did not invoke one release cut"
  assert_arg_pair "$args" --mutations-config .autogov-release.yaml
  assert_contains "$output" 'version=v1.3.0'
}

run_cut "$combined" false combined
combined_args="$test_root/combined-args"
assert_arg_pair "$combined_args" --asset-source "verification-summary-attestation-high-perms=$combined/release-artifacts/vsa/verification-summary-attestation-high-perms"
assert_arg_pair "$combined_args" --asset-source "verification-summary-attestation-low-perms=$combined/release-artifacts/vsa/verification-summary-attestation-low-perms"
assert_arg_pair "$combined_args" --asset-source "blob=$combined/release-artifacts/blob"
assert_arg_pair "$combined_args" --asset "$combined/autogov.attestations.intoto.jsonl"
assert_arg_pair "$combined_args" --asset "$combined/example.intoto.jsonl"
assert_arg_pair "$combined_args" --asset cert-identities.json
assert_contains "$combined_args" '--publish'
grep -Fq -- 'empty.txt' "$combined_args" && fail "workflow rediscovered source files instead of passing directories"

run_cut "$dry_run" true dry-run
assert_contains "$test_root/dry-run-args" '--dry-run'
grep -Fq -- '--asset-source' "$test_root/dry-run-args" && fail "dry run received an artifact source"
assert_arg_pair "$test_root/dry-run-args" --asset cert-identities.json

echo 'rw-release asset wiring tests passed'
