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

# 3. exec command (if provided)
if [[ -n "${INPUT_COMMAND:-}" ]]; then
  WORKDIR="${INPUT_WORKDIR:-${INPUT_UPLOAD_TO:-/root}}"
  echo "Running command on $VM_ID (workdir=$WORKDIR)..."
  EXEC_RES=$(curl -fsS -X POST -H "$AUTH" -H "User-Agent: $UA" -H "Content-Type: application/json" \
    -d "$(jq -n --arg c "$INPUT_COMMAND" --arg w "$WORKDIR" \
         '{command: $c, workdir: $w, timeoutMs: 900000}')" \
    "${SUPERJOLT_API_URL%/}/v1/vms/${VM_ID}/exec")
  STDOUT=$(echo "$EXEC_RES" | jq -r '.stdout // ""')
  STDERR=$(echo "$EXEC_RES" | jq -r '.stderr // ""')
  EXIT_CODE=$(echo "$EXEC_RES" | jq -r '.exitCode // -1')
  if [[ -n "$STDOUT" ]]; then echo "$STDOUT"; fi
  if [[ -n "$STDERR" ]]; then echo "$STDERR" >&2; fi
  if [[ "$EXIT_CODE" != "0" ]]; then
    echo "::error::Remote command exited with $EXIT_CODE"
    exit "$EXIT_CODE"
  fi
fi

echo "Deploy complete."
