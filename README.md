# PaddleOCR on Railway

[PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) — turn any image or PDF into structured text,
in 100+ languages — as an HTTP API on Railway, behind a generated password. No GPU required.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/paddleocr)

## Services

| Process | Base | Public | Role |
|---|---|---|---|
| `caddy` | `caddy:2.11.4` (binary) | **yes** | The only public listener. Holds the credential, proxies to inference. |
| `paddlex --serve` | `paddlepaddle` 3.3.1 + `paddlex` 3.7.2 | no | The OCR pipeline. Stays on `127.0.0.1`. |

One container, **no volume** — the service is stateless and the model weights are baked into the
image, so there is nothing to persist and nothing to warm up on first boot.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `PADDLEOCR_PASSWORD` | generated, 24 chars | The credential for the API. Read it from the service variables after deploying. |
| `PADDLEOCR_USERNAME` | `admin` | Username for the same. |
| `PADDLEOCR_PIPELINE` | `OCR` | PaddleX pipeline to serve. Others need their models downloaded at runtime. |
| `PADDLEOCR_MAX_BODY` | `32MB` | Request body cap. Raise it for large scans or long PDFs. |
| `PADDLEOCR_TIMEOUT` | `300s` | Proxy read timeout. CPU inference is not fast; do not set this low. |
| `PORT` | `8080` | The port Railway's healthcheck probes and the domain targets. Leave it alone. |

The deploy form asks for nothing you have to invent.

## Using it

The OCR pipeline serves `POST /ocr`. The body takes either a URL the server can reach or the
Base64-encoded bytes of an image or PDF:

```bash
curl -u "admin:$PADDLEOCR_PASSWORD" \
  -X POST "https://your-app.up.railway.app/ocr" \
  -H 'Content-Type: application/json' \
  -d '{"file": "https://example.com/scan.png", "fileType": 1}'
```

`fileType` is `0` for PDF and `1` for image; omit it and the type is inferred from the URL. PDFs and
multi-page TIFFs are processed to a default limit of 10 pages. Results come back as JSON with the
recognised text, per-line boxes and confidence scores, plus base64 visualisations.

## Security

PaddleX serving ships **no authentication of any kind**, and an open OCR endpoint is free compute for
anyone who finds the URL. So Caddy holds a generated credential and is the only public listener,
while the inference server is pinned to `127.0.0.1` — PaddleX defaults to `--host 0.0.0.0` and this
template deliberately overrides that, so the unauthenticated API has no public interface at all.

The container refuses to start without a password of at least 12 characters. The credential is
hashed with bcrypt through stdin rather than a command-line flag, so it never appears in the
container's argv.

## Performance and cold start

The default `OCR` pipeline resolves to five models — **PP-OCRv6 medium** detection and recognition,
document and textline orientation, and UVDoc unwarping — totalling 177 MB. All five are baked into
the image, so no deployment ever downloads them.

Cold start has a second half that is easy to miss. Downloading the weights is one cost; the **first
inference** then loads them into memory and initialises Paddle's executor, which measured **98
seconds against roughly 4 for every request afterwards**. So the entrypoint runs one throwaway
inference on a bundled image before the proxy opens, and the healthcheck only passes once the model
is genuinely warm. The first real request then costs about the same as the second.

For scale, upstream publishes its own CPU benchmarks — for PP-OCRv5, so treat them as indicative
rather than exact for the v6 defaults here:

| Configuration | Avg. time per image | Peak RAM |
|---|---|---|
| PP-OCRv5 mobile | 1.75 s | 2.2 GB |
| PP-OCRv5 server | 4.34 s | 4.0 GB |

Read those with the caveat that the runs show 966–1007% CPU utilisation — roughly ten cores. On a
smaller Railway instance expect proportionally longer per request. There is no GPU path here;
PaddleX selects CPU when no device is present.

## Why it is shaped this way

- **Inference on loopback, proxy in front.** The risky setting is never set: `--host 127.0.0.1`
  means no misconfiguration can publish the unauthenticated API.
- **`/healthz` is answered by Caddy.** Railway's healthcheck carries no credentials and every
  PaddleX route is an inference endpoint, so pointing the check at one would open a hole. Inference
  liveness is covered by the entrypoint instead, which takes the container down if it exits.
- **The proxy starts only after inference answers**, so a healthy check never fronts a server that
  would still fail.
- **Models are baked into the image** at `PADDLE_PDX_CACHE_HOME=/opt/paddlex`. The service is
  stateless, so this buys a fast first request and a reproducible deployment instead of a volume.
- **SIGTERM is forwarded to both processes**, so a redeploy is a clean stop rather than a SIGKILL.
- **`restartPolicyType: ALWAYS`**, with the entrypoint exiting if either process dies.

## Reproducible builds

PaddleOCR publishes no image for this path — `deploy/docker/` holds only the legacy 2.x hubserving,
and `deploy/paddleocr_vl_docker/` is the GPU/vLLM vision-language pipeline. So this image is built
from PyPI, and every resolved package is hash-pinned in `requirements.lock` and installed with
`pip --require-hashes`, which refuses anything that does not match.

To update, bump the versions in `requirements.in` and regenerate the lock **on the deploy
architecture**:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w python:3.12-slim \
  sh -c 'pip install -q uv==0.9.5 && uv pip compile requirements.in -o requirements.lock --generate-hashes --python-version 3.12'
```

## Licences

PaddleOCR is [Apache-2.0](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE). Caddy is
Apache-2.0. The glue in this repository is MIT.

> Card icon: `icon.png` is upstream's `docs/version3.x/logo.jpg` padded to a 512x512 square, re-hosted here so the marketplace URL stays stable.
