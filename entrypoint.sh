#!/bin/bash
set -euo pipefail

LISTEN_PORT="${PORT:-8080}"
INTERNAL_PORT="${PADDLEOCR_INTERNAL_PORT:-8081}"
PIPELINE="${PADDLEOCR_PIPELINE:-OCR}"
PADDLEOCR_USERNAME="${PADDLEOCR_USERNAME:-admin}"

# ---------------------------------------------------------------------------
# Fail closed on the proxy credential
# ---------------------------------------------------------------------------
# PaddleX serving has no authentication of its own. An open OCR endpoint is
# free compute for anyone who finds the URL, so the credential in front of it
# is the only gate and the container refuses to start without one.
if [ -z "${PADDLEOCR_PASSWORD:-}" ] || [ "${#PADDLEOCR_PASSWORD}" -lt 12 ]; then
    echo "FATAL: PADDLEOCR_PASSWORD is empty or shorter than 12 characters." >&2
    echo "  It is the only credential protecting this deployment: PaddleX serving" >&2
    echo "  has no authentication, so without it anyone who finds the URL can run" >&2
    echo "  inference on your instance. The template generates a password; read it" >&2
    echo "  from the service's Variables tab." >&2
    exit 1
fi

# Hashed through stdin rather than --plaintext so the password never appears
# in this container's argv and cannot be read out of `ps`.
PADDLEOCR_PASSWORD_HASH="$(printf '%s\n' "${PADDLEOCR_PASSWORD}" | caddy hash-password)"
unset PADDLEOCR_PASSWORD
export PADDLEOCR_PASSWORD_HASH PADDLEOCR_USERNAME
export PORT="${LISTEN_PORT}" PADDLEOCR_INTERNAL_PORT="${INTERNAL_PORT}"

echo "paddleocr: pipeline '${PIPELINE}', models from ${PADDLE_PDX_CACHE_HOME:-~/.paddlex}"
echo "paddleocr: serving on 0.0.0.0:${LISTEN_PORT} behind basic auth as '${PADDLEOCR_USERNAME}'"

# ---------------------------------------------------------------------------
# Inference server on loopback, proxy in front
# ---------------------------------------------------------------------------
# PaddleX defaults to --host 0.0.0.0; it is pinned to loopback here so the
# unauthenticated API has no public interface at all and the only route in is
# through Caddy.
paddlex --serve --pipeline "${PIPELINE}" --host 127.0.0.1 --port "${INTERNAL_PORT}" &
PADDLE_PID=$!

# Caddy starts only once inference answers, so Railway's healthcheck cannot
# report the deployment live while requests would still fail.
ready=""
for _ in $(seq 1 240); do
    if python3 - "$INTERNAL_PORT" <<'PY' 2>/dev/null
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=2)
except urllib.error.HTTPError:
    pass  # any HTTP status means the server is answering
sys.exit(0)
PY
    then ready=1; break; fi
    if ! kill -0 "${PADDLE_PID}" 2>/dev/null; then
        echo "FATAL: the inference server exited during startup." >&2
        exit 1
    fi
    sleep 1
done
if [ -z "${ready}" ]; then
    echo "FATAL: inference did not answer on 127.0.0.1:${INTERNAL_PORT} within 240s." >&2
    exit 1
fi
echo "paddleocr: inference ready, warming the model"

# One throwaway inference so the first real request does not pay for loading
# the weights into memory. Measured locally: 98s cold versus ~4s warm. Failure
# here is not fatal - a slow first request beats refusing to start.
python3 /usr/local/bin/warmup.py "$INTERNAL_PORT" || \
    echo "paddleocr: warmup request failed, continuing" >&2
echo "paddleocr: model warm, starting proxy"

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Forward SIGTERM to both children. Without this the shell sits in `wait` and
# every redeploy ends in SIGKILL instead of a clean stop.
shutdown() {
    echo "paddleocr: signal received, stopping both processes" >&2
    kill -TERM "${PADDLE_PID}" "${CADDY_PID}" 2>/dev/null || true
    wait "${PADDLE_PID}" 2>/dev/null || true
    wait "${CADDY_PID}" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# Either process dying takes the container down so Railway's ALWAYS policy
# restarts it, rather than leaving the proxy serving 502s.
wait -n "${PADDLE_PID}" "${CADDY_PID}"
status=$?
echo "paddleocr: a supervised process exited (status ${status}); shutting down" >&2
kill "${PADDLE_PID}" "${CADDY_PID}" 2>/dev/null || true
exit "${status:-1}"
