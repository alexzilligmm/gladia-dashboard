#!/bin/bash
# ============================================================
# GLADIA HPC Status Push — Installer v5
# ============================================================

set -e

BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# >>> GLADIA HPC STATUS PUSH BEGIN >>>"
MARKER_END="# <<< GLADIA HPC STATUS PUSH END <<<"
DEFAULT_GIST_ID="b917fb214fb459ae61383c650d551c8f"

MODE="${1:-install}"

if [[ "$MODE" == "--uninstall" || "$MODE" == "uninstall" ]]; then
  echo ""
  echo " GLADIA HPC Status Push — Uninstall"
  echo " Target: $BASHRC"
  echo ""

  if [ ! -f "$BASHRC" ]; then
    echo " Nothing to do: $BASHRC does not exist."
    exit 0
  fi

  cp "$BASHRC" "$BASHRC.bak.$(date +%s)"
  echo " ✓ Backed up $BASHRC"

  if grep -q "$MARKER_BEGIN" "$BASHRC"; then
    sed -i "/$MARKER_BEGIN/,/$MARKER_END/d" "$BASHRC"
    echo " ✓ Removed GLADIA install block"
  else
    echo " Nothing to remove: install block not found"
  fi

  echo ""
  echo " Sourcing bashrc..."
  set +e
  source "$BASHRC"
  SRC_RC=$?
  set -e
  if [ $SRC_RC -ne 0 ]; then
    echo " ⚠ .bashrc returned non-zero ($SRC_RC) — continuing anyway"
  fi

  echo ""
  echo " ✓ Uninstall complete"
  echo ""
  echo " Optional cleanup in current shell:"
  echo "   unset HPC_GITHUB_TOKEN HPC_PI_PROJECTS HPC_GIST_ID HPC_GIST_DESCRIPTION"
  echo "   unset -f hpc-push hpc-test hpc-debug hpc-addproject hpc-rmproject"
  exit 0
fi

if [[ "$MODE" != "install" ]]; then
  echo "Usage: $0 [--uninstall]"
  exit 1
fi

cat <<'LOGO'

          ██████╗ ██╗      █████╗ ██████╗ ██╗ █████╗
         ██╔════╝ ██║     ██╔══██╗██╔══██╗██║██╔══██╗
         ██║  ███╗██║     ███████║██║  ██║██║███████║
         ██║   ██║██║     ██╔══██║██║  ██║██║██╔══██║
         ╚██████╔╝███████╗██║  ██║██████╔╝██║██║  ██║
          ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝╚═╝  ╚═╝

          HPC Status Push — Installer v5
          Sapienza University of Rome
          ─────────────────────────────
LOGO

echo " Target: $BASHRC"
echo ""

# ---------- Read existing settings ----------
EXISTING_TOKEN=""
EXISTING_PI=""
EXISTING_GIST_ID="$DEFAULT_GIST_ID"
HAS_PREVIOUS=0

if [ -f "$BASHRC" ] && grep -q "$MARKER_BEGIN" "$BASHRC"; then
  HAS_PREVIOUS=1
  EXISTING_TOKEN=$(grep '^export HPC_GITHUB_TOKEN=' "$BASHRC" | head -1 | sed 's/^export HPC_GITHUB_TOKEN="\(.*\)"$/\1/')
  EXISTING_PI=$(grep '^export HPC_PI_PROJECTS=' "$BASHRC" | head -1 | sed 's/^export HPC_PI_PROJECTS="\(.*\)"$/\1/')
  FOUND_GIST_ID=$(grep '^export HPC_GIST_ID=' "$BASHRC" | head -1 | sed 's/^export HPC_GIST_ID="\(.*\)"$/\1/')
  if [ -n "$FOUND_GIST_ID" ]; then
    EXISTING_GIST_ID="$FOUND_GIST_ID"
  fi
  echo " Previous install detected."
  echo ""
fi

# ---------- Project name normalizer ----------
# Converts portal IDs (IsCd3_M4R / IsBd2_M4R) to saldo IDs (IscrC_M4R / IscrB_M4R)
_normalize_project_name() {
  local NAME="$1"
  if [[ "$NAME" =~ ^Is([CB])[[:alnum:]][[:alnum:]]_(.+)$ ]]; then
    echo "Iscr${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
  else
    echo "$NAME"
  fi
}

_normalize_pi_projects() {
  local INPUT="$1"
  local OUT=""
  for P in $INPUT; do
    local N
    N=$(_normalize_project_name "$P")
    if [ "$N" != "$P" ]; then
      echo "   Normalized: $P → $N" >&2
    fi
    OUT="$OUT $N"
  done
  echo "$OUT" | sed 's/^ //'
}

_extract_gist_id() {
  local INPUT="$1"
  # Accept full gist URL or raw gist id
  echo "$INPUT" | sed -n 's|.*/\([a-fA-F0-9]\{20,40\}\)$|\1|p'
}

if [ -z "$TOKEN" ]; then
  read -p " GitHub token: " TOKEN
fi

# ---------- Optional pinned gist target ----------
# You can pass GIST_LINK or GIST_ID when launching the installer.
if [ -n "$GIST_LINK" ] && [ -z "$GIST_ID" ]; then
  GIST_ID=$(_extract_gist_id "$GIST_LINK")
fi
if [ -n "$GIST_ID" ]; then
  EXISTING_GIST_ID="$GIST_ID"
elif [ -n "$GIST_LINK" ]; then
  echo " ⚠ Could not parse gist id from GIST_LINK='$GIST_LINK' — falling back to auto-discovery"
fi

# ---------- PI Projects ----------
if [ -n "$PI_PROJECTS" ]; then
  :  # already set via env
elif [ -n "$EXISTING_PI" ]; then
  echo " Current PI projects: $EXISTING_PI"
  read -p " PI projects (Enter to keep, new list to replace, '-' to clear): " PI_INPUT
  if [ "$PI_INPUT" = "-" ]; then
    PI_PROJECTS=""
  elif [ -n "$PI_INPUT" ]; then
    PI_PROJECTS="$PI_INPUT"
  else
    PI_PROJECTS="$EXISTING_PI"
  fi
elif [ "$HAS_PREVIOUS" = "1" ]; then
  read -p " PI projects (Enter to skip, or space-separated list): " PI_PROJECTS
else
  read -p " Are you PI of ISCRA projects? List them (e.g. IscrC_eff-SAM2 IscrC_LENS) or Enter to skip: " PI_PROJECTS
fi

# ---------- Normalize portal-style project names ----------
if [ -n "$PI_PROJECTS" ]; then
  PI_PROJECTS=$(_normalize_pi_projects "$PI_PROJECTS")
fi

# ---------- Backup ----------
cp "$BASHRC" "$BASHRC.bak.$(date +%s)"
echo ""
echo " ✓ Backed up $BASHRC"

# ---------- Remove old block ----------
if grep -q "$MARKER_BEGIN" "$BASHRC"; then
  sed -i "/$MARKER_BEGIN/,/$MARKER_END/d" "$BASHRC"
  echo " ✓ Removed previous install block"
fi

# ---------- Part 1: Variables ----------
cat >> "$BASHRC" <<EOF

$MARKER_BEGIN
# GLADIA HPC Status Push v5 · Installed $(date +%F)
export HPC_GITHUB_TOKEN="$TOKEN"
export HPC_PI_PROJECTS="$PI_PROJECTS"
export HPC_GIST_ID="$EXISTING_GIST_ID"
export HPC_GIST_DESCRIPTION="gladia-hpc-status-${USER}"
EOF


# A saldo -r looks like
## ------------------Resources used from 201401 to 202612------------------
# date        username    account              localCluster       num.jobs
#                                                Consumed/h
# ------------------------------------------------------------------------
# 20240916    dmarinci    IscrC_SNav                2:23:44              2
# 20240917    dmarinci    IscrC_SNav              102:42:20             59
# 20240918    dmarinci    IscrC_SNav               59:32:08             10
# 20240919    dmarinci    IscrC_SNav              179:01:52             14
# ...
# 20260415    dmarinci    IscrC_AHNetBio            9:05:06             13
# 20260416    dmarinci    IscrC_AHNetBio            6:30:09              8

# ---------------------Total from 201401 to 202612------------------------
#             username    account              localCluster       num.jobs
#                                                Consumed/h

#             dmarinci    IscrC_LENS             35885:08:46           1277
#             ...
#             dmarinci    IscrC_SNav              5832:01:56            374
# -------------------------------------------------------------------------
#                           Total                66216:07:07           2969

# ---------- Part 2: Functions (quoted heredoc) ----------
cat >> "$BASHRC" <<'HPC_PUSH_FUNCTIONS'

_hpc_build_json() {
  local TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local PI_OF_JSON=""
  if [ -n "$HPC_PI_PROJECTS" ]; then
    PI_OF_JSON=$(echo "$HPC_PI_PROJECTS" | awk '{for(i=1;i<=NF;i++) printf (i>1?",":"") "\"%s\"",$i}')
  fi
  local JOBS_JSON=$(squeue -u "$USER" -o "%i|%u|%P|%j|%T|%M|%D|%R" 2>/dev/null | tail -n +2 | \
    awk -F'|' 'NF>=8 {
      if (count++) printf ",\n";
      printf "    {\"id\":\"%s\",\"user\":\"%s\",\"partition\":\"%s\",\"name\":\"%s\",\"state\":\"%s\",\"time\":\"%s\",\"nodes\":\"%s\",\"nodelist\":\"%s\"}", $1, $2, $3, $4, $5, $6, $7, $8
    }')
  local BUDGETS_JSON=$(saldo -b -n 2>/dev/null | \
    awk 'NF>=7 && $2 ~ /^[0-9]{8}$/ && $3 ~ /^[0-9]{8}$/ {
      if (count++) printf ",\n";
      printf "    {\"account\":\"%s\",\"start\":\"%s\",\"end\":\"%s\",\"total\":%d,\"consumed\":%d,\"percent\":%.1f}", $1, $2, $3, $4, $6, $7
    }')
  local USAGE_JSON=$(saldo -r -u "$USER" 2>/dev/null | \
    awk 'NF>=5 && $1 ~ /^[0-9]{8}$/ {
      if (count++) printf ",\n";
      printf "    {\"date\":\"%s\",\"account\":\"%s\",\"consumed\":\"%s\",\"num_jobs\":%d}", $1, $3, $4, $5
    }')
  cat <<USERJSON
{
  "user": "$USER",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(hostname)",
  "pi_of": [$PI_OF_JSON],
  "jobs": [
$JOBS_JSON
  ],
  "budgets": [
$BUDGETS_JSON
  ],
  "usage": [
$USAGE_JSON
  ]
}
USERJSON
}

_hpc_validate_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json, sys; json.load(sys.stdin)" < "$1" 2>/dev/null
  else
    ! grep -qE ',[[:space:]]*[]}]' "$1"
  fi
}

_hpc_gist_find_id_by_description() {
  local DESCRIPTION="$1"
  curl -s \
    -H "Authorization: token $HPC_GITHUB_TOKEN" \
  "https://api.github.com/gists?per_page=100" | python3 -c '
import json
import sys

desc = sys.argv[1]
try:
  gists = json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)

latest = None
for gist in gists:
  if gist.get("description") != desc:
    continue
  ts = gist.get("updated_at") or gist.get("created_at") or ""
  if latest is None or ts > latest[0]:
    latest = (ts, gist.get("id", ""))

print(latest[1] if latest else "")
' "$DESCRIPTION"
}

_hpc_persist_gist_id() {
  if grep -q '^export HPC_GIST_ID=' "$HOME/.bashrc"; then
    sed -i "s|^export HPC_GIST_ID=\".*\"|export HPC_GIST_ID=\"$HPC_GIST_ID\"|" "$HOME/.bashrc"
  fi
}

_hpc_gist_upsert() {
  local FILENAME="$1"
  local LOCALFILE="$2"

  if [ -z "$HPC_GITHUB_TOKEN" ]; then
    echo "[hpc-push] SKIPPED gist upload: HPC_GITHUB_TOKEN is empty" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[hpc-push] SKIPPED gist upload: python3 is required" >&2
    return 1
  fi

  if ! _hpc_validate_json "$LOCALFILE"; then
    echo "[hpc-push] SKIPPED $FILENAME: invalid JSON" >&2
    return 1
  fi

  local CONTENT
  CONTENT=$(cat "$LOCALFILE")
  local DESC="${HPC_GIST_DESCRIPTION:-gladia-hpc-status-${USER}}"

  if [ -z "$HPC_GIST_ID" ]; then
    HPC_GIST_ID=$(_hpc_gist_find_id_by_description "$DESC")
    if [ -n "$HPC_GIST_ID" ]; then
      export HPC_GIST_ID
      _hpc_persist_gist_id
    fi
  fi

  local PAYLOAD
  PAYLOAD=$(python3 - "$FILENAME" "$CONTENT" "$DESC" <<'PY'
import json
import sys

filename = sys.argv[1]
content = sys.argv[2]
desc = sys.argv[3]
print(json.dumps({
    "description": desc,
    "public": False,
    "files": {filename: {"content": content}},
}))
PY
)

  if [ -z "$HPC_GIST_ID" ]; then
    local CREATE_RESP
    CREATE_RESP=$(curl -s -X POST \
      -H "Authorization: token $HPC_GITHUB_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.github.com/gists" \
      -d "$PAYLOAD")
    local NEW_GIST_ID
    NEW_GIST_ID=$(python3 -c '
  import json
  import sys

  try:
    data = json.load(sys.stdin)
  except Exception:
    print("")
    raise SystemExit(0)
  print(data.get("id", ""))
  ' <<< "$CREATE_RESP")
    if [ -n "$NEW_GIST_ID" ]; then
      export HPC_GIST_ID="$NEW_GIST_ID"
      _hpc_persist_gist_id
    else
      echo "[hpc-push] SKIPPED gist upload: gist creation failed" >&2
      return 1
    fi
  else
    curl -s -X PATCH \
      -H "Authorization: token $HPC_GITHUB_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.github.com/gists/$HPC_GIST_ID" \
      -d "$PAYLOAD" > /dev/null
  fi
}

_hpc_push() {
  local TMPDIR="/tmp/hpc_push_$$"
  mkdir -p "$TMPDIR"
  _hpc_build_json > "$TMPDIR/user.json"
  _hpc_gist_upsert "data_${USER}.json" "$TMPDIR/user.json"
  rm -rf "$TMPDIR"
}

# ---- User-facing commands ----

hpc_debug() {
  echo "=== PARSED budgets ==="
  saldo -b -n 2>/dev/null | awk 'NF>=7 && $2 ~ /^[0-9]{8}$/ && $3 ~ /^[0-9]{8}$/ {printf "  %-22s total=%-7d consumed=%-7d percent=%.1f%%\\n", $1, $4, $6, $7}'
  echo
  echo "=== PARSED usage (daily) ==="
  saldo -r -u "$USER" 2>/dev/null | awk 'NF>=5 && $1 ~ /^[0-9]{8}$/ {printf "  %s  %-22s %s (%d jobs)\\n", $1, $3, $4, $5}'
  echo
  echo "PI projects: ${HPC_PI_PROJECTS:-none}"
  echo "Gist id: ${HPC_GIST_ID:-none}"
}

hpc_test() {
  local OUT=$(_hpc_build_json)
  echo "$OUT"
  echo "---"
  if command -v python3 >/dev/null 2>&1; then
    if echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
      echo "✓ Valid JSON"
    else
      echo "✗ INVALID JSON"
    fi
  fi
}

hpc_addproject() {
  if [ -z "$1" ]; then
    echo "Usage: hpc-addproject IscrC_myproject"
    echo "Current PI projects: ${HPC_PI_PROJECTS:-none}"
    return 1
  fi
  local PROJECT="$1"
  # Normalize portal ID (IsCd3_M4R / IsBd2_M4R) to saldo ID (IscrC_M4R / IscrB_M4R)
  if [[ "$PROJECT" =~ ^Is([CB])[[:alnum:]][[:alnum:]]_(.+)$ ]]; then
    local NORMALIZED="Iscr${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
    echo "  Normalized: $PROJECT → $NORMALIZED"
    PROJECT="$NORMALIZED"
  fi
  # Check if already listed
  if echo " $HPC_PI_PROJECTS " | grep -q " $PROJECT "; then
    echo "Already tracking $PROJECT"
    return 0
  fi
  # Add to current session
  if [ -n "$HPC_PI_PROJECTS" ]; then
    export HPC_PI_PROJECTS="$HPC_PI_PROJECTS $PROJECT"
  else
    export HPC_PI_PROJECTS="$PROJECT"
  fi
  # Persist to bashrc
  sed -i "s|^export HPC_PI_PROJECTS=\".*\"|export HPC_PI_PROJECTS=\"$HPC_PI_PROJECTS\"|" "$HOME/.bashrc"
  echo "✓ Added $PROJECT as PI project"
  echo "  Current: $HPC_PI_PROJECTS"
  echo "  Saved in user metadata for next 'hpc-push'"
}

hpc_rmproject() {
  if [ -z "$1" ]; then
    echo "Usage: hpc-rmproject IscrC_myproject"
    echo "Current PI projects: ${HPC_PI_PROJECTS:-none}"
    return 1
  fi
  local PROJECT="$1"
  # Normalize portal ID so users can remove with either form
  if [[ "$PROJECT" =~ ^Is([CB])[[:alnum:]][[:alnum:]]_(.+)$ ]]; then
    PROJECT="Iscr${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
  fi
  export HPC_PI_PROJECTS=$(echo "$HPC_PI_PROJECTS" | sed "s|$PROJECT||g" | tr -s ' ' | sed 's/^ //;s/ $//')
  sed -i "s|^export HPC_PI_PROJECTS=\".*\"|export HPC_PI_PROJECTS=\"$HPC_PI_PROJECTS\"|" "$HOME/.bashrc"
  echo "✓ Removed $PROJECT"
  echo "  Current: ${HPC_PI_PROJECTS:-none}"
}

hpc_push() {
  ( _hpc_push ) </dev/null >/dev/null 2>&1 &
  disown $! 2>/dev/null
  echo "Pushing in background (~1-2 min)..."
}

# Expose hyphenated commands as aliases for convenience.
alias hpc-push='hpc_push'
alias hpc-test='hpc_test'
alias hpc-debug='hpc_debug'
alias hpc-addproject='hpc_addproject'
alias hpc-rmproject='hpc_rmproject'

# Auto-push on every interactive shell startup (non-blocking, survives shell exit)
if [[ $- == *i* ]]; then
  ( _hpc_push ) </dev/null >/dev/null 2>&1 &
  disown $! 2>/dev/null
fi
HPC_PUSH_FUNCTIONS

cat >> "$BASHRC" <<EOF
$MARKER_END
EOF

chmod 600 "$BASHRC"

echo " ✓ Installed to $BASHRC"
echo " ✓ Permissions: 600"
echo ""
echo " Sourcing bashrc..."
set +e
source "$BASHRC"
SRC_RC=$?
set -e
if [ $SRC_RC -ne 0 ]; then
  echo " ⚠ .bashrc returned non-zero ($SRC_RC) — continuing anyway"
fi

echo " Kicking off initial push in background..."
( _hpc_push ) </dev/null >"$HOME/.hpc-push.log" 2>&1 &
disown $! 2>/dev/null
echo " ✓ Push started — will complete in ~1-2 min"
echo "   (check ~/.hpc-push.log if data doesn't appear on Gist)"
echo ""
echo " ┌─────────────────────────────────────────────────────┐"
echo " │  Remember: this is not a wall of shame 😄           │"
echo " │  It's a wall of fame for those who donate hours     │"
echo " │  to the group. The more you share, the higher you   │"
echo " │  climb on the leaderboard. Give compute, get glory. │"
echo " └─────────────────────────────────────────────────────┘"
echo ""
echo " ┌─────────────────────────────────────────┐"
echo " │  COMMANDS                               │"
echo " ├─────────────────────────────────────────┤"
echo " │  hpc-push       Force push now          │"
echo " │  hpc-test       Preview JSON            │"
echo " │  hpc-debug      Show parsed saldo data  │"
echo " │  hpc-addproject Add a PI project        │"
echo " │  hpc-rmproject  Remove a PI project     │"
echo " └─────────────────────────────────────────┘"
echo ""
echo " PI projects: ${HPC_PI_PROJECTS:-none}"
echo " Auto-push: runs on every login (non-blocking)"
echo " Gist id: ${HPC_GIST_ID:-pending creation on first push}"
echo ""
echo " Check in ~1 min:"
echo "   https://alexzilligmm.github.io/gladia-dashboard"

