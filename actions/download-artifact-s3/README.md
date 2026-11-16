# download-artifact-s3

Counterpart of [`upload-artifact-s3`](../upload-artifact-s3/README.md). It is a drop-in for the
common `actions/download-artifact@v4` usage: download **one artifact by name** into a directory.
It fetches `<repo>/<run_id>-<run_attempt>/<job>/<name>.zip` from the XiriGo self-hosted S3 store
by exact key and extracts it into `path`.

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `name` | (required) | Artifact name given to `upload-artifact-s3`. |
| `path` | `.` | Directory to extract into (created if missing). `~` is `$HOME`. |
| `job` | (required) | **Job id of the uploading job**: its key under `jobs:` (what `${{ github.job }}` returns in that job), **not** its display `name:`. `download-artifact@v4` does not need it, but the object key does. |
| `run-id` | current run | Another run's id. Its attempts 10…1 are probed, newest first. |
| `endpoint`, `access-key`, `secret-key` | | `${{ vars.CI_ARTIFACTS_ENDPOINT }}`, `${{ secrets.CI_ARTIFACTS_CI_ACCESS_KEY }}`, `${{ secrets.CI_ARTIFACTS_CI_SECRET_KEY }}` |

Outputs: `download-path` (absolute) and `key`.

## Behaviour

- **Re-runs:** in the current run, the current `run_attempt` is tried first, then older attempts.
  After "Re-run failed jobs", the producing job keeps its artifact from the earlier attempt and
  is still found.
- **Download:** `curl --aws-sigv4 --fail-with-body` (a `-f` that keeps the S3 error code) with
  retries on transient errors, then `unzip` (fallback: `python3 zipfile`). Unix file modes stored
  by `upload-artifact-s3` (zip) are restored, so executables keep their exec bit.
- **Clear errors:**
  - Not found (404, or 403 `AccessDenied`) in any attempt: says which attempts were tried, and
    that `job` must be the job id and the object younger than 7 days.
  - 403 with another code (e.g. `SignatureDoesNotMatch`, `InvalidAccessKeyId`): credentials.
  - Endpoint unreachable: network/TLS.
- Plain bash 3.2, `curl` ≥ 7.76, `unzip` or `python3`. Works on the macOS runner and the Linux
  runners.

## Not covered (compared to `actions/download-artifact@v4`)

- No `name`: "download all artifacts of the run". Not possible, because the CI identity cannot
  list. Name each artifact.
- `pattern:` / `merge-multiple:`: the same reason. Download each name explicitly.
- `github-token` + `repository:` (another repository's artifacts): not supported.
- `artifact-ids:`: there are no artifact ids.

Current XiriGo usage (default branches, 2026-11-16) is one call (`ecommerce-mobile` `ios-ci.yml`,
`e2e` job). It uses only `name` + `path` and is fully covered.

## ecommerce-mobile `ios-ci.yml`: exact before / after

Producing job id: **`build`** (display name "Build"). The consuming job is `e2e`.

Before (`build` job):

```yaml
      - name: Upload .app artifact
        uses: actions/upload-artifact@v4
        with:
          name: ios-debug-app
          path: .ci/app.zip
          retention-days: 1
          if-no-files-found: error
```

After (`build` job):

```yaml
      - name: Upload .app artifact
        uses: XiriGo/.github/actions/upload-artifact-s3@main
        with:
          name: ios-debug-app
          path: .ci/app.zip
          retention-days: 1 # accepted, ignored (bucket rule: 7 days)
          if-no-files-found: error
          endpoint: ${{ vars.CI_ARTIFACTS_ENDPOINT }}
          access-key: ${{ secrets.CI_ARTIFACTS_CI_ACCESS_KEY }}
          secret-key: ${{ secrets.CI_ARTIFACTS_CI_SECRET_KEY }}
```

Before (`e2e` job):

```yaml
      - name: Download .app artifact from build job
        uses: actions/download-artifact@v4
        with:
          name: ios-debug-app
          path: .ci/dl
```

After (`e2e` job):

```yaml
      - name: Download .app artifact from build job
        uses: XiriGo/.github/actions/download-artifact-s3@main
        with:
          name: ios-debug-app
          path: .ci/dl
          job: build # job id of the uploading job (key under `jobs:`), not "Build"
          endpoint: ${{ vars.CI_ARTIFACTS_ENDPOINT }}
          access-key: ${{ secrets.CI_ARTIFACTS_CI_ACCESS_KEY }}
          secret-key: ${{ secrets.CI_ARTIFACTS_CI_SECRET_KEY }}
```

The following step, `Install app on simulator`, keeps working unchanged. It expects
`.ci/dl/app.zip`: the upload root is `.ci`, so the artifact zip contains `app.zip`, which is
extracted to `.ci/dl/app.zip` byte-for-byte. The inner ditto zip, with its modes, symlinks and
signature, is untouched. The other `upload-artifact@v4` steps in `ios-ci.yml` (test results,
snapshots, e2e results) are uploads only and switch to `upload-artifact-s3` the same way.
