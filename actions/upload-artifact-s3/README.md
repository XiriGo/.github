# upload-artifact-s3

Drop-in replacement for the common `actions/upload-artifact@v4` usage in XiriGo workflows.
XiriGo no longer uses GitHub artifact storage. Artifacts go to the self-hosted, S3-compatible
store at `vars.CI_ARTIFACTS_ENDPOINT` (bucket `xirigo-ci-artifacts`) and **expire 7 days after
upload**.

## Replace `actions/upload-artifact@v4`

Before:

```yaml
- uses: actions/upload-artifact@v4
  with:
    name: app-debug
    path: app/build/outputs/apk/debug/*.apk
    if-no-files-found: error
    retention-days: 7
```

After (pin to a commit SHA of this repository instead of `main` if you prefer):

```yaml
- uses: XiriGo/.github/actions/upload-artifact-s3@main
  with:
    name: app-debug
    path: app/build/outputs/apk/debug/*.apk
    if-no-files-found: error
    retention-days: 7 # accepted, ignored (bucket rule: 7 days)
    endpoint: ${{ vars.CI_ARTIFACTS_ENDPOINT }}
    access-key: ${{ secrets.CI_ARTIFACTS_CI_ACCESS_KEY }}
    secret-key: ${{ secrets.CI_ARTIFACTS_CI_SECRET_KEY }}
```

`CI_ARTIFACTS_ENDPOINT` (variable) and `CI_ARTIFACTS_CI_ACCESS_KEY` / `CI_ARTIFACTS_CI_SECRET_KEY`
(secrets) are set at organization level for all repositories. Always pass them explicitly.
The action has no defaults for them.

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `name` | `artifact` | Becomes `<name>.zip`. Must not contain `" : < > \| * ? \ /` or newlines. |
| `path` | (required) | One entry per line: file, directory or glob (`*`, `**`, `?`, `[...]`). A line starting with `!` excludes; `#` lines are comments; `~` is `$HOME`. |
| `if-no-files-found` | `warn` | `warn`, `error` or `ignore`. |
| `retention-days` | | Accepted for compatibility, ignored. |
| `endpoint`, `access-key`, `secret-key` | | See the snippet above. |

Outputs: `key` (object key in the bucket) and `size` (bytes). Both are also written to the job
summary, together with the SHA-256 of the zip.

## Behaviour

- Same layout as `upload-artifact`: paths inside the zip are relative to the least common ancestor
  of the search paths. Hidden files and directories (`.name`) below that root are skipped,
  matching the `upload-artifact` ≥ 4.4 default.
- Object key: `<repo>/<run_id>-<run_attempt>/<job>/<name>.zip`. Re-runs get their own prefix.
  Use a distinct `name` per matrix leg, as with `upload-artifact@v4`.
- Upload: single SigV4 `PUT` with `curl --aws-sigv4`. The payload SHA-256 is signed, so the server
  rejects a corrupted upload. Retried 3 times on transient errors. A zip larger than
  **4.5 GiB** fails with a clear message (single-PUT limit). Split such artifacts.
- Credentials are passed to curl on stdin (`-K -`), never on the command line, and never printed.
- Works on the self-hosted Linux runners (Ubuntu 24.04, ARC pods) and the self-hosted macOS
  runner: plain bash 3.2, `zip`, `curl` ≥ 7.75, `find`, `grep`, `sed`. No extra tools.

## Downloading

The CI identity is **write-only**: it can upload, but cannot list, download or delete. There is
no `download-artifact` counterpart. Jobs that need a file from an earlier job in the same
workflow should rebuild it or run in the same job. People download through an admin: either
port-forward with admin credentials, or a presigned URL the admin generates. See the everva/k8s
`infrastructure/ci-artifacts` PR.

## `actions/cache`

Do **not** replace `actions/cache` with this action. On the self-hosted runners, caching comes from
persistent runner disks and the node-local read-only seed (`/ci-seed`: JDK/Go/Node toolcache,
Android SDK, Gradle wrapper and read-only Gradle dependency cache via `GRADLE_RO_DEP_CACHE`).
**Remove** `actions/cache` (and `cache:` options of `setup-*` actions that write to GitHub's
cache) from workflows that run on self-hosted runners.
