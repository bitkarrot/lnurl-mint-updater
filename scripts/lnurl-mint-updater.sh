#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONFIG=${CONFIG:-/etc/lnurl-mint-updater.env}
[[ -r "$CONFIG" ]] && # shellcheck disable=SC1090
  source "$CONFIG"

REPO_URL=${REPO_URL:-https://github.com/dni/lnurl-mint.git}
BRANCH=${BRANCH:-main}
APP_DIR=${APP_DIR:-/opt/lnurl-mint}
STATE_DIR=${STATE_DIR:-/var/lib/lnurl-mint-updater}
LOG_DIR=${LOG_DIR:-/var/log/lnurl-mint-updater}
SERVICE=${SERVICE:-lnurl-mint.service}
MODEL_ENDPOINT=${MODEL_ENDPOINT:-https://llm.int.exe.xyz/v1/chat/completions}
MODEL=${MODEL:-fireworks/glm-5p2}
AUTO_DEPLOY=${AUTO_DEPLOY:-false}

mkdir -p "$STATE_DIR" "$LOG_DIR"
# Allow the non-root test user to traverse the staging directory only.
chown root:lnurl-mint "$STATE_DIR"
chmod 0710 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$LOG_DIR/$stamp.log"
exec > >(tee -a "$log") 2>&1

say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { say "ERROR: $*"; exit 1; }

work="$STATE_DIR/work"
rm -rf "$work"
mkdir -p "$work"
if [[ -d "$work/repo/.git" ]]; then
  git -C "$work/repo" fetch --quiet origin "$BRANCH"
else
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$work/repo"
fi
remote=$(git -C "$work/repo" rev-parse "origin/$BRANCH")
current=$(cat "$STATE_DIR/deployed-revision" 2>/dev/null || git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || true)

say "repository=$REPO_URL branch=$BRANCH remote=$remote current=${current:-unknown}"
if [[ -n "$current" && "$remote" == "$current" ]]; then
  say 'No upstream change.'
  systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8111/ >/dev/null || fail 'mint health check failed'
  exit 0
fi

git -C "$work/repo" diff --stat "${current:-$remote}" "$remote" 2>/dev/null || true
git -C "$work/repo" log --format='%h %ad %s' --date=short "${current:-$remote}..$remote" 2>/dev/null | head -30 || true

# Keep the LLM advisory-only: it receives source diff metadata, never secrets or tools.
if [[ "${MODEL_REVIEW:-true}" == true ]]; then
  summary=$(git -C "$work/repo" diff --no-ext-diff --unified=1 "${current:-$remote}" "$remote" -- ':!uv.lock' 2>/dev/null | head -c 50000 || true)
  prompt=$(python3 - "$summary" <<'PY'
import json, sys
print(json.dumps({"model": "MODEL", "messages": [{"role": "system", "content": "You are a cautious release reviewer. Review this proposed lnurl-mint update. Identify breaking changes, migration or payment-risk concerns, and give a recommendation: REVIEW, DEPLOY, or HOLD. Do not assume tests pass."}, {"role": "user", "content": sys.argv[1]}], "temperature": 0, "max_tokens": 400}))
PY
)
  prompt=${prompt/\"MODEL\"/\"$MODEL\"}
  curl --fail --silent --show-error --max-time 120 "$MODEL_ENDPOINT" \
    -H 'Content-Type: application/json' -d "$prompt" >"$LOG_DIR/$stamp.model.json" || say 'model review unavailable; continuing with deterministic checks'
fi

if [[ "$AUTO_DEPLOY" != true ]]; then
  say 'Update detected; AUTO_DEPLOY is not true, so this run is audit-only.'
  exit 0
fi

# Deploy only after a complete backup, isolated test, and a service health check.
backup_root=/var/backups/lightning-stack/lnurl-mint-updater
mkdir -p "$backup_root"
backup="$backup_root/$stamp"
mkdir -p "$backup"
systemctl stop "$SERVICE"
trap 'systemctl start "$SERVICE" >/dev/null 2>&1 || true' EXIT
install -m 0600 /var/lib/lnurl-mint/mint.db "$backup/mint.db"
sqlite3 "$backup/mint.db" 'PRAGMA integrity_check;' | grep -qx ok || fail 'mint backup integrity check failed'

uv sync --frozen --project "$work/repo"
# Tests execute as the application user, not root: upstream tests are untrusted code.
install -d -o lnurl-mint -g lnurl-mint -m 0750 "$work/cache"
chown -R lnurl-mint:lnurl-mint "$work"
runuser -u lnurl-mint -- env HOME=/var/lib/lnurl-mint UV_CACHE_DIR="$work/cache" \
  uv run --project "$work/repo" pytest -q "$work/repo/tests"

new_dir="$APP_DIR.$stamp"
old_dir="$APP_DIR.previous"
rsync -a --delete --exclude .git --exclude .venv "$work/repo/" "$new_dir/"
rsync -a --delete "$work/repo/.venv/" "$new_dir/.venv/"
if [[ -f "$work/repo/uvicorn-log-config.json" ]]; then
  install -m 0644 -o lnurl-mint -g lnurl-mint "$work/repo/uvicorn-log-config.json" "$new_dir/uvicorn-log-config.json"
elif [[ -f "$APP_DIR/uvicorn-log-config.json" ]]; then
  # This deployment-local file is not tracked by upstream.
  install -m 0644 -o lnurl-mint -g lnurl-mint "$APP_DIR/uvicorn-log-config.json" "$new_dir/uvicorn-log-config.json"
elif [[ -f "$old_dir/uvicorn-log-config.json" ]]; then
  install -m 0644 -o lnurl-mint -g lnurl-mint "$old_dir/uvicorn-log-config.json" "$new_dir/uvicorn-log-config.json"
else
  fail 'uvicorn-log-config.json is missing from upstream and current deployment'
fi
chown -R lnurl-mint:lnurl-mint "$new_dir"
chmod 0750 "$new_dir"
rm -rf "$old_dir"
mv "$APP_DIR" "$old_dir"
mv "$new_dir" "$APP_DIR"
chown -R lnurl-mint:lnurl-mint "$APP_DIR"

git -C "$work/repo" rev-parse "$remote" > "$STATE_DIR/deployed-revision"
systemctl start "$SERVICE"
trap - EXIT
sleep 3
systemctl is-active --quiet "$SERVICE" || { mv "$APP_DIR" "$new_dir.failed"; mv "$old_dir" "$APP_DIR"; systemctl restart "$SERVICE"; fail 'new service failed; rolled back'; }
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8111/ >/dev/null || fail 'new mint health check failed'
say "Deployed $remote successfully; backup=$backup"
