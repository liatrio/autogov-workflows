#!/usr/bin/env bash
set -euo pipefail

AUTOGOV_VERSION='v1.3.0'
AUTOGOV_SHA256='570a49ccf59376cb4c341041e00fa6126e5653cdec73ea8f6532b9d60562ef3d'

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_line() { grep -Fxq -- "$2" "$1" || fail "expected exact line '$2' in $1"; }

if [ "$(uname -s)" != Linux ] && [ -z "${AUTOGOV_TEST_BINARY:-}" ]; then
  echo 'rw-release CLI regression tests require the released Linux binary; run on Ubuntu' >&2
  exit 0
fi

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
autogov="$test_root/autogov"
if [ -n "${AUTOGOV_TEST_BINARY:-}" ]; then
  install -m 0755 "$AUTOGOV_TEST_BINARY" "$autogov"
else
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/liatrio/autogov/releases/download/${AUTOGOV_VERSION}/autogov" \
    --output "$autogov"
  echo "${AUTOGOV_SHA256}  ${autogov}" | sha256sum --check --strict -
  chmod +x "$autogov"
fi

repo="$test_root/repo"
git init --initial-branch=main "$repo" >/dev/null
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf '# test\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'feat: initial release' >/dev/null
baseline="$(git -C "$repo" rev-parse HEAD)"
baseline_tags="$(git -C "$repo" tag --list)"

image="$test_root/image"
blob="$test_root/blob"
mkdir -p "$image/nested" "$blob/deep"
printf '{}\n' > "$image/nested/vsa-PASSED.json"
printf '{}\n' > "$blob/vsa-PASSED.json"
printf 'bundle\n' > "$blob/deep/bundle.tar.gz"
: > "$blob/deep/empty.txt"

"$autogov" release cut --repo "$repo" --branch main --mode local --dry-run \
  --asset-source "image=$image" --asset-source "blob=$blob" > "$test_root/success.out" 2>&1
assert_line "$test_root/success.out" 'dry-run: would upload 3 asset(s): bundle.tar.gz, vsa-blob-PASSED.json, vsa-image-PASSED.json'
if grep -Fq -- 'empty.txt' "$test_root/success.out"; then
  fail 'zero-byte source file appeared in the release plan'
fi

empty="$test_root/all-empty"
mkdir -p "$empty/nested"
: > "$empty/nested/empty.txt"
if "$autogov" release cut --repo "$repo" --branch main --mode local --dry-run --asset-source "empty=$empty" \
  > "$test_root/empty.log" 2>&1; then
  fail 'all-empty source was accepted'
fi
assert_contains "$test_root/empty.log" 'contains no releasable files'

first="$test_root/first"
second="$test_root/second"
mkdir -p "$first/nested" "$second/other"
printf 'first\n' > "$first/nested/archive.tar.gz"
printf 'second\n' > "$second/other/archive.tar.gz"
if "$autogov" release cut --repo "$repo" --branch main --mode local --dry-run \
  --asset-source "first=$first" --asset-source "second=$second" > "$test_root/collision.log" 2>&1; then
  fail 'duplicate ordinary basename was accepted'
fi
assert_contains "$test_root/collision.log" 'multiple assets resolve to the same name "archive.tar.gz"'
assert_contains "$test_root/collision.log" "$first/nested/archive.tar.gz"
assert_contains "$test_root/collision.log" "$second/other/archive.tar.gz"

explicit="$test_root/archive.tar.gz"
printf 'explicit\n' > "$explicit"
if "$autogov" release cut --repo "$repo" --branch main --mode local --dry-run --asset "$explicit" \
  --asset-source "first=$first" > "$test_root/explicit-collision.log" 2>&1; then
  fail 'explicit/source basename collision was accepted'
fi
assert_contains "$test_root/explicit-collision.log" 'multiple assets resolve to the same name "archive.tar.gz"'
assert_contains "$test_root/explicit-collision.log" "$explicit"
assert_contains "$test_root/explicit-collision.log" "$first/nested/archive.tar.gz"

if "$autogov" release cut --repo "$repo" --branch main --mode local --dry-run \
  --asset-source "release image=$first" --asset-source "release-image=$second" \
  > "$test_root/ambiguous.log" 2>&1; then
  fail 'ambiguous sanitized source IDs were accepted'
fi
assert_contains "$test_root/ambiguous.log" 'ambiguous asset source IDs'

[ "$(git -C "$repo" rev-parse HEAD)" = "$baseline" ] || fail 'CLI preflight mutated the repository'
git -C "$repo" diff --quiet || fail 'CLI preflight changed tracked files'
git -C "$repo" diff --cached --quiet || fail 'CLI preflight staged repository changes'
[ "$(git -C "$repo" tag --list)" = "$baseline_tags" ] || fail 'CLI preflight created a tag'
[ -z "$(git -C "$repo" status --porcelain)" ] || fail 'CLI preflight created staged or untracked repository state'

echo 'rw-release v1.3.0 CLI regression tests passed'
