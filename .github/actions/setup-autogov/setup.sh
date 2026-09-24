#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

version="${AUTOGOV_VERSION:-}"
repo="${AUTOGOV_REPO:-}"

[ -n "$version" ] || fail "autogov-version is required"
[[ "$version" != *$'\n'* && "$version" != *$'\r'* && "$version" != *$'\t'* ]] ||
  fail "autogov-version cannot contain control characters"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "autogov-repo must use owner/repo format"
if [ "${RUNNER_OS:-}" != Linux ] || [ "${RUNNER_ARCH:-}" != X64 ]; then
  fail "setup-autogov requires a Linux X64 runner"
fi
[ -n "${RUNNER_TEMP:-}" ] || fail "RUNNER_TEMP is required"
[ -n "${GITHUB_OUTPUT:-}" ] || fail "GITHUB_OUTPUT is required"
[ -n "${GITHUB_PATH:-}" ] || fail "GITHUB_PATH is required"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required"
# Older verify-asset versions can forward tokens to TUF mirrors (GHSA-8xvp-7hj6-mcj9).
if ! gh_version="$(gh --version)" || ! awk '
  NR == 1 {
    if ($1 != "gh" || $2 != "version" ||
        $3 !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) exit 1
    split($3, version, ".")
    exit !(version[1] > 2 || (version[1] == 2 && version[2] >= 93))
  }
' <<< "$gh_version"; then
  fail "GitHub CLI 2.93.0 or newer (stable release) is required"
fi

release_query="
  .[]
  | select(.draft == false)
  | (.assets | map(select(.name == \"autogov\"))) as \$assets
  | [
      .tag_name,
      (.immutable // false),
      (\$assets | length),
      (\$assets[0].digest // \"\"),
      (\$assets[0].size // 0)
    ]
  | @tsv
"
if ! published_releases="$(
  gh api --paginate "repos/${repo}/releases?per_page=100" --jq "$release_query"
)"; then
  fail "unable to list published releases for $repo"
fi

release_row="$(
  awk -F $'\t' -v requested="$version" '"tag:" $1 == "tag:" requested { print }' <<< "$published_releases"
)"
resolved_from_commit=false

if [[ "$version" =~ ^[0-9a-fA-F]{40}$ ]] && [ -z "$release_row" ]; then
  if ! tag_commits="$(
    gh api --paginate "repos/${repo}/tags?per_page=100" \
      --jq '.[] | [.name, .commit.sha] | @tsv'
  )"; then
    fail "unable to resolve release tags for $repo"
  fi

  release_row="$(
    while IFS=$'\t' read -r tag immutable asset_count asset_digest asset_size; do
      [ "$immutable" = true ] || continue
      commit="$(
        awk -F $'\t' -v wanted="$tag" '"tag:" $1 == "tag:" wanted { print $2 }' <<< "$tag_commits"
      )"
      if [ "${commit,,}" = "${version,,}" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$tag" "$immutable" "$asset_count" "$asset_digest" "$asset_size"
      fi
    done <<< "$published_releases"
  )"
  resolved_from_commit=true
fi

if [ -z "$release_row" ] || [[ "$release_row" == *$'\n'* ]]; then
  if [[ "$version" =~ ^[0-9a-fA-F]{40}$ ]]; then
    fail "autogov full 40-character SHA must identify exactly one immutable published release: $version"
  fi
  fail "autogov-version must identify one immutable published release: $version"
fi

release_tag="$(awk -F $'\t' '{ print $1 }' <<< "$release_row")"
immutable="$(awk -F $'\t' '{ print $2 }' <<< "$release_row")"
asset_count="$(awk -F $'\t' '{ print $3 }' <<< "$release_row")"
asset_digest="$(awk -F $'\t' '{ print $4 }' <<< "$release_row")"
asset_size="$(awk -F $'\t' '{ print $5 }' <<< "$release_row")"

[ "$immutable" = true ] ||
  fail "autogov-version must identify an immutable published release: $version"
[ "$asset_count" = 1 ] ||
  fail "immutable release $release_tag must contain exactly one 'autogov' asset"
[[ "$asset_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] ||
  fail "immutable release $release_tag has no valid SHA-256 digest for 'autogov'"
if ! [[ "$asset_size" =~ ^[0-9]+$ ]] || [ "$asset_size" -le 0 ]; then
  fail "immutable release $release_tag has an invalid 'autogov' asset size"
fi

# Encode the whole ref so legal tag characters cannot alter the URL. Qualifying
# refs/tags also prevents a same-named branch from supplying the commit. The
# commits endpoint peels annotated tags to their underlying commit.
urlencode() {
  local value="$1" char i LC_ALL=C
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}
release_ref="$(urlencode "refs/tags/$release_tag")"
if ! release_commit="$(
  gh api "repos/${repo}/commits/${release_ref}" --jq '.sha'
)"; then
  fail "unable to resolve commit for immutable release $release_tag"
fi
[[ "$release_commit" =~ ^[0-9a-fA-F]{40}$ ]] ||
  fail "immutable release $release_tag did not resolve to a full commit SHA"
if [ "$resolved_from_commit" = true ] &&
  [ "${release_commit,,}" != "${version,,}" ]; then
  fail "immutable release $release_tag no longer resolves to requested commit $version"
fi

stage="$(mktemp -d "$RUNNER_TEMP/setup-autogov.XXXXXX")" ||
  fail "unable to create setup-autogov staging directory"
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT

if ! gh release download "$release_tag" \
  --repo "$repo" \
  --pattern autogov \
  --dir "$stage"; then
  fail "unable to download autogov from immutable release $release_tag"
fi

download="$stage/autogov"
if [ ! -f "$download" ] || [ -L "$download" ] || [ ! -s "$download" ]; then
  fail "downloaded autogov binary is not a non-empty regular file"
fi

actual_size="$(wc -c < "$download" | tr -d '[:space:]')"
[ "$actual_size" = "$asset_size" ] ||
  fail "autogov asset size mismatch for immutable release $release_tag"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha="$(sha256sum "$download" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual_sha="$(shasum -a 256 "$download" | awk '{ print $1 }')"
else
  fail "SHA-256 checksum tool is required"
fi
actual_digest="sha256:$actual_sha"
[ "${actual_digest,,}" = "${asset_digest,,}" ] ||
  fail "autogov asset checksum mismatch for immutable release $release_tag"

if ! gh release verify-asset "$release_tag" "$download" --repo "$repo"; then
  fail "GitHub release attestation verification failed for $release_tag"
fi

install_dir="$RUNNER_TEMP/setup-autogov/bin"
install_path="$install_dir/autogov"
install -d -m 0755 "$install_dir"
install -m 0755 "$download" "$install_path"

printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
{
  printf 'path=%s\n' "$install_path"
  printf 'release-tag=%s\n' "$release_tag"
  printf 'commit-sha=%s\n' "$release_commit"
  printf 'sha256=%s\n' "$asset_digest"
} >> "$GITHUB_OUTPUT"
