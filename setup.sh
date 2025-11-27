#!/usr/bin/env bash
# setup.sh — create + activate venv, install requirements if missing, and start MongoDB docker-compose
# Intended to be SOURCED:  . ./setup.sh
#
# If you accidentally run with `bash setup.sh`, the script will still run but venv activation
# won't persist in your interactive shell. Prefer:  . ./setup.sh

# -------------------------
# Helper functions
# -------------------------
_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

_info() { printf "👉 %s\n" "$1"; }
_warn() { printf "⚠️  %s\n" "$1"; }
_err()  { printf "❌ %s\n" "$1" >&2; }

# -------------------------
# Ensure script is sourced
# -------------------------
# When sourced, $0 is the parent shell and $BASH_SOURCE[0] is the filename.
# If run rather than sourced, give a friendly warning.
if [ "$0" = "$BASH_SOURCE" ]; then
  _warn "You ran the script instead of sourcing it. To keep the venv activated in this shell run:  . ./setup.sh"
fi

# -------------------------
# 1) Setup Python binary choice
# -------------------------
PYBIN=""
if _cmd_exists python3; then
  PYBIN=python3
elif _cmd_exists python; then
  PYBIN=python
else
  _err "Python is not installed or not on PATH. Install Python 3 and retry."
  return 1 2>/dev/null || exit 1
fi

# -------------------------
# 2) Create & activate venv if needed
# -------------------------
VENV_DIR=".venv"

if [ -n "$VIRTUAL_ENV" ]; then
  _info "Virtualenv already active: $VIRTUAL_ENV"
else
  if [ ! -d "$VENV_DIR" ]; then
    _info "Creating virtual environment at .venv using $PYBIN ..."
    "$PYBIN" -m venv "$VENV_DIR" || { _err "Failed to create venv"; return 1 2>/dev/null || exit 1; }
  else
    _info "Using existing virtual environment at $VENV_DIR"
  fi

  # Activate in current shell
  if [ -f "$VENV_DIR/bin/activate" ]; then
    # shellcheck disable=SC1090
    . "$VENV_DIR/bin/activate"
    _info "Activated virtualenv: $VIRTUAL_ENV"
  else
    _err "Activate script not found at $VENV_DIR/bin/activate"
    return 1 2>/dev/null || exit 1
  fi
fi

# Ensure pip is available now
if ! _cmd_exists pip; then
  _err "pip not available inside virtualenv. Ensure venv activation worked."
  return 1 2>/dev/null || exit 1
fi

# -------------------------
# 3) Install requirements (only missing packages)
# -------------------------
REQ_FILE="requirements.txt"
if [ ! -f "$REQ_FILE" ]; then
  _warn "No requirements.txt found at repo root. Skipping pip install."
else
  _info "Checking requirements in $REQ_FILE ..."

  # read non-empty non-comment lines
  missing_pkgs=""
  while IFS= read -r line || [ -n "$line" ]; do
    pkg="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # skip comments & empty
    case "$pkg" in
      ""|\#*) continue;;
    esac

    # Extract simple package name before version specifiers (handles "pymongo==4.3", "pkg>=1.2")
    pkgname="$(printf '%s' "$pkg" | sed 's/[<=>!~].*$//')"
    pkgname="$(printf '%s' "$pkgname" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')"

    # Map some common package -> import name if needed (pypi name differs)
    import_name="$pkgname"
    case "$pkgname" in
      pymongo) import_name="pymongo";;
      google-cloud-storage) import_name="google.cloud.storage";;
      google-cloud-pubsub) import_name="google.cloud.pubsub";;
      *) import_name="$pkgname";;
    esac

    # Try to import using Python — if import fails, mark as missing
    if ! python - <<PYTEST 2>/dev/null
try:
    import importlib
    importlib.import_module("${import_name}")
    print("OK")
except Exception:
    raise SystemExit(1)
PYTEST
    then
      missing_pkgs="${missing_pkgs}${pkg} "
    else
      _info "Already installed: $pkgname"
    fi
  done < "$REQ_FILE"

  if [ -n "$missing_pkgs" ]; then
    _info "Installing missing packages: $missing_pkgs"
    pip install $missing_pkgs || { _err "pip install failed"; return 1 2>/dev/null || exit 1; }
  else
    _info "All required packages already installed."
  fi
fi

# -------------------------
# 4) Start MongoDB via docker compose if not running
# -------------------------
# Try multiple docker-compose invocations: prefer modern `docker compose`, fallback to `docker-compose`
_start_compose() {
  if _cmd_exists docker; then
    # Check whether 'docker compose' is available
    if docker compose version >/dev/null 2>&1; then
      docker compose up -d
      return $?
    elif _cmd_exists docker-compose; then
      docker-compose up -d
      return $?
    else
      _err "Docker is installed but docker compose plugin / docker-compose not found."
      return 2
    fi
  else
    _err "Docker is not installed or not on PATH. Install Docker and retry."
    return 1
  fi
}

# Check if the mongo container is present and running
_container_is_running() {
  # first try docker compose ps for named service 'mongo'
  if _cmd_exists docker && docker compose ps -q mongo >/dev/null 2>&1; then
    cid="$(docker compose ps -q mongo 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      # check status
      if docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true; then
        return 0
      fi
    fi
  fi

  # try docker ps filter by name 'mongo-lab'
  if _cmd_exists docker; then
    if docker ps --filter "name=mongo-lab" --format '{{.Names}}' | grep -q .; then
      # container with that name exists and is running
      return 0
    fi
  fi

  return 1
}

if _container_is_running; then
  _info "MongoDB docker container already running (mongo-lab)."
else
  _info "MongoDB container not running — attempting to start with docker compose ..."
  if _start_compose; then
    _info "docker compose started. Waiting for MongoDB to become ready (10s) ..."
    sleep 10
    if _container_is_running; then
      _info "MongoDB container is up."
    else
      _warn "Docker compose started but mongo container not detected as running. Check 'docker compose logs' for errors."
    fi
  else
    _err "Failed to start docker compose. See errors above."
    return 1 2>/dev/null || exit 1
  fi
fi

_info "Setup complete. Virtualenv active at: ${VIRTUAL_ENV:-none}"
# don't exit — allow the sourced shell to continue
return 0 2>/dev/null || true
