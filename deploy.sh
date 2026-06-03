#!/usr/bin/env bash
# Composite-action body for getsuperjolt/deploy-action@v1.
# Resolves the target VM, uploads files, runs a command.
# Every request carries `User-Agent: superjolt-action/<version> (+https://github.com/getsuperjolt/deploy-action)`
# so the dashboard activity feed tags the audit row with metadata.source = 'github-actions'.

set -euo pipefail

UA="superjolt-action/${ACTION_VERSION} (+https://github.com/getsuperjolt/deploy-action)"
AUTH="Authorization: Bearer ${SUPERJOLT_TOKEN}"

if [[ -z "${SUPERJOLT_TOKEN:-}" ]]; then
  echo "::error::token input is empty. Pass secrets.SUPERJOLT_TOKEN."
  exit 1
fi
if [[ -z "${INPUT_VM:-}" ]]; then
  echo "::error::vm input is required."
  exit 1
fi

# 1. resolve vm name + project → vm id
RESOLVE_URL="${SUPERJOLT_API_URL%/}/v1/vms/resolve?vm=$(jq -rn --arg v "$INPUT_VM" '$v|@uri')"
if [[ -n "${INPUT_PROJECT:-}" ]]; then
  RESOLVE_URL="${RESOLVE_URL}&project=$(jq -rn --arg p "$INPUT_PROJECT" '$p|@uri')"
fi

echo "Resolving VM '${INPUT_VM}'${INPUT_PROJECT:+ in project '${INPUT_PROJECT}'}..."
RESOLVE_RES=$(curl -fsS -H "$AUTH" -H "User-Agent: $UA" "$RESOLVE_URL")
VM_ID=$(echo "$RESOLVE_RES" | jq -r .vmId)
if [[ -z "$VM_ID" || "$VM_ID" == "null" ]]; then
  echo "::error::resolve returned no vmId: $RESOLVE_RES"
  exit 1
fi
echo "Resolved → $VM_ID"
echo "vm_id=$VM_ID" >> "$GITHUB_OUTPUT"

# 2. upload (if requested)
if [[ -n "${INPUT_UPLOAD:-}" ]]; then
  if [[ ! -e "$INPUT_UPLOAD" ]]; then
    echo "::error::upload path '$INPUT_UPLOAD' does not exist on the runner."
    exit 1
  fi
  REMOTE="${INPUT_UPLOAD_TO:-/root/app}"

  if [[ -f "$INPUT_UPLOAD" ]]; then
    # single file → inline base64 via /v1/vms/:id/files (≤16 MiB)
    SIZE=$(stat -c%s "$INPUT_UPLOAD")
    if (( SIZE > 16 * 1024 * 1024 )); then
      echo "::error::single-file upload >16 MiB; use a directory path to go through the presigned-URL flow."
      exit 1
    fi
    BASENAME=$(basename "$INPUT_UPLOAD")
    # Path-resolution rule (VM-side, never inspect the runner FS):
    #   - if `upload_to` ends in `/`, treat as directory; the local file
    #     lands at `<upload_to><basename>`.
    #   - otherwise, treat `upload_to` as the full remote file path.
    if [[ "$REMOTE" == */ ]]; then
      REMOTE_PATH="${REMOTE}${BASENAME}"
    else
      REMOTE_PATH="$REMOTE"
    fi
    echo "Uploading $INPUT_UPLOAD → $REMOTE_PATH ..."
    BODY=$(jq -n --arg p "$REMOTE_PATH" --arg c "$(base64 -w0 < "$INPUT_UPLOAD")" \
      '{files: [{path: $p, content: $c}]}')
    curl -fsS -X POST -H "$AUTH" -H "User-Agent: $UA" -H "Content-Type: application/json" \
      -d "$BODY" "${SUPERJOLT_API_URL%/}/v1/vms/${VM_ID}/files" > /dev/null
  else
    # directory → /v1/uploads (presigned PUT) → /v1/uploads/:id/complete
    echo "Uploading directory $INPUT_UPLOAD → $REMOTE ..."
    BEGIN_RES=$(curl -fsS -X POST -H "$AUTH" -H "User-Agent: $UA" -H "Content-Type: application/json" \
      -d "$(jq -n --arg v "$VM_ID" '{purpose: "deploy", vmId: $v}')" \
      "${SUPERJOLT_API_URL%/}/v1/uploads")
    UPLOAD_ID=$(echo "$BEGIN_RES" | jq -r .uploadId)
    UPLOAD_URL=$(echo "$BEGIN_RES" | jq -r .uploadUrl)
    if [[ -z "$UPLOAD_ID" || "$UPLOAD_ID" == "null" || -z "$UPLOAD_URL" || "$UPLOAD_URL" == "null" ]]; then
      echo "::error::upload begin response missing uploadId/uploadUrl: $BEGIN_RES"
      exit 1
    fi
    TGZ=$(mktemp -t superjolt-upload-XXXXXX.tar.gz)
    trap 'rm -f "$TGZ"' EXIT
    tar -C "$INPUT_UPLOAD" -czf "$TGZ" .
    curl -fsS -X PUT --upload-file "$TGZ" "$UPLOAD_URL" > /dev/null
    curl -fsS -X POST -H "$AUTH" -H "User-Agent: $UA" -H "Content-Type: application/json" \
      -d "$(jq -n --arg v "$VM_ID" --arg p "$REMOTE" '{destination: {vmId: $v, vmPath: $p}}')" \
      "${SUPERJOLT_API_URL%/}/v1/uploads/${UPLOAD_ID}/complete" > /dev/null
  fi
fi

# 3. exec command (if provided) — async path so long-running deploys
#    (npm ci, builds) don't hit Cloudflare's ~100s edge timeout (524).
#    POST starts the run, GET polls every 2s for incremental stdout/stderr.
if [[ -n "${INPUT_COMMAND:-}" ]]; then
  WORKDIR="${INPUT_WORKDIR:-${INPUT_UPLOAD_TO:-/root}}"
  echo "Running command on $VM_ID (workdir=$WORKDIR)..."

  START_RES=$(curl -fsS -X POST -H "$AUTH" -H "User-Agent: $UA" -H "Content-Type: application/json" \
    -d "$(jq -n --arg c "$INPUT_COMMAND" --arg w "$WORKDIR" \
         '{command: $c, workdir: $w, timeoutMs: 1800000}')" \
    "${SUPERJOLT_API_URL%/}/v1/vms/${VM_ID}/exec/async")
  EXEC_ID=$(echo "$START_RES" | jq -r '.execId // ""')
  if [[ -z "$EXEC_ID" ]]; then
    echo "::error::exec/async returned no execId: $START_RES"
    exit 1
  fi

  # Trap SIGTERM/SIGINT (the workflow runner sends these on cancel) so
  # the underlying child gets SIGTERM-then-SIGKILL on vm-init instead
  # of leaking. Best-effort: if the DELETE fails we still exit.
  cleanup_exec() {
    curl -fsS -X DELETE -H "$AUTH" -H "User-Agent: $UA" \
      "${SUPERJOLT_API_URL%/}/v1/vms/${VM_ID}/exec/${EXEC_ID}" >/dev/null 2>&1 || true
  }
  trap 'cleanup_exec; exit 130' INT TERM

  STDOUT_OFFSET=0
  STDERR_OFFSET=0
  EXIT_CODE=-1
  while true; do
    # --retry on transient 5xx (agent restart, brief CF blip) so a
    # single bad poll doesn't fail an otherwise-healthy run mid-stream.
    POLL=$(curl -fsS --retry 5 --retry-delay 1 --retry-all-errors \
      -H "$AUTH" -H "User-Agent: $UA" \
      "${SUPERJOLT_API_URL%/}/v1/vms/${VM_ID}/exec/${EXEC_ID}?stdoutOffset=${STDOUT_OFFSET}&stderrOffset=${STDERR_OFFSET}")
    NEW_STDOUT=$(echo "$POLL" | jq -r '.stdout // ""')
    NEW_STDERR=$(echo "$POLL" | jq -r '.stderr // ""')
    [[ -n "$NEW_STDOUT" ]] && printf '%s' "$NEW_STDOUT"
    [[ -n "$NEW_STDERR" ]] && printf '%s' "$NEW_STDERR" >&2
    # Server returns the NEXT offset — clients are byte-counting-free.
    STDOUT_OFFSET=$(echo "$POLL" | jq -r '.stdoutOffset // 0')
    STDERR_OFFSET=$(echo "$POLL" | jq -r '.stderrOffset // 0')
    STATUS=$(echo "$POLL" | jq -r '.status // "failed"')
    case "$STATUS" in
      running)
        sleep 2
        ;;
      done)
        EXIT_CODE=$(echo "$POLL" | jq -r '.exitCode // -1')
        break
        ;;
      canceled|failed|lost)
        ERR=$(echo "$POLL" | jq -r '.error // ""')
        echo "::error::Remote command ended with status=${STATUS}${ERR:+ (${ERR})}"
        exit 1
        ;;
      *)
        echo "::error::Unexpected exec status: $STATUS"
        exit 1
        ;;
    esac
  done

  trap - INT TERM
  if [[ "$EXIT_CODE" != "0" ]]; then
    echo "::error::Remote command exited with $EXIT_CODE"
    exit "$EXIT_CODE"
  fi
fi

echo "Deploy complete."
