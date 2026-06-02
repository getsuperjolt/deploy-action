# getsuperjolt/deploy-action

Deploy code to a [Superjolt](https://superjolt.com) VM from GitHub Actions.

The action calls Superjolt's HTTP API directly — no SSH key, no agent install on the runner, no container build. It uploads files (single inline or directory via presigned URL) and runs a shell command on the VM, propagating stdout/stderr/exit code back to the workflow log.

## Quick start

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: getsuperjolt/deploy-action@v1
        with:
          token: ${{ secrets.SUPERJOLT_TOKEN }}
          vm: web
          upload: ./dist
          command: |
            cd /root/app && npm ci --omit=dev && pm2 reload all || pm2 start npm -- start
```

## Getting a token

1. Open the [Superjolt dashboard](https://dashboard.superjolt.com) → **Settings → API keys → Create**.
2. Copy the `sj_live_…` token (it's only shown once).
3. In GitHub → repo **Settings → Secrets and variables → Actions → New repository secret**:
   - **Name**: `SUPERJOLT_TOKEN`
   - **Value**: paste the token

Token creation is dashboard-only by design — a leaked bearer can't mint shadow tokens (see HI-31 in the Superjolt API).

## Inputs

| name | required | default | description |
|---|---|---|---|
| `token` | ✅ | — | `sj_live_…` API token. Store as a GitHub Secret. |
| `vm` | ✅ | — | VM name or id. Names resolve via `/v1/vms/resolve`; ambiguity → 404. |
| `project` | | first project | Project name or id. Omit if the tenant has one project. |
| `upload` | | — | Local path to ship. File → inline base64 (≤16 MiB). Directory → tar + presigned PUT. |
| `upload_to` | | `/root/app` | Absolute remote path. |
| `command` | | — | Shell command run after upload completes. |
| `workdir` | | `upload_to` or `/root` | Working directory for `command`. |
| `api_url` | | `https://api.superjolt.com` | Override for self-hosted / dev. |

## Outputs

- `vm_id` — the resolved `vm-…` id, useful for chaining steps.

## Versioning

Pin to a semver release for stability — and follow [GitHub's post-tj-actions guidance](https://github.blog/changelog/2025-08-15-github-actions-policy-now-supports-blocking-and-sha-pinning-actions/) by pinning to a commit SHA in high-security orgs.

```yaml
uses: getsuperjolt/deploy-action@v1.0.0   # immutable semver
# or
uses: getsuperjolt/deploy-action@<full-sha>  # most secure
# or
uses: getsuperjolt/deploy-action@v1          # moving major (convenient, not recommended for prod)
```

## Audit attribution

Every API call from this action sends `User-Agent: superjolt-action/<version> (+https://github.com/getsuperjolt/deploy-action)`. Superjolt's audit service detects that header and stamps `metadata.source = 'github-actions'` on every audit row, so the dashboard activity feed renders a "via GitHub Actions" badge.

## Plain SSH alternative

If you'd rather use `appleboy/ssh-action` / `rsync-deployments` / `docker compose pull` over SSH, register your public key in **Settings → API keys → SSH keys**, then call the Superjolt MCP `enable_ssh` tool (or `POST /v1/vms/:id/enable-ssh`) on the target VM. sshd installs, your key lands in `authorized_keys`, and the VM exposes a public TCP port at `vm-<id>.superjolt.host:<port>`. See the [SSH docs](https://superjolt.com/docs/deploy/ssh).
