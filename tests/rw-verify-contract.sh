#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
opa="${OPA_TEST_BINARY:-opa}"
policy_digest=08a6591d0a3629bae05f62c00c8ec38da3f7fb7cc2066312d46f2a9ca409862b
workflow_sha=69ae7bdc931567721161895d6245a27fbab2cd06
metadata_sha=df684349b4732c5cfe2fc9e40606de0213b13bb4

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_absent() { if grep -Fq -- "$2" "$1"; then fail "unexpected '$2' in $1"; fi; }

extract_run_block() {
  awk -v wanted="$2" '
    $0 == "      - name: " wanted { in_step = 1; next }
    in_step && $0 == "        run: |" { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { exit }
      print substr($0, 11)
    }
  ' "$1" > "$3"
  [ -s "$3" ] || fail "missing $2 run block"
  shellcheck --severity=warning -s bash "$3"
}

# Use the immutable published bundle, with its GitHub release asset digest.
# Load its Rego modules as the CLI does, alongside the workflow-generated data.
if [ -n "${POLICY_TEST_BUNDLE:-}" ]; then
  cp "$POLICY_TEST_BUNDLE" "$test_root/bundle.tar.gz"
else
  curl --fail --location --silent --show-error --retry 3 \
    https://github.com/liatrio/autogov-policy-library/releases/download/v1.1.7/bundle.tar.gz \
    --output "$test_root/bundle.tar.gz"
fi
printf '%s  %s\n' "$policy_digest" "$test_root/bundle.tar.gz" | sha256sum --check --strict -
mkdir "$test_root/policy" "$test_root/bin" "$test_root/fixtures"
tar -xzf "$test_root/bundle.tar.gz" -C "$test_root/policy"
policy="$test_root/policy/policies"

# These fakes are transport boundaries: execute the actual shell resolver and
# inspect every request, including authentication, pagination, and download args.
cat > "$test_root/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'OIDC request' >> "$CALL_LOG"
[[ "$*" == *"--proto =https"* ]] || exit 90
[[ "$*" == *"Authorization: bearer fixture-runner-credential"* ]] || exit 91
[ "${!#}" = 'https://oidc.example.test/token?job=fixture&audience=autogov-cert-identities' ] || exit 92
[ "${OIDC_FAILURE:-false}" = false ] || exit 22
cat "$FIXTURE_DIR/oidc-response.json"
SH
cat > "$test_root/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALL_LOG"
if [ "$1" = api ]; then
  [ "${API_FAILURE:-false}" = false ] || exit 24
  shift
  if [ "$1" = --paginate ]; then
    [ "$#" = 2 ] || exit 94
    endpoint="$2"
    case "$endpoint" in
      repos/*/releases\?per_page=100) fixture=releases ;;
      repos/*/tags\?per_page=100) fixture=tags ;;
      *) exit 93 ;;
    esac
    # gh --paginate emits each response page as a separate JSON array.
    jq -c '.[]' "$FIXTURE_DIR/$fixture.json"
  else
    [ "$1" = 'repos/example/security/contents/cert-identities.json' ] || exit 95
    [ "$2" = --jq ] && [ "$3" = .content ] || exit 96
    base64 < "$FIXTURE_DIR/override.json"
  fi
elif [ "$1" = release ] && [ "$2" = download ]; then
  [ "$3" = v1.1.5 ] && [ "$4" = --repo ] || exit 97
  [ "${5,,}" = liatrio/autogov-workflows ] || exit 98
  [ "$6" = --pattern ] && [ "$7" = cert-identities.json ] || exit 99
  [ "${DOWNLOAD_FAILURE:-false}" = false ] || exit 23
  cp "$FIXTURE_DIR/release-allowlist.json" cert-identities.json
else
  exit 100
fi
SH
chmod +x "$test_root/bin/curl" "$test_root/bin/gh"
shellcheck -s bash "$test_root/bin/curl" "$test_root/bin/gh"

export FIXTURE_DIR="$test_root/fixtures"
export ACTIONS_ID_TOKEN_REQUEST_TOKEN=fixture-runner-credential
export ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example.test/token?job=fixture'
# Caller identity deliberately differs from the called release in every case.
export GITHUB_REPOSITORY=external-org/application
export GITHUB_SHA=1111111111111111111111111111111111111111
export GH_REPO="$GITHUB_REPOSITORY" JOB_WF_SHA="$GITHUB_SHA"

write_oidc_response() {
  local payload
  payload="$(jq -c . "$FIXTURE_DIR/claims.json" | base64 | tr -d '\n=' | tr '+/' '-_')"
  jq -n --arg value "eyJhbGciOiJSUzI1NiJ9.$payload.fixture-signature" '{value:$value}' > "$FIXTURE_DIR/oidc-response.json"
}

reset_fixtures() {
  local filename="$1" digest
  jq -n --arg sha "$workflow_sha" '{identities:[{version:"1.1.5",sha:$sha,status:"latest",identities:[("https://github.com/liatrio/autogov-workflows/.github/workflows/rw-attest-image.yaml@"+$sha)]}]}' > "$FIXTURE_DIR/release-allowlist.json"
  printf '%s\n' '{"identities":[{"version":"override"}]}' > "$FIXTURE_DIR/override.json"
  digest="$(sha256sum "$FIXTURE_DIR/release-allowlist.json")"
  digest="${digest%% *}"
  # v1.1.5's actual annotated tag peels to workflow_sha, not metadata_sha.
  # Empty first pages ensure resolution does not silently inspect one page only.
  jq -n --arg sha "$workflow_sha" '[[],[{name:"v1.1.5",commit:{sha:$sha}}]]' > "$FIXTURE_DIR/tags.json"
  jq -n --arg digest "sha256:$digest" '[[],[{id:15,tag_name:"v1.1.5",target_commitish:"main",draft:false,immutable:true,assets:[{name:"cert-identities.json",digest:$digest}]}]]' > "$FIXTURE_DIR/releases.json"
  jq -n --arg sha "$workflow_sha" --arg filename "$filename" --arg caller_sha "$GITHUB_SHA" '{iss:"https://token.actions.githubusercontent.com",aud:"autogov-cert-identities",repository:"external-org/application",workflow_sha:$caller_sha,job_workflow_ref:("liatrio/autogov-workflows/.github/workflows/"+$filename+"@refs/tags/v1.1.5"),job_workflow_sha:$sha}' > "$FIXTURE_DIR/claims.json"
  write_oidc_response
  export CERT_IDENTITIES_REPO=liatrio/autogov-workflows
  export OIDC_FAILURE=false DOWNLOAD_FAILURE=false API_FAILURE=false
}

mutate_fixture() {
  jq "$2" "$FIXTURE_DIR/$1.json" > "$FIXTURE_DIR/changed.json"
  mv "$FIXTURE_DIR/changed.json" "$FIXTURE_DIR/$1.json"
  if [ "$1" = claims ]; then write_oidc_response; fi
}

run_resolver() {
  local name="$1" expected="$2" status=0
  mkdir "$case_root/$name"
  export CALL_LOG="$case_root/$name/calls.log"
  : > "$CALL_LOG"
  (cd "$case_root/$name" && PATH="$test_root/bin:$PATH" bash "$resolver") > "$case_root/$name/output.log" 2>&1 || status=$?
  if [ "$expected" = pass ]; then
    [ "$status" -eq 0 ] || { cat "$case_root/$name/output.log"; fail "$filename/$name failed"; }
  else
    [ "$status" -ne 0 ] || fail "$filename/$name unexpectedly passed"
    assert_absent "$CALL_LOG" /contents/
  fi
  assert_absent "$case_root/$name/output.log" fixture-runner-credential
  assert_absent "$case_root/$name/output.log" fixture-signature
}

run_overlay() {
  local name="$1" overlay="$2" expected="$3" status=0
  mkdir "$case_root/$name"
  (cd "$case_root/$name" && VULN_CRITICAL=0 VULN_HIGH=1 VULN_MEDIUM=2 VULN_LOW=-1 OVERLAY="$overlay" bash -e "$generator") > "$case_root/$name/output.log" 2>&1 || status=$?
  if [ "$expected" = pass ]; then
    [ "$status" -eq 0 ] || fail "$filename/$name failed"
    jq -e '.vuln_thresholds == {critical:0,high:1,medium:2,low:-1}' "$case_root/$name/policy-data.json" >/dev/null || fail 'vulnerability thresholds changed'
  else
    [ "$status" -ne 0 ] || fail "$filename/$name unexpectedly passed"
  fi
}

documented_overlay="$(sed -n "s/^policy-data-overlay: '\(.*\)'$/\1/p" "$repo_root/README.md")"
[ -n "$documented_overlay" ] || fail 'missing copyable README overlay example'

for filename in rw-verify.yaml rw-verify-offline.yaml; do
  workflow="$repo_root/.github/workflows/$filename"
  case_root="$test_root/$filename"
  mkdir "$case_root"
  resolver="$case_root/resolver.sh"
  generator="$case_root/generator.sh"
  extract_run_block "$workflow" 'Download cert-identities file' "$resolver"
  extract_run_block "$workflow" 'Generate Vulnerability Threshold Config' "$generator"
  assert_contains "$workflow" 'per-repo gates such as source_review_thresholds /'
  assert_absent "$workflow" 'github.job_workflow_sha'

  reset_fixtures "$filename"
  run_resolver external-caller pass
  assert_contains "$CALL_LOG" 'release download v1.1.5 --repo liatrio/autogov-workflows --pattern cert-identities.json'
  assert_absent "$CALL_LOG" /contents/
  assert_absent "$CALL_LOG" external-org/application
  jq -e --arg sha "$workflow_sha" '.identities[0].sha == $sha' "$case_root/external-caller/cert-identities.json" >/dev/null

  reset_fixtures "$filename"
  mutate_fixture claims '.job_workflow_ref = ((.job_workflow_ref | split("@")[0]) + "@" + .job_workflow_sha)'
  run_resolver sha-pinned-caller pass
  assert_absent "$CALL_LOG" /contents/

  reset_fixtures "$filename"
  export CERT_IDENTITIES_REPO=Liatrio/AutoGov-Workflows
  run_resolver repo-case pass
  assert_absent "$CALL_LOG" /contents/

  reset_fixtures "$filename"
  export CERT_IDENTITIES_REPO=example/security
  run_resolver cross-repo-override pass
  assert_contains "$CALL_LOG" 'api repos/example/security/contents/cert-identities.json --jq .content'
  assert_absent "$CALL_LOG" 'release download'
  assert_absent "$CALL_LOG" '/releases?'
  cmp "$FIXTURE_DIR/override.json" "$case_root/cross-repo-override/cert-identities.json"

  reset_fixtures "$filename"
  mutate_fixture claims "del(.job_workflow_sha)"
  run_resolver missing-sha fail
  assert_absent "$CALL_LOG" 'api '

  reset_fixtures "$filename"
  mutate_fixture claims 'del(.job_workflow_ref)'
  run_resolver missing-ref fail

  reset_fixtures "$filename"
  mutate_fixture claims '.job_workflow_sha = "refs/heads/main"'
  run_resolver invalid-sha fail

  reset_fixtures "$filename"
  mutate_fixture claims '.job_workflow_ref = "liatrio/autogov-workflows@main"'
  run_resolver invalid-ref fail

  reset_fixtures "$filename"
  printf '%s\n' '{"value":"invalid.jwt"}' > "$FIXTURE_DIR/oidc-response.json"
  run_resolver malformed-token fail

  reset_fixtures "$filename"
  mutate_fixture claims '.aud = "other-audience"'
  run_resolver wrong-audience fail

  reset_fixtures "$filename"
  mutate_fixture claims '.iss = "https://other.example.test"'
  run_resolver wrong-issuer fail

  reset_fixtures "$filename"
  export OIDC_FAILURE=true
  run_resolver oidc-permission-denied fail
  assert_absent "$CALL_LOG" 'api '

  reset_fixtures "$filename"
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run_resolver missing-oidc-permission fail
  assert_absent "$CALL_LOG" 'api '
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=fixture-runner-credential

  reset_fixtures "$filename"
  export API_FAILURE=true
  run_resolver release-api-denied fail

  reset_fixtures "$filename"
  mutate_fixture claims ".job_workflow_sha = \"$metadata_sha\""
  run_resolver release-metadata-commit fail
  assert_absent "$CALL_LOG" 'release download'

  reset_fixtures "$filename"
  mutate_fixture releases '.[1][0].immutable = false'
  run_resolver mutable-release fail

  reset_fixtures "$filename"
  mutate_fixture releases '.[1][0].draft = true'
  run_resolver draft-release fail

  reset_fixtures "$filename"
  mutate_fixture releases '.[1] += [.[1][0] | .id = 16 | .tag_name = "v1.1.5-alias"]'
  mutate_fixture tags '.[1] += [.[1][0] | .name = "v1.1.5-alias"]'
  run_resolver ambiguous-release fail

  reset_fixtures "$filename"
  mutate_fixture releases '.[1][0].assets = []'
  run_resolver missing-asset fail

  reset_fixtures "$filename"
  mutate_fixture releases '.[1][0].assets[0].digest = null'
  run_resolver missing-digest fail

  reset_fixtures "$filename"
  printf '%s\n' '{"tampered":true}' > "$FIXTURE_DIR/release-allowlist.json"
  run_resolver digest-mismatch fail

  reset_fixtures "$filename"
  export DOWNLOAD_FAILURE=true
  run_resolver download-failure fail

  run_overlay empty-overlay '' pass
  "$opa" eval --format raw --data "$policy" --data "$case_root/empty-overlay/policy-data.json" \
    '[data.security.source_review.allow, data.source_review_config.min_approvals]' > "$case_root/default-result.json"
  jq -e '. == [true,1]' "$case_root/default-result.json" >/dev/null || fail 'released default contract changed'

  run_overlay documented-overlay "$documented_overlay" pass
  "$opa" eval --format raw --data "$policy" --data "$case_root/documented-overlay/policy-data.json" \
    '[data.security.source_review.allow, data.security.source_review.violations, data.source_review_config.min_approvals]' > "$case_root/overlay-result.json"
  jq -e '. == [false,["source-review attestation is missing"],2]' "$case_root/overlay-result.json" >/dev/null || fail 'released policy did not consume documented overlay'

  run_overlay disjoint-overlay '{"source_review_thresholds":{"min_approvals":2},"code_scan_thresholds":{"max_critical":0}}' pass
  jq -e '.code_scan_thresholds.max_critical == 0' "$case_root/disjoint-overlay/policy-data.json" >/dev/null
  run_overlay malformed-json '{' fail
  run_overlay array-json '[]' fail
  run_overlay null-json 'null' fail
  run_overlay string-json '"text"' fail
  run_overlay forbidden-thresholds '{"vuln_thresholds":{"critical":-1}}' fail
  run_overlay forbidden-null-thresholds '{"vuln_thresholds":null}' fail

  run_overlay old-key '{"source_review_config":{"require_source_review":true,"min_approvals":2}}' pass
  if "$opa" eval --format json --data "$policy" --data "$case_root/old-key/policy-data.json" \
    'data.security.source_review.allow' > "$case_root/old-key-result.json"; then
    fail 'old package-name overlay unexpectedly compiled'
  fi
  jq -e '.errors | any(.code == "rego_compile_error" and (.message | contains("conflicting rule")))' "$case_root/old-key-result.json" >/dev/null

  echo "$filename: allowlist binding and released-policy overlay regressions passed"
done
