#!/bin/sh
set -eu

ENV_FILE="${ROMEO_AGENT_ENV_FILE:-$HOME/.config/romeo-agent-openclaw/romeo-agent-openclaw.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

cd "$(dirname "$0")/.."
exec node src/server.mjs
