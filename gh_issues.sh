#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERR] line:$LINENO" >&2; exit 1' ERR

REPO=${REPO:-}
RATE_LIMIT_SLEEP=${RATE_LIMIT_SLEEP:-2}
MAX_RETRY=${MAX_RETRY:-5}
LEDGER_FILE="issue-tracing.md"

usage() {
  cat <<'USAGE'
Usage: gh_issues.sh [--try-run | --execute | --verify]
  --try-run   Dry run that validates inputs and prints planned actions
  --execute   Create missing GitHub issues after successful dry run
  --verify    Fetch and print issue summary table based on the ledger
USAGE
}

require_mode() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi
  case "$1" in
    --try-run|--execute|--verify)
      MODE="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
}

require_gh() {
  if command -v gh >/dev/null 2>&1; then
    gh --version >/dev/null
    return
  fi
  echo "[INFO] GitHub CLI not found, attempting installation..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update >/dev/null 2>&1; then
      echo "[ERROR] Failed to run apt-get update. Install GitHub CLI manually." >&2
      exit 1
    fi
    if ! apt-get install -y gh >/dev/null 2>&1; then
      echo "[ERROR] Failed to install GitHub CLI. Install it manually and re-run." >&2
      exit 1
    fi
  else
    cat >&2 <<'MSG'
[ERROR] GitHub CLI (gh) is required. Install from https://cli.github.com/ and re-run.
MSG
    exit 1
  fi
  gh --version >/dev/null
}

determine_repo() {
  if [[ -n "$REPO" ]]; then
    CURRENT_REPO="$REPO"
    return
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    local remote
    remote=$(git remote get-url origin)
    case "$remote" in
      https://github.com/*)
        remote=${remote#https://github.com/}
        remote=${remote%.git}
        ;;
      git@github.com:*)
        remote=${remote#git@github.com:}
        remote=${remote%.git}
        ;;
      *)
        remote=""
        ;;
    esac
    if [[ -n "$remote" ]]; then
      CURRENT_REPO="$remote"
      REPO="$remote"
      return
    fi
  fi
  echo "⚠️ No remote repository configured. Please set REPO=<owner>/<repo> and re-run." >&2
  exit 1
}

check_auth() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    return
  fi
  cat >&2 <<'MSG'
[ERROR] GitHub CLI is not authenticated. Run:
  gh auth login --hostname github.com --git-protocol https --scopes repo --web
then re-run this script once authentication succeeds.
MSG
  exit 1
}

lint_csv() {
  python3 - <<'PY'
import csv
import re
from pathlib import Path

path = Path('issues.csv')
if not path.exists():
    print('CSV Lint: FAIL - issues.csv not found')
    raise SystemExit(1)

errors = []
required_headers = ['id', 'title', 'body', 'labels', 'milestone']
with path.open(encoding='utf-8', newline='') as fh:
    reader = csv.DictReader(fh)
    if reader.fieldnames != required_headers:
        errors.append(f'Invalid headers: expected {required_headers}, found {reader.fieldnames}')
    ids = set()
    titles = set()
    pattern_id = re.compile(r'^E\d+-F\d+-I\d+$')
    priority_values = {'priority:P0', 'priority:P1', 'priority:P2'}
    milestone_values = {f'Week {i}' for i in range(1, 5)}
    row_num = 1
    for row in reader:
        row_num += 1
        for key in required_headers:
            if not row.get(key, '').strip():
                errors.append(f'Row {row_num}: {key} is empty')
        issue_id = row.get('id', '')
        if not pattern_id.match(issue_id):
            errors.append(f'Row {row_num}: Invalid ID format {issue_id!r}')
        title = row.get('title', '')
        if not title.startswith(f'{issue_id}: '):
            errors.append(f'Row {row_num}: Title must start with "{issue_id}: "')
        body = row.get('body', '')
        for heading in ('### Summary', '### Scope', '### Acceptance Criteria', '### Notes'):
            if heading not in body:
                errors.append(f'Row {row_num}: Missing heading {heading}')
        labels = row.get('labels', '').split(';')
        if len(labels) != 4:
            errors.append(f'Row {row_num}: Expected 4 labels, found {len(labels)}')
        else:
            expected_prefixes = ['epic:', 'type:', 'priority:', 'area:']
            for label, prefix in zip(labels, expected_prefixes):
                if not label.startswith(prefix):
                    errors.append(f'Row {row_num}: Label {label!r} must start with {prefix}')
                if not re.fullmatch(r'[a-z]+:[A-Za-z0-9]+', label):
                    errors.append(f'Row {row_num}: Label {label!r} must be CamelCase and alphanumeric after colon')
            if labels[2] not in priority_values:
                errors.append(f'Row {row_num}: Priority label {labels[2]!r} is invalid')
        milestone = row.get('milestone', '')
        if milestone not in milestone_values:
            errors.append(f'Row {row_num}: Milestone {milestone!r} is out of range')
        if issue_id in ids:
            errors.append(f'Row {row_num}: Duplicate ID {issue_id}')
        ids.add(issue_id)
        if title in titles:
            errors.append(f'Row {row_num}: Duplicate title {title!r}')
        titles.add(title)

if errors:
    print('CSV Lint: FAIL')
    for err in errors:
        print(f'  - {err}')
    raise SystemExit(1)

print('CSV Lint: PASS')
PY
}

ensure_ledger() {
  if [[ -f "$LEDGER_FILE" ]]; then
    return
  fi
  cat >"$LEDGER_FILE" <<'LEDGER'
# Issue Creation Ledger
| ID | Title | Labels | Milestone | Issue # | State | Timestamp |
|----|-------|--------|-----------|---------|-------|-----------|
LEDGER
}

load_ledger() {
  declare -gA LEDGER_TITLE_BY_ID=()
  declare -gA LEDGER_NUMBER_BY_ID=()
  declare -gA LEDGER_STATE_BY_ID=()
  mapfile -t _LEDGER_DATA < <(
    python3 - <<'PY'
import sys
from pathlib import Path
path = Path('issue-tracing.md')
if not path.exists():
    sys.exit(0)
with path.open(encoding='utf-8') as fh:
    for line in fh:
        line = line.strip()
        if not line.startswith('|') or line.startswith('| ID '):
            continue
        parts = [part.strip() for part in line.strip('|').split('|')]
        if len(parts) < 7:
            continue
        issue_id, title, labels, milestone, number, state, timestamp = parts[:7]
        if issue_id in {'ID', ''}:
            continue
        print(f"{issue_id}|{title}|{labels}|{milestone}|{number}|{state}|{timestamp}")
PY
  )
  for entry in "${_LEDGER_DATA[@]:-}"; do
    IFS='|' read -r lid ltitle llabels lmilestone lnumber lstate lts <<<"$entry"
    LEDGER_TITLE_BY_ID["$lid"]="$ltitle"
    LEDGER_NUMBER_BY_ID["$lid"]="$lnumber"
    LEDGER_STATE_BY_ID["$lid"]="$lstate"
  done
}

collect_labels() {
  mapfile -t UNIQUE_LABELS < <(
    python3 - <<'PY'
import csv
labels = set()
with open('issues.csv', newline='', encoding='utf-8') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        labels.update(label.strip() for label in row['labels'].split(';') if label.strip())
for label in sorted(labels):
    print(label)
PY
  )
}

collect_milestones() {
  mapfile -t UNIQUE_MILESTONES < <(
    python3 - <<'PY'
import csv
milestones = set()
with open('issues.csv', newline='', encoding='utf-8') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        milestones.add(row['milestone'].strip())
for milestone in sorted(milestones):
    print(milestone)
PY
  )
}

gh_with_retry_capture() {
  local __var=$1
  shift
  local attempt=1
  local sleep_time=$RATE_LIMIT_SLEEP
  local output
  while true; do
    if output=$("$@" 2>&1); then
      printf -v "$__var" '%s' "$output"
      return 0
    fi
    local exit_code=$?
    if (( attempt >= MAX_RETRY )); then
      printf -v "$__var" '%s' "$output"
      return $exit_code
    fi
    echo "[WARN] Command failed (exit $exit_code). Retrying in ${sleep_time}s..." >&2
    sleep "$sleep_time"
    attempt=$((attempt+1))
    sleep_time=$((sleep_time*2))
  done
}

ensure_labels() {
  local mode="$1"
  local existing_json
  if ! gh_with_retry_capture existing_json gh label list --repo "$CURRENT_REPO" --limit 1000 --json name; then
    existing_json='[]'
  fi
  mapfile -t existing < <(printf '%s' "$existing_json" | python3 - <<'PY'
import json
import sys
payload = sys.stdin.read().strip()
if not payload:
    sys.exit(0)
data = json.loads(payload)
for item in data:
    print(item['name'])
PY
  )
  declare -A existing_map=()
  for name in "${existing[@]:-}"; do
    existing_map["$name"]=1
  done
  for label in "${UNIQUE_LABELS[@]}"; do
    if [[ -n "${existing_map[$label]:-}" ]]; then
      continue
    fi
    if [[ "$mode" == "--try-run" ]]; then
      echo "[DRY-RUN] would create label $label"
    else
      local color desc
      case "$label" in
        epic:*) color="1D76DB"; desc="Epic categorization" ;;
        type:*) color="5319E7"; desc="Work type" ;;
        priority:*) color="B60205"; desc="Priority" ;;
        area:*) color="0E8A16"; desc="Functional area" ;;
        *) color="CCCCCC"; desc="Auto-created label" ;;
      esac
      gh label create "$label" --repo "$CURRENT_REPO" --color "$color" --description "$desc" >/dev/null
      echo "[INFO] Created label $label"
    fi
  done
}

ensure_milestones() {
  local mode="$1"
  local milestones_json
  if ! gh_with_retry_capture milestones_json gh api repos/"$CURRENT_REPO"/milestones -f state=all --paginate; then
    milestones_json='[]'
  fi
  mapfile -t milestone_lines < <(printf '%s' "$milestones_json" | python3 - <<'PY'
import json
import sys
payload = sys.stdin.read().strip()
if not payload:
    sys.exit(0)
data = json.loads(payload)
if isinstance(data, dict):
    data = [data]
for item in data:
    print(f"{item['title']}|{item['state']}|{item['number']}")
PY
  )
  declare -A milestone_state=()
  declare -A milestone_number=()
  for line in "${milestone_lines[@]:-}"; do
    IFS='|' read -r title state number <<<"$line"
    milestone_state["$title"]="$state"
    milestone_number["$title"]="$number"
  done
  for milestone in "${UNIQUE_MILESTONES[@]}"; do
    if [[ -z "${milestone_state[$milestone]:-}" ]]; then
      if [[ "$mode" == "--try-run" ]]; then
        echo "[DRY-RUN] would create milestone $milestone"
      else
        gh api repos/"$CURRENT_REPO"/milestones -f title="$milestone" >/dev/null
        echo "[INFO] Created milestone $milestone"
      fi
    elif [[ "${milestone_state[$milestone]}" == "closed" && "$mode" == "--execute" ]]; then
      gh api repos/"$CURRENT_REPO"/milestones/"${milestone_number[$milestone]}" -X PATCH -f state=open >/dev/null
      echo "[INFO] Reopened milestone $milestone"
    fi
  done
}

load_issue_rows() {
  TMP_ISSUES=$(mktemp)
  python3 - <<'PY' >"$TMP_ISSUES"
import csv
import base64
with open('issues.csv', newline='', encoding='utf-8') as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        body_b64 = base64.b64encode(row['body'].encode('utf-8')).decode('ascii')
        labels = ';'.join(label.strip() for label in row['labels'].split(';'))
        print('\t'.join([row['id'], row['title'], body_b64, labels, row['milestone']]))
PY
}

search_issue() {
  local title="$1"
  local query response parsed
  local escaped_title
  escaped_title=$(printf '%s' "$title" | sed 's/"/\\"/g')
  printf -v query 'repo:%s in:title "%s"' "$CURRENT_REPO" "$escaped_title"
  if ! gh_with_retry_capture response gh api search/issues -f q="$query" --paginate; then
    return 1
  fi
  parsed=$(printf '%s' "$response" | python3 - "$title" <<'PY'
import json, sys
import itertools

title = sys.argv[1]
payload = sys.stdin.read()
if not payload.strip():
    sys.exit(0)
data = json.loads(payload)
items = data.get('items', []) if isinstance(data, dict) else []
for item in items:
    if item.get('title') == title:
        print(f"{item['number']}|{item['state']}")
        break
PY
)
  if [[ -n "$parsed" ]]; then
    IFS='|' read -r SEARCH_NUMBER SEARCH_STATE <<<"$parsed"
    return 0
  fi
  return 1
}

append_ledger() {
  local id="$1" title="$2" labels="$3" milestone="$4" number="$5" state="$6"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$title" "$labels" "$milestone" "$number" "$state" "$timestamp" >>"$LEDGER_FILE"
}

try_run() {
  ensure_labels --try-run
  ensure_milestones --try-run
  load_issue_rows
  local planned=0 skipped=0
  while IFS=$'\t' read -r id title body_b64 labels milestone; do
    if [[ -n "${LEDGER_TITLE_BY_ID[$id]:-}" ]]; then
      echo "SKIP (ledger): $title"
      ((skipped++))
      continue
    fi
    if search_issue "$title"; then
      echo "SKIP (github): $title (Issue #$SEARCH_NUMBER)"
      ((skipped++))
      continue
    fi
    echo "CREATE: $title (milestone: $milestone)"
    ((planned++))
  done <"$TMP_ISSUES"
  rm -f "$TMP_ISSUES"
  echo "Summary: Created=0, Planned=$planned, Skipped=$skipped, Failed=0"
}

execute_run() {
  ensure_labels --execute
  ensure_milestones --execute
  load_issue_rows
  local created=0 skipped=0 failed=0
  while IFS=$'\t' read -r id title body_b64 labels milestone; do
    if [[ -n "${LEDGER_TITLE_BY_ID[$id]:-}" ]]; then
      echo "SKIP (ledger): $title"
      ((skipped++))
      continue
    fi
    if search_issue "$title"; then
      echo "SKIP (github): $title (Issue #$SEARCH_NUMBER)"
      ((skipped++))
      continue
    fi
    local body
    body=$(printf '%s' "$body_b64" | base64 --decode)
    local body_file
    body_file=$(mktemp)
    printf '%s' "$body" >"$body_file"
    IFS=';' read -r -a label_array <<<"$labels"
    local output
    local create_args=(gh issue create --repo "$CURRENT_REPO" --title "$title" --milestone "$milestone" --body-file "$body_file")
    for lbl in "${label_array[@]}"; do
      create_args+=(--label "$lbl")
    done
    create_args+=(--json number,state)
    create_args+=(--jq '"\(.number)|\(.state)"')
    if gh_with_retry_capture output "${create_args[@]}"; then
      IFS='|' read -r issue_number issue_state <<<"$output"
      echo "CREATED Issue #$issue_number for $title"
      append_ledger "$id" "$title" "$labels" "$milestone" "$issue_number" "$issue_state"
      ((created++))
    else
      echo "[ERROR] Failed to create $title" >&2
      echo "$output" >&2
      ((failed++))
    fi
    rm -f "$body_file"
  done <"$TMP_ISSUES"
  rm -f "$TMP_ISSUES"
  echo "Summary: Created=$created, Skipped=$skipped, Failed=$failed"
  if (( failed > 0 )); then
    exit 1
  fi
}

verify_run() {
  printf '| ID | Title | Labels | Milestone | Issue # | State |\n'
  printf '|----|-------|--------|-----------|---------|-------|\n'
  python3 - "$CURRENT_REPO" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
repo = sys.argv[1]
path = Path('issue-tracing.md')
if not path.exists():
    sys.exit(0)
rows = []
with path.open(encoding='utf-8') as fh:
    for line in fh:
        line=line.strip()
        if not line.startswith('|') or line.startswith('| ID '):
            continue
        parts=[p.strip() for p in line.strip('|').split('|')]
        if len(parts) < 7:
            continue
        rows.append(parts[:7])
for issue_id, title, labels, milestone, number, state, timestamp in rows:
    if not number or number == 'Issue #':
        continue
    cmd = ['gh', 'issue', 'view', number, '--repo', repo, '--json', 'number,state', '--jq', '\"\\(.number)|\\(.state)\"']
    try:
        output = subprocess.check_output(cmd, text=True).strip()
        if output:
            number_val, state_val = output.split('|', 1)
        else:
            number_val, state_val = number, state
    except subprocess.CalledProcessError:
        number_val, state_val = number, state
    print(f"| {issue_id} | {title} | {labels} | {milestone} | {number_val} | {state_val} |")
PY
}

main() {
  require_mode "$@"
  require_gh
  determine_repo
  check_auth
  lint_csv
  ensure_ledger
  load_ledger
  collect_labels
  collect_milestones
  case "$MODE" in
    --try-run)
      try_run
      ;;
    --execute)
      execute_run
      ;;
    --verify)
      verify_run
      ;;
  esac
}

main "$@"
