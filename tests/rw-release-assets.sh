#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/rw-release.yaml"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

extract_run_block() {
  local step_name="$1"
  local output="$2"

  awk -v wanted="$step_name" '
    function indentation(line) {
      match(line, /[^ ]/)
      return RSTART == 0 ? length(line) : RSTART - 1
    }
    $0 == "      - name: " wanted {
      in_step = 1
      next
    }
    in_step && $0 == "        run: |" {
      in_run = 1
      run_indent = 8
      next
    }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) {
        print ""
        next
      }
      if (indentation($0) <= run_indent) {
        exit
      }
      print substr($0, run_indent + 3)
    }
    in_step && $0 ~ /^      - name:/ {
      exit
    }
  ' "$workflow" > "$output"

  [ -s "$output" ] || fail "could not extract run block for '$step_name'"
  bash -n "$output"
}

normalize_script="$test_root/normalize.sh"
stage_script="$test_root/stage.sh"
cut_script="$test_root/cut.sh"
extract_run_block "Normalize release artifact IDs" "$normalize_script"
extract_run_block "Stage release assets" "$stage_script"
extract_run_block "Run release cut" "$cut_script"

run_normalize() {
  local vsa_ids="$1"
  local blob_ids="$2"
  local output="$3"
  local expected_vsa_count="${4:-0}"
  local expected_blob_count="${5:-0}"

  : > "$output"
  env \
    GITHUB_OUTPUT="$output" \
    VSA_ARTIFACT_IDS="$vsa_ids" \
    BLOB_ARTIFACT_IDS="$blob_ids" \
    EXPECTED_VSA_ARTIFACT_COUNT="$expected_vsa_count" \
    EXPECTED_BLOB_ARTIFACT_COUNT="$expected_blob_count" \
    bash "$normalize_script"
}

normalization_output="$test_root/normalization-output"
run_normalize ' 101, ,202 ,,' ' , 303,404, ' "$normalization_output"
assert_contains "$normalization_output" 'vsa-artifact-ids=101,202'
assert_contains "$normalization_output" 'blob-artifact-ids=303,404'

run_normalize ' , , ' $'\t,  ' "$normalization_output"
assert_contains "$normalization_output" 'vsa-artifact-ids='
assert_contains "$normalization_output" 'blob-artifact-ids='

missing_required_log="$test_root/missing-required.log"
if run_normalize '101, ,' '303' "$test_root/missing-required-output" 2 1 > "$missing_required_log" 2>&1; then
  fail "missing required combined artifact output was accepted"
fi
assert_contains "$missing_required_log" 'expected 2 VSA artifact IDs but received 1'

malformed_log="$test_root/malformed.log"
if env \
  GITHUB_OUTPUT="$test_root/malformed-output" \
  VSA_ARTIFACT_IDS='101,not-an-id,202' \
  BLOB_ARTIFACT_IDS='' \
  EXPECTED_VSA_ARTIFACT_COUNT='0' \
  EXPECTED_BLOB_ARTIFACT_COUNT='0' \
  bash "$normalize_script" > "$malformed_log" 2>&1; then
  fail "malformed artifact ID was accepted"
fi
assert_contains "$malformed_log" 'non-numeric artifact ID: not-an-id'

run_stage() {
  local runner_temp="$1"
  local vsa_ids="$2"
  local blob_ids="$3"

  env \
    RUNNER_TEMP="$runner_temp" \
    GITHUB_REPOSITORY='liatrio/example' \
    NORMALIZED_VSA_ARTIFACT_IDS="$vsa_ids" \
    NORMALIZED_BLOB_ARTIFACT_IDS="$blob_ids" \
    DRY_RUN='false' \
    bash "$stage_script"
}

create_combined_downloads() {
  local runner_temp="$1"
  local order="$2"
  local first_source='image-vsa'
  local second_source='blob-vsa'

  if [ "$order" == 'blob-first' ]; then
    first_source='blob-vsa'
    second_source='image-vsa'
  fi
  mkdir -p "$runner_temp/release-artifacts/vsa/$first_source/nested"
  printf '%s\n' "$first_source" > "$runner_temp/release-artifacts/vsa/$first_source/nested/vsa-PASSED.json"
  mkdir -p "$runner_temp/release-artifacts/vsa/$second_source/nested"
  printf '%s\n' "$second_source" > "$runner_temp/release-artifacts/vsa/$second_source/nested/vsa-PASSED.json"
  mkdir -p "$runner_temp/release-artifacts/blob/blob-assets/deep"
  printf 'bundle\n' > "$runner_temp/release-artifacts/blob/blob-assets/deep/bundle.tar.gz"
  : > "$runner_temp/release-artifacts/blob/blob-assets/deep/empty.txt"
  printf 'full-attestations\n' > "$runner_temp/autogov.attestations.intoto.jsonl"
  printf 'provenance\n' > "$runner_temp/example.intoto.jsonl"
}

combined_image_first="$test_root/combined-image-first"
create_combined_downloads "$combined_image_first" image-first
run_stage "$combined_image_first" '101,202' '303'
assert_file "$combined_image_first/staged-release-assets/image-vsa--vsa-PASSED.json"
assert_file "$combined_image_first/staged-release-assets/blob-vsa--vsa-PASSED.json"
assert_file "$combined_image_first/staged-release-assets/bundle.tar.gz"
assert_file "$combined_image_first/staged-release-assets/autogov.attestations.intoto.jsonl"
assert_file "$combined_image_first/staged-release-assets/example.intoto.jsonl"
[ ! -e "$combined_image_first/staged-release-assets/empty.txt" ] || fail "empty downloaded file was staged"

combined_blob_first="$test_root/combined-blob-first"
create_combined_downloads "$combined_blob_first" blob-first
run_stage "$combined_blob_first" '101,202' '303'
(
  cd "$combined_image_first/staged-release-assets"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$test_root/image-first-assets"
(
  cd "$combined_blob_first/staged-release-assets"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$test_root/blob-first-assets"
cmp "$test_root/image-first-assets" "$test_root/blob-first-assets" || fail "completion order changed staged assets"

single_path="$test_root/single-path"
mkdir -p "$single_path/release-artifacts/vsa/image-vsa/nested"
printf 'single-vsa\n' > "$single_path/release-artifacts/vsa/image-vsa/nested/vsa-PASSED.json"
run_stage "$single_path" '101' ''
assert_file "$single_path/staged-release-assets/vsa-PASSED.json"

empty_optional="$test_root/empty-optional"
mkdir -p "$empty_optional"
run_stage "$empty_optional" '' ''
[ -d "$empty_optional/staged-release-assets" ] || fail "empty optional IDs did not produce a valid empty staging directory"

missing_expected_log="$test_root/missing-expected.log"
mkdir -p "$test_root/missing-expected"
if run_stage "$test_root/missing-expected" '101' '' > "$missing_expected_log" 2>&1; then
  fail "missing expected VSA files were accepted"
fi
assert_contains "$missing_expected_log" 'expected 1 source artifact directories but found 0'

missing_source="$test_root/missing-source"
mkdir -p "$missing_source/release-artifacts/vsa/only-one-source"
printf 'vsa\n' > "$missing_source/release-artifacts/vsa/only-one-source/vsa-PASSED.json"
missing_source_log="$test_root/missing-source.log"
if run_stage "$missing_source" '101,102' '' > "$missing_source_log" 2>&1; then
  fail "a missing source artifact directory was accepted"
fi
assert_contains "$missing_source_log" 'expected 2 source artifact directories but found 1'

duplicate_blob="$test_root/duplicate-blob"
mkdir -p \
  "$duplicate_blob/release-artifacts/blob/first/nested" \
  "$duplicate_blob/release-artifacts/blob/second/other"
printf 'first\n' > "$duplicate_blob/release-artifacts/blob/first/nested/archive.tar.gz"
printf 'second\n' > "$duplicate_blob/release-artifacts/blob/second/other/archive.tar.gz"
duplicate_blob_log="$test_root/duplicate-blob.log"
if run_stage "$duplicate_blob" '' '301,302' > "$duplicate_blob_log" 2>&1; then
  fail "duplicate non-VSA basename was accepted"
fi
assert_contains "$duplicate_blob_log" "$duplicate_blob/release-artifacts/blob/first/nested/archive.tar.gz"
assert_contains "$duplicate_blob_log" "$duplicate_blob/release-artifacts/blob/second/other/archive.tar.gz"

duplicate_non_vsa="$test_root/duplicate-non-vsa"
mkdir -p \
  "$duplicate_non_vsa/release-artifacts/vsa/first" \
  "$duplicate_non_vsa/release-artifacts/vsa/second"
printf 'first\n' > "$duplicate_non_vsa/release-artifacts/vsa/first/notes.txt"
printf 'second\n' > "$duplicate_non_vsa/release-artifacts/vsa/second/notes.txt"
duplicate_non_vsa_log="$test_root/duplicate-non-vsa.log"
if run_stage "$duplicate_non_vsa" '101,102' '' > "$duplicate_non_vsa_log" 2>&1; then
  fail "duplicate non-VSA file in VSA artifacts was namespaced instead of rejected"
fi
assert_contains "$duplicate_non_vsa_log" "$duplicate_non_vsa/release-artifacts/vsa/first/notes.txt"
assert_contains "$duplicate_non_vsa_log" "$duplicate_non_vsa/release-artifacts/vsa/second/notes.txt"

ambiguous_vsa="$test_root/ambiguous-vsa"
mkdir -p \
  "$ambiguous_vsa/release-artifacts/vsa/image vsa" \
  "$ambiguous_vsa/release-artifacts/vsa/image@vsa"
printf 'first\n' > "$ambiguous_vsa/release-artifacts/vsa/image vsa/vsa-PASSED.json"
printf 'second\n' > "$ambiguous_vsa/release-artifacts/vsa/image@vsa/vsa-PASSED.json"
ambiguous_vsa_log="$test_root/ambiguous-vsa.log"
if run_stage "$ambiguous_vsa" '101,102' '' > "$ambiguous_vsa_log" 2>&1; then
  fail "ambiguous duplicate VSA namespace was accepted"
fi
assert_contains "$ambiguous_vsa_log" "$ambiguous_vsa/release-artifacts/vsa/image vsa/vsa-PASSED.json"
assert_contains "$ambiguous_vsa_log" "$ambiguous_vsa/release-artifacts/vsa/image@vsa/vsa-PASSED.json"

tracked_collision="$test_root/tracked-collision"
mkdir -p "$tracked_collision/release-artifacts/blob/blob-assets"
printf 'downloaded\n' > "$tracked_collision/release-artifacts/blob/blob-assets/cert-identities.json"
tracked_collision_log="$test_root/tracked-collision.log"
if run_stage "$tracked_collision" '' '301' > "$tracked_collision_log" 2>&1; then
  fail "downloaded/tracked basename collision was accepted"
fi
assert_contains "$tracked_collision_log" "$tracked_collision/release-artifacts/blob/blob-assets/cert-identities.json"
assert_contains "$tracked_collision_log" 'cert-identities.json'

generated_collision="$test_root/generated-collision"
mkdir -p "$generated_collision/release-artifacts/blob/blob-assets"
printf 'downloaded\n' > "$generated_collision/release-artifacts/blob/blob-assets/autogov.attestations.intoto.jsonl"
printf 'generated\n' > "$generated_collision/autogov.attestations.intoto.jsonl"
generated_collision_log="$test_root/generated-collision.log"
if run_stage "$generated_collision" '' '301' > "$generated_collision_log" 2>&1; then
  fail "downloaded/generated basename collision was accepted"
fi
assert_contains "$generated_collision_log" "$generated_collision/release-artifacts/blob/blob-assets/autogov.attestations.intoto.jsonl"
assert_contains "$generated_collision_log" "$generated_collision/autogov.attestations.intoto.jsonl"

dry_run_stage="$test_root/dry-run-stage"
mkdir -p "$dry_run_stage"
env \
  RUNNER_TEMP="$dry_run_stage" \
  GITHUB_REPOSITORY='liatrio/example' \
  NORMALIZED_VSA_ARTIFACT_IDS='101' \
  NORMALIZED_BLOB_ARTIFACT_IDS='301' \
  DRY_RUN='true' \
  bash "$stage_script"
assert_file "$dry_run_stage/staged-release-assets/cert-identities.json"

stub_bin="$test_root/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/autogov" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo CALL >> "$AUTOGOV_CALLS"
printf '%s\n' "$@" >> "$AUTOGOV_ARGS"
printf '%s\n' '{"version":"v1.2.3","tag_name":"v1.2.3","commit_sha":"abc123","release_id":"42"}'
STUB
chmod +x "$stub_bin/autogov"

run_published_cut() {
  local runner_temp="$1"
  local label="$2"
  local autogov_calls="$test_root/${label}-autogov-calls"
  local autogov_args="$test_root/${label}-autogov-args"
  local cut_output="$test_root/${label}-cut-output"

  : > "$autogov_calls"
  : > "$autogov_args"
  : > "$cut_output"
  env \
    PATH="$stub_bin:$PATH" \
    RUNNER_TEMP="$runner_temp" \
    RELEASE_BRANCH='main' \
    MUTATIONS_CONFIG='.autogov-release.yaml' \
    DRY_RUN='false' \
    AUTOGOV_CALLS="$autogov_calls" \
    AUTOGOV_ARGS="$autogov_args" \
    GITHUB_OUTPUT="$cut_output" \
    bash "$cut_script"

  [ "$(grep -c '^CALL$' "$autogov_calls")" -eq 1 ] || fail "${label} release cut was not invoked exactly once"
  assert_contains "$autogov_args" '--mutations-config'
  assert_contains "$autogov_args" '.autogov-release.yaml'
  assert_contains "$autogov_args" '--publish'
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/image-vsa--vsa-PASSED.json"
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/blob-vsa--vsa-PASSED.json"
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/bundle.tar.gz"
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/autogov.attestations.intoto.jsonl"
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/example.intoto.jsonl"
  assert_contains "$autogov_args" "$runner_temp/staged-release-assets/cert-identities.json"
  if grep -Fq -- "$runner_temp/staged-release-assets/empty.txt" "$autogov_args"; then
    fail "${label} release cut received an empty asset"
  fi
  assert_contains "$cut_output" 'version=v1.2.3'
  assert_contains "$cut_output" 'tag=v1.2.3'
  assert_contains "$cut_output" 'commit-sha=abc123'
  assert_contains "$cut_output" 'release-id=42'
}

run_published_cut "$combined_image_first" image-first
run_published_cut "$combined_blob_first" blob-first

autogov_calls="$test_root/dry-run-autogov-calls"
autogov_args="$test_root/dry-run-autogov-args"
cut_output="$test_root/dry-run-cut-output"
: > "$autogov_calls"
: > "$autogov_args"
: > "$cut_output"
env \
  PATH="$stub_bin:$PATH" \
  RUNNER_TEMP="$dry_run_stage" \
  RELEASE_BRANCH='main' \
  MUTATIONS_CONFIG='.autogov-release.yaml' \
  DRY_RUN='true' \
  AUTOGOV_CALLS="$autogov_calls" \
  AUTOGOV_ARGS="$autogov_args" \
  GITHUB_OUTPUT="$cut_output" \
  bash "$cut_script"
[ "$(grep -c '^CALL$' "$autogov_calls")" -eq 1 ] || fail "dry-run release cut was not invoked exactly once"
assert_contains "$autogov_args" '--dry-run'
if grep -Fxq -- '--publish' "$autogov_args"; then
  fail "dry-run release cut included --publish"
fi
assert_contains "$autogov_args" "$dry_run_stage/staged-release-assets/cert-identities.json"

echo 'rw-release asset regression tests passed'
