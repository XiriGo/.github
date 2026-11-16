#!/usr/bin/env bash
# download-artifact-s3: fetch <repo>/<run_id>-<run_attempt>/<job>/<name>.zip from the
# self-hosted S3 store (curl --aws-sigv4, GET by exact key) and unzip it into `path`.
# Bash 3.2 compatible (macOS). Never prints credentials.
set -euo pipefail
export LC_ALL=C

BUCKET="xirigo-ci-artifacts"
# For a run other than the current one the latest attempt is unknown (the CI identity
# cannot list), so attempts MAX_FOREIGN_ATTEMPTS..1 are probed, newest first.
MAX_FOREIGN_ATTEMPTS=10

NAME="${INPUT_NAME:-}"
DEST="${INPUT_PATH:-.}"
JOB="${INPUT_JOB:-}"
RUN_ID="${INPUT_RUN_ID:-}"
ENDPOINT="${INPUT_ENDPOINT:-}"

die() { echo "::error title=download-artifact-s3::$*"; exit 1; }

[ -n "$NAME" ] || die "input 'name' is required (downloading all artifacts of a run is not supported: the CI identity cannot list)"
# shellcheck disable=SC1003 # '\' below is a literal backslash pattern
case "$NAME" in
  *'"'*|*:*|*'<'*|*'>'*|*'|'*|*'*'*|*'?'*|*'\'*|*/*) die "artifact name '$NAME' contains a forbidden character (\" : < > | * ? \\ /)" ;;
esac
[ -n "$JOB" ] || die "input 'job' is required: the job id (\${{ github.job }} of the producing job, the key under 'jobs:'), not its display name"
case "$JOB" in */*) die "input 'job' must be a job id, got '$JOB'" ;; esac
[ -n "$ENDPOINT" ] || die "input 'endpoint' is empty (pass \${{ vars.CI_ARTIFACTS_ENDPOINT }})"
[ -n "${INPUT_ACCESS_KEY:-}" ] && [ -n "${INPUT_SECRET_KEY:-}" ] \
  || die "inputs 'access-key' / 'secret-key' are empty (pass the CI_ARTIFACTS_CI_* secrets)"
ENDPOINT="${ENDPOINT%/}"
for t in curl sed; do command -v "$t" >/dev/null 2>&1 || die "'$t' not found on this runner"; done

repo="${GITHUB_REPOSITORY##*/}"
[ -n "$repo" ] || die "GITHUB_REPOSITORY is not set"
cur_run="${GITHUB_RUN_ID:-}"
if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "$cur_run" ]; then
  run="$cur_run"
  # Current run: the producing job ran in this attempt or (after "re-run failed
  # jobs") in an earlier one, so try this attempt first, then older ones.
  max_attempt="${GITHUB_RUN_ATTEMPT:-1}"
else
  run="$RUN_ID"
  max_attempt="$MAX_FOREIGN_ATTEMPTS"
fi
case "$run" in ''|*[!0-9]*) die "run id must be numeric, got '$run'" ;; esac
case "$max_attempt" in ''|*[!0-9]*) max_attempt=1 ;; esac

urlenc() { # percent-encode one key segment (RFC 3986 unreserved kept)
  local s="$1" out="" i=0 c
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/download-artifact-s3.XXXXXX")"
trap 'rm -rf "$work"' EXIT
zipfile="$work/artifact.zip"

found=""
attempt="$max_attempt"
tried=""
while [ "$attempt" -ge 1 ]; do
  key="$repo/$run-$attempt/$JOB/$NAME.zip"
  enckey="$(urlenc "$repo")/$(urlenc "$run-$attempt")/$(urlenc "$JOB")/$(urlenc "$NAME.zip")"
  code=$(printf 'user = "%s:%s"\n' "$INPUT_ACCESS_KEY" "$INPUT_SECRET_KEY" | curl -s -K - \
    --aws-sigv4 "aws:amz:us-east-1:s3" --fail-with-body --retry 3 --retry-delay 5 \
    -o "$zipfile" -w '%{http_code}' "$ENDPOINT/$BUCKET/$enckey") || true
  if [ "$code" = "200" ]; then found="$key"; break; fi
  reason=$(sed -n 's:.*<Code>\(.*\)</Code>.*:\1:p' "$zipfile" 2>/dev/null | head -1 || true)
  case "$code:$reason" in
    404:*|403:AccessDenied|403:NoSuchKey|403:)
      # Missing key. Without list permission S3 may answer a missing key with 403
      # AccessDenied instead of 404, so both mean "not here, try the next attempt".
      tried="$tried $run-$attempt"
      echo "not in run attempt $attempt (HTTP $code${reason:+ $reason})"
      ;;
    403:*) die "access denied ($reason) for s3://$BUCKET/$key: check access-key/secret-key" ;;
    000:*) die "could not reach $ENDPOINT (network/TLS error)" ;;
    *) die "download failed for s3://$BUCKET/$key: HTTP $code${reason:+ ($reason)}" ;;
  esac
  attempt=$((attempt - 1))
done

if [ -z "$found" ]; then
  die "artifact '$NAME' of job '$JOB' not found (HTTP 403/404) in run attempt(s):$tried. Check that job '$JOB' uploaded it with upload-artifact-s3 in that run, that 'job' is its job id (the key under 'jobs:', = \${{ github.job }}), not its display name, and that it is younger than 7 days."
fi

size=$(wc -c < "$zipfile" | tr -d '[:space:]')
echo "Downloaded s3://$BUCKET/$found ($size bytes)"

# shellcheck disable=SC2088 # literal "~" from the input is expanded by hand
case "$DEST" in "~") DEST="$HOME" ;; "~/"*) DEST="$HOME/${DEST#\~/}" ;; esac
mkdir -p "$DEST"
if command -v unzip >/dev/null 2>&1; then
  unzip -q -o "$zipfile" -d "$DEST" || die "unzip failed"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zipfile" "$DEST" \
    || die "extract (python3 zipfile) failed"
else
  die "neither 'unzip' nor 'python3' is available to extract the artifact"
fi
abs="$(cd "$DEST" && pwd)"
echo "Extracted into $abs"

{
  echo "download-path=$abs"
  echo "key=$found"
} >> "${GITHUB_OUTPUT:-/dev/null}"
