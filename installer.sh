#!/bin/bash
# ============================================================
# GLADIA HPC Status Push — Installer v5
# ============================================================

set -e

BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# >>> GLADIA HPC STATUS PUSH BEGIN >>>"
MARKER_END="# <<< GLADIA HPC STATUS PUSH END <<<"

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
HAS_PREVIOUS=0

if [ -f "$BASHRC" ] && grep -q "$MARKER_BEGIN" "$BASHRC"; then
  HAS_PREVIOUS=1
  EXISTING_TOKEN=$(grep '^export HPC_GITHUB_TOKEN=' "$BASHRC" | head -1 | sed 's/^export HPC_GITHUB_TOKEN="\(.*\)"$/\1/')
  EXISTING_PI=$(grep '^export HPC_PI_PROJECTS=' "$BASHRC" | head -1 | sed 's/^export HPC_PI_PROJECTS="\(.*\)"$/\1/')
  echo " Previous install detected."
  echo ""
fi

# ---------- Project name normalizer ----------
# Converts portal IDs (IsCd3_M4R) to saldo IDs (IscrC_M4R)
_normalize_project_name() {
  local NAME="$1"
  if [[ "$NAME" =~ ^IsC[a-zA-Z][0-9]_(.+)$ ]]; then
    echo "IscrC_${BASH_REMATCH[1]}"
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

if [ -z "$TOKEN" ]; then
  read -p " GitHub token: " TOKEN
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
export HPC_GITHUB_REPO="alexzilligmm/gladia-dashboard"
export HPC_PI_PROJECTS="$PI_PROJECTS"
EOF

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
    awk '/^Iscr/ && NF>=7 {
      if (count++) printf ",\n";
      printf "    {\"account\":\"%s\",\"start\":\"%s\",\"end\":\"%s\",\"total\":%d,\"consumed\":%d,\"percent\":%.1f}", $1, $2, $3, $4, $6, $7
    }')
  local USAGE_JSON=$(saldo -r -u "$USER" -t 2>/dev/null | \
    awk 'NF==4 && $2 ~ /^Iscr/ {
      if (count++) printf ",\n";
      printf "    {\"account\":\"%s\",\"consumed\":\"%s\",\"num_jobs\":%d}", $2, $3, $4
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

_hpc_build_project_json() {
  local PROJECT="$1"
  local TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local MEMBERS_JSON=$(saldo -r -a "$PROJECT" -t 2>/dev/null | \
    awk 'NF==4 && $2 ~ /^Iscr/ {
      if (count++) printf ",\n";
      printf "    {\"user\":\"%s\",\"account\":\"%s\",\"consumed\":\"%s\",\"num_jobs\":%d}", $1, $2, $3, $4
    }')
  cat <<PROJJSON
{
  "account": "$PROJECT",
  "pi": "$USER",
  "timestamp": "$TIMESTAMP",
  "members": [
$MEMBERS_JSON
  ]
}
PROJJSON
}

_hpc_validate_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json, sys; json.load(sys.stdin)" < "$1" 2>/dev/null
  else
    ! grep -qE ',[[:space:]]*[]}]' "$1"
  fi
}

_hpc_github_push() {
  local FILEPATH="$1"
  local LOCALFILE="$2"
  if ! _hpc_validate_json "$LOCALFILE"; then
    echo "[hpc-push] SKIPPED $FILEPATH: invalid JSON" >&2
    return 1
  fi
  local CONTENT=$(base64 -w 0 "$LOCALFILE")
  local SHA=$(curl -s \
    -H "Authorization: token $HPC_GITHUB_TOKEN" \
    "https://api.github.com/repos/$HPC_GITHUB_REPO/contents/$FILEPATH" \
    | grep '"sha"' | head -1 | cut -d'"' -f4)
  local BODY
  if [ -n "$SHA" ]; then
    BODY="{\"message\":\"${USER} $(date +%F_%T) ${FILEPATH}\",\"content\":\"${CONTENT}\",\"sha\":\"${SHA}\"}"
  else
    BODY="{\"message\":\"${USER} $(date +%F_%T) ${FILEPATH}\",\"content\":\"${CONTENT}\"}"
  fi
  curl -s -X PUT \
    -H "Authorization: token $HPC_GITHUB_TOKEN" \
    "https://api.github.com/repos/$HPC_GITHUB_REPO/contents/$FILEPATH" \
    -d "$BODY" > /dev/null
}

_hpc_push() {
  local TMPDIR="/tmp/hpc_push_$$"
  mkdir -p "$TMPDIR"
  _hpc_build_json > "$TMPDIR/user.json"
  _hpc_github_push "data/${USER}.json" "$TMPDIR/user.json"
  if [ -n "$HPC_PI_PROJECTS" ]; then
    for PROJECT in $HPC_PI_PROJECTS; do
      _hpc_build_project_json "$PROJECT" > "$TMPDIR/project.json"
      _hpc_github_push "projects/${PROJECT}.json" "$TMPDIR/project.json"
    done
  fi
  rm -rf "$TMPDIR"
}

# ---- User-facing commands ----

hpc-debug() {
  echo "=== PARSED budgets ==="
  saldo -b -n 2>/dev/null | awk '/^Iscr/ && NF>=7 {printf "  %-22s total=%-7d consumed=%-7d percent=%.1f%%\n", $1, $4, $6, $7}'
  echo
  echo "=== PARSED usage ==="
  saldo -r -u "$USER" -t 2>/dev/null | awk 'NF==4 && $2 ~ /^Iscr/ {printf "  %-22s %s (%d jobs)\n", $2, $3, $4}'
  echo
  echo "PI projects: ${HPC_PI_PROJECTS:-none}"
}

hpc-test() {
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

hpc-addproject() {
  if [ -z "$1" ]; then
    echo "Usage: hpc-addproject IscrC_myproject"
    echo "Current PI projects: ${HPC_PI_PROJECTS:-none}"
    return 1
  fi
  local PROJECT="$1"
  # Normalize portal ID (IsCd3_M4R) to saldo ID (IscrC_M4R)
  if [[ "$PROJECT" =~ ^IsC[a-zA-Z][0-9]_(.+)$ ]]; then
    local NORMALIZED="IscrC_${BASH_REMATCH[1]}"
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
  echo "  Will push project report on next login or 'hpc-push'"
}

hpc-rmproject() {
  if [ -z "$1" ]; then
    echo "Usage: hpc-rmproject IscrC_myproject"
    echo "Current PI projects: ${HPC_PI_PROJECTS:-none}"
    return 1
  fi
  local PROJECT="$1"
  # Normalize portal ID so users can remove with either form
  if [[ "$PROJECT" =~ ^IsC[a-zA-Z][0-9]_(.+)$ ]]; then
    PROJECT="IscrC_${BASH_REMATCH[1]}"
  fi
  export HPC_PI_PROJECTS=$(echo "$HPC_PI_PROJECTS" | sed "s|$PROJECT||g" | tr -s ' ' | sed 's/^ //;s/ $//')
  sed -i "s|^export HPC_PI_PROJECTS=\".*\"|export HPC_PI_PROJECTS=\"$HPC_PI_PROJECTS\"|" "$HOME/.bashrc"
  echo "✓ Removed $PROJECT"
  echo "  Current: ${HPC_PI_PROJECTS:-none}"
}

hpc-push() {
  ( _hpc_push ) </dev/null >/dev/null 2>&1 &
  disown $! 2>/dev/null
  echo "Pushing in background (~1-2 min)..."
}

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

echo " Running initial push..."
if _hpc_push; then
  echo " ✓ Initial push complete"
else
  echo " ⚠ Initial push failed — run 'hpc-push' manually after checking 'hpc-debug'"
fi


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
echo ""
echo " Check in ~1 min:"
echo "   https://github.com/alexzilligmm/gladia-dashboard/tree/main/data"

