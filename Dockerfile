# PaddleOCR on Railway — an OCR HTTP API behind an authenticating proxy.
#
# PaddleOCR publishes no image for this deployment path (deploy/docker holds
# only the legacy 2.x hubserving, and paddleocr_vl_docker is the GPU/vLLM
# vision-language pipeline), so the image is built here and requirements.lock
# pins every resolved package with hashes.
ARG CADDY_VERSION=2.11.4
ARG PYTHON_VERSION=3.12-slim

FROM caddy:${CADDY_VERSION} AS caddy-src

FROM python:${PYTHON_VERSION}

# libgomp1 for PaddlePaddle's OpenMP runtime; libgl1 and libglib2.0-0 because
# PaddleX's serving extra pins opencv-contrib-python, the non-headless build.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 \
        libgl1 \
        libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

# PaddleX serving has no authentication of any kind, so Caddy supplies it and
# is the only public listener. Caddy is a static Go binary, so it is copied in
# rather than installed.
COPY --from=caddy-src /usr/bin/caddy /usr/local/bin/caddy

COPY requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir --require-hashes -r /tmp/requirements.lock \
 && rm -f /tmp/requirements.lock

# Model weights live in the image rather than on a volume: this service is
# stateless, so baking them keeps the first request fast and the deployment
# reproducible. PaddleX reads this variable in paddlex/utils/cache.py.
ENV PADDLE_PDX_CACHE_HOME=/opt/paddlex \
    PADDLEOCR_PIPELINE=OCR \
    PADDLEOCR_INTERNAL_PORT=8081 \
    PORT=8080

# Disable oneDNN.
#
# PaddleX enables it by default, and on real x86 hardware PaddlePaddle 3.3.1
# then fails every OCR request inside its new PIR executor:
#
#   NotImplementedError: (Unimplemented) ConvertPirAttribute2RuntimeAttribute
#   not support [pir::ArrayAttribute<pir::DoubleAttribute>]
#   (at .../new_executor/instruction/onednn/onednn_instruction.cc:116)
#
# This never reproduces in a local `--platform linux/amd64` rehearsal on Apple
# Silicon, because the emulated CPU does not take the oneDNN path at all — the
# bug only appears once the service runs on genuine hardware.
ENV PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=False

# Bake the pipeline's weights into the image.
#
# PaddleX builds the pipeline when the SERVER STARTS, not lazily on the first
# request — measured: a cold container downloads 177 MB across five models
# (PP-OCRv6 medium detection and recognition, document and textline
# orientation, UVDoc unwarping) before Uvicorn answers at all. Doing it here
# instead turns every boot into a fast, offline, reproducible one, and is the
# reason this template needs no volume.
RUN python -c "from paddlex import create_pipeline; create_pipeline(pipeline='${PADDLEOCR_PIPELINE}')" \
 && du -sh "${PADDLE_PDX_CACHE_HOME}"

# A tiny image the entrypoint runs one inference on before opening the proxy.
# Downloading the weights is only half the cold start: the FIRST inference also
# loads them into memory and initialises Paddle's executor, measured at 98s
# versus ~4s for every request after it. Warming up before the healthcheck can
# pass moves that cost off the first real request.
RUN python -c "\
from PIL import Image, ImageDraw; \
img = Image.new('RGB', (320, 80), 'white'); \
ImageDraw.Draw(img).text((20, 30), 'warmup 123', fill='black'); \
img.save('/opt/warmup.png')"

COPY Caddyfile /etc/caddy/Caddyfile
COPY warmup.py /usr/local/bin/warmup.py
COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint
ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]
