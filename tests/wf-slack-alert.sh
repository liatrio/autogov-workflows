#!/usr/bin/env bash
# Run the actual workflow script without GitHub requests, git reads, or Slack sends.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$repo_root/.github/workflows/wf-slack-alert.yaml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Ruby's YAML reader avoids reimplementing YAML block-scalar extraction.
ruby -ryaml -e '
  workflow = YAML.load_file(ARGV.fetch(0))
  trigger = workflow.fetch("on") { workflow.fetch(true) }.fetch("workflow_run")
  abort "Expected main-only completed runs" unless trigger.fetch("branches") == "main" &&
    trigger.fetch("types") == ["completed"]
  allowed = [["Release Caller Workflow"], ["Build Blob Caller Workflow", "Build Image Caller Workflow"]]
  abort "Unexpected watched workflows" unless allowed.include?(trigger.fetch("workflows"))
  abort "Expected empty workflow permissions" unless workflow.fetch("permissions") == {}
  job = workflow.fetch("jobs").fetch("alert")
  abort "Expected actions read only" unless job.fetch("permissions") == {"actions" => "read"}
  abort "Expected failure-only job" unless job.fetch("if") == "$" + "{{ github.event.workflow_run.conclusion == \u0027failure\u0027 }}"
  steps = job.fetch("steps")
  abort "Expected one trusted inline script, without checkout" unless steps.length == 1 &&
    steps.first.key?("run") && !steps.first.key?("uses")
  print steps.first.fetch("run")
' "$workflow" > "$tmp/alert.sh"
shellcheck -s bash "$tmp/alert.sh"

mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo called >> "$MOCK_DIR/gh.calls"
jq -n --args '$ARGS.positional' -- "$@" > "$MOCK_DIR/gh.args"
if [ "$MOCK_GH_STATUS" -ne 0 ]; then
  echo "mock GitHub lookup failed" >&2
  exit "$MOCK_GH_STATUS"
fi
cat "$MOCK_DIR/jobs.json"
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo called >> "$MOCK_DIR/curl.calls"
jq -n --args '$ARGS.positional' -- "$@" > "$MOCK_DIR/curl.args"
cat > "$MOCK_DIR/payload.json"
if [ "$MOCK_CURL_STATUS" -ne 0 ]; then
  echo "curl: (22) mock HTTP 500" >&2
fi
exit "$MOCK_CURL_STATUS"
MOCK
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "Unexpected git access" > "$MOCK_DIR/git.called"
exit 99
MOCK
chmod +x "$tmp/bin/gh" "$tmp/bin/curl" "$tmp/bin/git"
shellcheck -s bash "$tmp/bin/gh" "$tmp/bin/curl" "$tmp/bin/git"

cat > "$tmp/original-event.json" <<'JSON'
{
  "workflow_run": {
    "id": 123,
    "html_url": "https://github.example.test/org/repo/actions/runs/123",
    "head_sha": "111111122222223333333444444455555556666666",
    "head_commit": {
      "message": "Fix \"quoted\" path C:\\build\\src\nSecond line with $(touch should-not-exist) and \u0060literal\u0060\n"
    },
    "actor": {"login": "original-author"},
    "triggering_actor": {"login": "rerun-user"}
  }
}
JSON
cat > "$tmp/original-jobs.json" <<'JSON'
{
  "jobs": [
    {
      "databaseId": 950,
      "conclusion": "failure",
      "steps": [{"number": 1, "conclusion": "failure", "name": "Other failed job"}]
    },
    {
      "databaseId": 800,
      "conclusion": "success",
      "steps": [{"number": 1, "conclusion": "success", "name": "Successful job"}]
    },
    {
      "databaseId": 900,
      "conclusion": "failure",
      "steps": [
        {"number": 5, "conclusion": "failure", "name": "Later failed step"},
        {"number": 1, "conclusion": "success", "name": "Successful step"},
        {"number": 2, "conclusion": "failure", "name": "Build \"quoted\" C:\\tmp\nline two $(echo literal)\n"}
      ]
    }
  ]
}
JSON

export PATH="$tmp/bin:$PATH"
export MOCK_DIR="$tmp"
export GITHUB_EVENT_PATH="$tmp/event.json"
export GITHUB_REPOSITORY="org/repo"
export GITHUB_SERVER_URL="https://github.example.test"
# The default branch moved after the failed run. Neither value is run metadata.
export GITHUB_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export GITHUB_ACTOR="default-branch-actor"
export GITHUB_REF_NAME="main"
export GH_TOKEN="test-token"

reset_case() {
  rm -f "$tmp/gh.calls" "$tmp/curl.calls" "$tmp/payload.json" "$tmp/git.called"
  cp "$tmp/original-event.json" "$GITHUB_EVENT_PATH"
  cp "$tmp/original-jobs.json" "$tmp/jobs.json"
  export MOCK_GH_STATUS=0 MOCK_CURL_STATUS=0
  # Spaces also prove that the webhook remains a single quoted curl argument.
  export SLACK_WEBHOOK="https://slack.invalid/mock?value=one two&literal=three"
}

run_alert() {
  bash "$tmp/alert.sh" > "$tmp/output.log" 2>&1
}

assert_one_request() {
  [ "$(wc -l < "$tmp/gh.calls" | tr -d ' ')" = 1 ] || fail "expected one GitHub lookup"
  [ "$(wc -l < "$tmp/curl.calls" | tr -d ' ')" = 1 ] || fail "expected one Slack request"
  [ ! -e "$tmp/git.called" ] || fail "notification read the default branch commit"
  jq -e '. == ["run", "view", "123", "--repo", "org/repo", "--json", "jobs"]' \
    "$tmp/gh.args" > /dev/null || fail "incorrect GitHub query"
  jq -e --arg webhook "$SLACK_WEBHOOK" \
    '. == ["--fail", "--silent", "--show-error", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@-", $webhook]' \
    "$tmp/curl.args" > /dev/null || fail "curl must surface HTTP errors and quote the webhook"
  jq -e '.attachments | length == 1' "$tmp/payload.json" > /dev/null ||
    fail "invalid Slack JSON"
}

assert_fallback() {
  jq -e '.attachments[0].blocks as $blocks |
    $blocks[1].fields[1].text == "Failed Step:\nunknown" and
    $blocks[4].fields[0].text ==
      "<https://github.example.test/org/repo/actions/runs/123|❌ View Failed Run>"' \
    "$tmp/payload.json" > /dev/null || fail "expected unknown step and run-level link"
}

reset_case
run_alert || fail "normal notification failed"
assert_one_request
jq -e --slurpfile event "$tmp/original-event.json" --slurpfile jobs "$tmp/original-jobs.json" '
  .attachments[0] as $attachment | $attachment.blocks as $blocks |
  $attachment.color == "#FF0000" and
  $blocks[0].text.text == "🚨 Pipeline Failure" and
  $blocks[1].fields[0].text == "Repository:\norg/repo" and
  $blocks[1].fields[1].text == ("Failed Step:\n" + $jobs[0].jobs[2].steps[2].name) and
  $blocks[2].fields[0].text == "Triggered By:\nrerun-user" and
  $blocks[2].fields[1].text == "Commit:\n1111111" and
  $blocks[3].text.text == ("Commit Message:\n" + $event[0].workflow_run.head_commit.message) and
  $blocks[4].fields[0].text == "<https://github.example.test/org/repo/actions/runs/123/job/900|❌ View Failed Job>" and
  $blocks[4].fields[1].text == "<https://github.example.test/org/repo/tree/111111122222223333333444444455555556666666|:github: View Repository>"
' "$tmp/payload.json" > /dev/null || fail "payload changed triggering commit or failed-step text"
echo "PASS: exact JSON values, triggering commit, and deterministic job/step"
cp "$tmp/payload.json" "$tmp/expected-payload.json"

reset_case
jq '.jobs |= reverse | .jobs[].steps |= reverse' "$tmp/original-jobs.json" > "$tmp/jobs.json"
run_alert || fail "reordered jobs failed"
assert_one_request
cmp "$tmp/expected-payload.json" "$tmp/payload.json" || fail "API ordering changed payload"
echo "PASS: API response order does not change job or step"

reset_case
unset SLACK_WEBHOOK
rm "$GITHUB_EVENT_PATH"
run_alert || fail "missing webhook should skip successfully"
if [ -e "$tmp/gh.calls" ] || [ -e "$tmp/curl.calls" ] || [ -e "$tmp/git.called" ]; then
  fail "missing webhook must skip all lookups and requests"
fi
grep -Fq "::notice::SLACK_WEBHOOK is not configured; skipping Slack alert." "$tmp/output.log" ||
  fail "missing webhook did not explain the skip"
echo "PASS: missing webhook explicitly skips without any request"

reset_case
export SLACK_WEBHOOK=""
run_alert || fail "empty webhook should skip successfully"
if [ -e "$tmp/gh.calls" ] || [ -e "$tmp/curl.calls" ]; then
  fail "empty webhook must skip all requests"
fi
grep -Fq "::notice::SLACK_WEBHOOK is not configured; skipping Slack alert." "$tmp/output.log" ||
  fail "empty webhook did not explain the skip"
echo "PASS: empty webhook explicitly skips without any request"

reset_case
export MOCK_GH_STATUS=1
run_alert || fail "lookup failure should still notify"
assert_one_request
assert_fallback
grep -Fq "::warning::Failed to look up failed jobs" "$tmp/output.log" ||
  fail "lookup failure did not emit a warning"
echo "PASS: lookup failure warns and sends a run-level link"

reset_case
printf '{"jobs":[]}\n' > "$tmp/jobs.json"
run_alert || fail "empty jobs should still notify"
assert_one_request
assert_fallback
echo "PASS: empty jobs use a run-level link"

reset_case
jq '.workflow_run.head_commit = null | del(.workflow_run.triggering_actor)' \
  "$tmp/original-event.json" > "$GITHUB_EVENT_PATH"
run_alert || fail "missing head commit should still notify"
assert_one_request
jq -e '.attachments[0].blocks as $blocks |
  $blocks[2].fields[0].text == "Triggered By:\noriginal-author" and
  $blocks[2].fields[1].text == "Commit:\n1111111" and
  $blocks[3].text.text == "Commit Message:\nunknown"' \
  "$tmp/payload.json" > /dev/null || fail "missing head commit fabricated metadata"
echo "PASS: missing head commit is explicitly unknown"

reset_case
export MOCK_CURL_STATUS=22
if run_alert; then
  fail "HTTP failure must fail the notification"
else
  status=$?
  [ "$status" -eq 22 ] || fail "expected HTTP failure status 22, got $status"
fi
assert_one_request
grep -Fq "curl: (22) mock HTTP 500" "$tmp/output.log" ||
  fail "HTTP error was hidden"
echo "PASS: HTTP failures surface and fail the step"

reset_case
jq '.workflow_run.head_commit.message = "```\n<!channel> <https://example.invalid|Click me>\n```"' \
  "$tmp/original-event.json" > "$GITHUB_EVENT_PATH"
jq '.jobs[2].steps[2].name = "` <!here> <https://example.invalid|Click me>"' \
  "$tmp/original-jobs.json" > "$tmp/jobs.json"
run_alert || fail "markup metadata should still notify"
assert_one_request
jq -e --slurpfile event "$GITHUB_EVENT_PATH" --slurpfile jobs "$tmp/jobs.json" '
  .attachments[0].blocks as $blocks |
  $blocks[1].fields[1].type == "plain_text" and
  $blocks[1].fields[1].text == ("Failed Step:\n" + $jobs[0].jobs[2].steps[2].name) and
  $blocks[3].text.type == "plain_text" and
  $blocks[3].text.text == ("Commit Message:\n" + $event[0].workflow_run.head_commit.message)
' "$tmp/payload.json" > /dev/null || fail "external metadata can activate Slack markup"
echo "PASS: commit and step markup remain literal plain text"

reset_case
jq '.workflow_run.head_commit.message = ([range(0; 4000) | "界"] | join(""))' \
  "$tmp/original-event.json" > "$GITHUB_EVENT_PATH"
jq '.jobs[2].steps[2].name = ([range(0; 3000) | "🚧"] | join(""))' \
  "$tmp/original-jobs.json" > "$tmp/jobs.json"
run_alert || fail "long metadata should still notify"
assert_one_request
jq -e '.attachments[0].blocks as $blocks |
  ($blocks[1].fields[1].text | length) == 2000 and
  ($blocks[1].fields[1].text | endswith("…")) and
  ($blocks[3].text.text | length) == 3000 and
  ($blocks[3].text.text | endswith("…")) and
  all($blocks[] | select(.type == "section") | .fields[]?; (.text | length) <= 2000)
' "$tmp/payload.json" > /dev/null || fail "Slack block character limits exceeded"
echo "PASS: long Unicode metadata fits Slack limits and indicates truncation"
