# Deploy and Host PaddleOCR on Railway

[PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) turns images and PDFs into structured text in
more than 100 languages. This template runs it as an HTTP API on Railway, behind a password generated
for your deployment, with no GPU and no volume.

## About Hosting PaddleOCR

The deployed service is PaddleOCR's own OCR pipeline served over HTTP. You POST an image or PDF — as
a URL the server can fetch or as base64 — and get back the recognised text with per-line boxes and
confidence scores. It is a plain request-and-response API, so there is no database, no queue and no
state to keep.

Two things about starting up are worth knowing, because this template deals with both. The pipeline's
five models are downloaded when the *server* starts rather than on first use, so they are baked into
the image and no deployment ever waits for a download. And the first inference after that loads those
weights into memory, which costs far more than every later request, so the container runs one
throwaway inference before it reports itself healthy. The result is that the first request a real
client makes is as fast as the second.

The other thing this template supplies is authentication. PaddleX's serving layer has none at all,
and an OCR endpoint left open on a public domain is free compute for whoever finds it, so a password
is generated for your deployment and the inference server is kept on loopback where nothing but the
proxy can reach it.

## Why Deploy PaddleOCR on Railway?

- **No GPU needed.** The pipeline runs on CPU, so it costs what an ordinary service costs.
- **No volume, no database.** The service is stateless and the models ship inside the image.
- **Fast from the first request.** Weights are baked in and the model is warmed before the
  healthcheck passes.
- **Private by default.** Your documents go to your own instance, not a third-party OCR API.
- **One service.** Nothing to assemble.

## Common Use Cases

- Turning scanned invoices, receipts and forms into text for an LLM pipeline.
- Extracting text from PDFs at an HTTP endpoint your other services can call.
- Adding OCR to an agent or workflow tool that can call a REST API.
- Batch-processing a document backlog without renting a GPU.

## Dependencies for PaddleOCR Hosting

- None. No database, no external services, no API keys.

### Deployment Dependencies

- Upstream project: [PaddlePaddle/PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) (Apache-2.0),
  packages `paddleocr` 3.7.0 and `paddlex[ocr,serving]` 3.7.2 on `paddlepaddle` 3.3.1.
- Upstream documentation: [PaddleOCR serving guide](https://paddlepaddle.github.io/PaddleOCR/latest/en/version3.x/inference_deployment/serving/serving.html).
- Template source: [RockinPaul/paddleocr_railway_template](https://github.com/RockinPaul/paddleocr_railway_template) (MIT).

### Implementation Details

**After deploying:** copy `PADDLEOCR_PASSWORD` from the service's Variables tab and call the API as
`admin` with that password. The OCR pipeline serves `POST /ocr`:

```
curl -u "admin:$PADDLEOCR_PASSWORD" -X POST "https://your-app.up.railway.app/ocr" \
  -H 'Content-Type: application/json' \
  -d '{"file": "https://example.com/scan.png", "fileType": 1}'
```

`fileType` is `0` for PDF and `1` for image, and may be omitted when the type is clear from the URL.
PDFs and multi-page TIFFs process the first 10 pages by default.

**Why there is a proxy.** PaddleX serving ships no authentication of any kind. Rather than leave an
inference endpoint open, this template puts Caddy in front with a generated credential and pins the
inference server to `127.0.0.1`, overriding PaddleX's `0.0.0.0` default — so there is no
configuration mistake that can expose the unauthenticated API. The container refuses to start without
a password, and the password is hashed through stdin so it never appears in the container's argv.

**Cold start, measured rather than assumed.** A cold container downloads 177 MB across five models
before serving anything, so the build bakes them in. The first inference then costs far more than
later ones, so the entrypoint warms the model before the healthcheck can pass. Both numbers were
measured during the build, and both costs are paid before your first request rather than during it.

**Performance.** This is CPU inference. Upstream's own published CPU benchmarks for PP-OCRv5 are
1.75 s per image at roughly ten cores; the defaults here are the newer PP-OCRv6 medium models. Size
the service for the throughput you need and expect longer per request on a small instance.

**Notes.** `PADDLEOCR_MAX_BODY` (default 32MB) caps request size — raise it for large scans.
`PADDLEOCR_TIMEOUT` (default 300s) is the proxy read timeout; do not set it low, because inference is
not instant. The healthcheck is `/healthz`, answered by the proxy itself so it needs no credentials
and exposes no inference route.

## Licences

PaddleOCR is Apache-2.0. Caddy is Apache-2.0. The template's glue is MIT.
