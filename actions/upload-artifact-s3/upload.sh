#!/usr/bin/env bash
# upload-artifact-s3: collect files (upload-artifact style globs), zip, PUT to the
# self-hosted S3 store with curl --aws-sigv4. Bash 3.2 compatible (macOS) — no
# globstar, mapfile, associative arrays or ${var,,}. Never prints credentials.
set -euo pipefail
export LC_ALL=C

BUCKET="xirigo-ci-artifacts"
# S3 single PUT is limited to 5 GiB; stay below it with headroom.
MAX_BYTES=4831838208 # 4.5 GiB

NAME="${INPUT_NAME:-artifact}"
PATHS="${INPUT_PATH:-}"
IF_NO_FILES="${INPUT_IF_NO_FILES_FOUND:-warn}"
ENDPOINT="${INPUT_ENDPOINT:-}"

die() { echo "::error title=upload-artifact-s3::$*"; exit 1; }

case "$IF_NO_FILES" in warn|error|ignore) ;; *) die "if-no-files-found must be warn, error or ignore (got '$IF_NO_FILES')" ;; esac
[ -n "$PATHS" ] || die "input 'path' is required"
[ -n "$NAME" ] || die "input 'name' must not be empty"
# shellcheck disable=SC1003 # '\' below is a literal backslash pattern
case "$NAME" in
  *'"'*|*:*|*'<'*|*'>'*|*'|'*|*'*'*|*'?'*|*'\'*|*/*) die "artifact name '$NAME' contains a forbidden character (\" : < > | * ? \\ /)" ;;
esac
case "$NAME" in *$'\n'*|*$'\r'*) die "artifact name must be a single line" ;; esac
if [ -n "${INPUT_RETENTION_DAYS:-}" ]; then
  echo "retention-days=${INPUT_RETENTION_DAYS} ignored: the bucket expires every object after 7 days."
fi

for t in zip curl find grep sed sort; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' not found on this runner"
done

# ---------------------------------------------------------------------------
# glob -> ERE. '**/' = zero or more directories, '**' = anything, '*' and '?'
# never cross '/', [...] is kept as a bracket expression ('!' -> '^').
glob_to_ere() {
  local g="$1" out="" i=0 len c j cls
  len=${#g}
  while [ "$i" -lt "$len" ]; do
    c="${g:$i:1}"
    # shellcheck disable=SC1003 # '\' below is a literal backslash pattern
    case "$c" in
      '*')
        if [ "${g:$((i + 1)):1}" = "*" ]; then
          if [ "${g:$((i + 2)):1}" = "/" ]; then out="$out(.*/)?"; i=$((i + 3)); else out="$out.*"; i=$((i + 2)); fi
          continue
        fi
        out="${out}[^/]*" ;;
      '?') out="${out}[^/]" ;;
      '[')
        j=$((i + 1)); cls=""
        [ "${g:$j:1}" = "!" ] && { cls="^"; j=$((j + 1)); }
        [ "${g:$j:1}" = "]" ] && { cls="$cls]"; j=$((j + 1)); }
        while [ "$j" -lt "$len" ] && [ "${g:$j:1}" != "]" ]; do cls="$cls${g:$j:1}"; j=$((j + 1)); done
        if [ "$j" -lt "$len" ]; then out="${out}[${cls}]"; i=$((j + 1)); continue; fi
        out="$out\\[" ;;
      '.'|'+'|'('|')'|'{'|'}'|'^'|'$'|'|'|'\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

has_glob() { case "$1" in *'*'*|*'?'*|*'['*) return 0 ;; esac; return 1; }

# Make a pattern absolute and tidy: ~ expansion, leading ./, trailing /.
normalize() {
  local p="$1"
  # shellcheck disable=SC2088 # literal "~" from the input is expanded by hand
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
  while case "$p" in ./*) true ;; *) false ;; esac; do p="${p#./}"; done
  [ "$p" = "." ] && p=""
  case "$p" in /*) ;; *) p="$PWD${p:+/$p}" ;; esac
  while [ "${#p}" -gt 1 ] && case "$p" in */) true ;; *) false ;; esac; do p="${p%/}"; done
  printf '%s' "$p"
}

# Longest leading run of path components without glob characters.
glob_base() {
  local p="$1" base="" comp rest="${1#/}"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    has_glob "$comp" && break
    base="$base/$comp"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
  printf '%s' "${base:-/}"
}

lca() {
  local a="$1" b="$2"
  while :; do
    [ "$a" = "/" ] && { printf '/'; return; }
    case "$b/" in "$a"/*) printf '%s' "$a"; return ;; esac
    a="${a%/*}"; [ -z "$a" ] && a="/"
  done
}

list_files() { # all regular files (and symlinks to files) under $1
  find "$1" -type f -print 2>/dev/null || true
  find "$1" -type l -exec test -f {} \; -print 2>/dev/null || true
}

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/upload-artifact-s3.XXXXXX")"
trap 'rm -rf "$work"' EXIT
: > "$work/include"; : > "$work/exclude"
root=""

while IFS= read -r line || [ -n "$line" ]; do
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac
  neg=0
  case "$line" in '!'*) neg=1; line="${line#!}" ;; esac
  pat="$(normalize "$line")"
  if has_glob "$pat"; then base="$(glob_base "$pat")"; else base="$pat"; fi
  re="^$(glob_to_ere "$pat")(/.*)?\$"
  if [ "$neg" = 1 ]; then
    printf '%s\n' "$re" >> "$work/exclude"
    continue
  fi
  [ -e "$base" ] || continue
  list_files "$base" | grep -E -- "$re" >> "$work/include" || true
  # search path for the artifact root: the directory itself, or a file's parent
  if [ -d "$base" ]; then sbase="$base"; else sbase="${base%/*}"; [ -z "$sbase" ] && sbase="/"; fi
  if [ -z "$root" ]; then root="$sbase"; else root="$(lca "$root" "$sbase")"; fi
done <<EOF
$PATHS
EOF

sort -u "$work/include" > "$work/files"
if [ -s "$work/exclude" ]; then
  grep -v -E -f "$work/exclude" "$work/files" > "$work/files.kept" || true
  mv "$work/files.kept" "$work/files"
fi

# Paths relative to the artifact root (least common ancestor of the search
# paths, as actions/upload-artifact does); hidden files/dirs below it are
# skipped (upload-artifact >= 4.4 default).
: > "$work/rel"
if [ -s "$work/files" ] && [ -n "$root" ]; then
  if [ "$root" = "/" ]; then prefix="/"; else prefix="$root/"; fi
  while IFS= read -r f; do
    rel="${f#"$prefix"}"
    case "/$rel" in */.*) continue ;; esac
    printf '%s\n' "$rel" >> "$work/rel"
  done < "$work/files"
fi

count=$(grep -c '' "$work/rel" || true)
if [ "${count:-0}" -eq 0 ]; then
  msg="No files were found with the provided path: $(printf '%s' "$PATHS" | tr '\n' ' '). No artifact will be uploaded."
  case "$IF_NO_FILES" in
    error) die "$msg" ;;
    warn) echo "::warning title=upload-artifact-s3::$msg" ;;
    ignore) echo "$msg" ;;
  esac
  exit 0
fi
echo "Found $count file(s); artifact root: $root"

[ -n "$ENDPOINT" ] || die "input 'endpoint' is empty (pass \${{ vars.CI_ARTIFACTS_ENDPOINT }})"
[ -n "${INPUT_ACCESS_KEY:-}" ] && [ -n "${INPUT_SECRET_KEY:-}" ] \
  || die "inputs 'access-key' / 'secret-key' are empty (pass the CI_ARTIFACTS_CI_* secrets)"
ENDPOINT="${ENDPOINT%/}"

zipfile="$work/artifact.zip"
( cd "$root" && zip -q -X "$zipfile" -@ < "$work/rel" ) || die "zip failed"
size=$(wc -c < "$zipfile" | tr -d '[:space:]')
if [ "$size" -gt "$MAX_BYTES" ]; then
  die "artifact '$NAME' is $size bytes after zip; the limit is $MAX_BYTES bytes (4.5 GiB, single S3 PUT). Split it into smaller artifacts."
fi

# Payload hash is signed, so the server rejects a corrupted upload.
# sha256sum (Linux) -> shasum (macOS) -> openssl; UNSIGNED-PAYLOAD only if none work.
sha=$(sha256sum "$zipfile" 2>/dev/null | cut -d' ' -f1) || true
[ "${#sha}" -eq 64 ] || sha=$(shasum -a 256 "$zipfile" 2>/dev/null | cut -d' ' -f1) || true
[ "${#sha}" -eq 64 ] || sha=$(openssl dgst -sha256 -r "$zipfile" 2>/dev/null | cut -d' ' -f1) || true
[ "${#sha}" -eq 64 ] || sha="UNSIGNED-PAYLOAD"

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

repo="${GITHUB_REPOSITORY##*/}"
run="${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}"
# Job id (`github.job`: the key under `jobs:`), never the display name, so that
# download-artifact-s3 can rebuild the key from its `job:` input.
job="${INPUT_JOB_ID:-${GITHUB_JOB:-}}"
[ -n "$job" ] || die "job id unknown (github.job / GITHUB_JOB empty)"
key="$repo/$run/$job/$NAME.zip"
enckey="$(urlenc "$repo")/$(urlenc "$run")/$(urlenc "$job")/$(urlenc "$NAME.zip")"

echo "Uploading $size bytes to s3://$BUCKET/$key"
code=$(printf 'user = "%s:%s"\n' "$INPUT_ACCESS_KEY" "$INPUT_SECRET_KEY" | curl -sS -K - \
  --aws-sigv4 "aws:amz:us-east-1:s3" \
  -H "x-amz-content-sha256: $sha" -H "Content-Type: application/zip" \
  --retry 3 --retry-delay 5 --retry-all-errors \
  -T "$zipfile" -o "$work/response" -w '%{http_code}' \
  "$ENDPOINT/$BUCKET/$enckey") || code="curl-error"
case "$code" in
  200) ;;
  *)
    reason=$(sed -n 's:.*<Code>\(.*\)</Code>.*:\1:p' "$work/response" 2>/dev/null | head -1 || true)
    die "upload failed: HTTP $code${reason:+ ($reason)}"
    ;;
esac

human=$(awk -v b="$size" 'BEGIN { split("B KiB MiB GiB", u, " "); i = 1; while (b >= 1024 && i < 4) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }')
echo "Uploaded s3://$BUCKET/$key ($human)"
{
  echo "key=$key"
  echo "size=$size"
} >> "${GITHUB_OUTPUT:-/dev/null}"
{
  echo "### Artifact \`$NAME\`"
  echo ""
  echo "| | |"
  echo "| --- | --- |"
  echo "| Object | \`s3://$BUCKET/$key\` |"
  echo "| Size | $human ($size bytes) |"
  echo "| Files | $count |"
  echo "| SHA-256 | \`$sha\` |"
  echo "| Expires | 7 days after upload (bucket rule) |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
