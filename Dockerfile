#==========================================================================#
# DeepRank-Ab image for RunPod Serverless (default Dockerfile path for
# RunPod's GitHub build integration). For the plain CLI images see
# Dockerfile.cpu / Dockerfile.gpu.
#
# Build:  docker build -t deeprank-ab-serverless .
# Local test:
#   docker run --rm --gpus all deeprank-ab-serverless \
#     /app/.venv/bin/python -u /app/serverless/handler.py \
#     --test_input "$(cat serverless/test_input.json)"
#==========================================================================#
ARG CUDA=12.8.0
FROM nvidia/cuda:${CUDA}-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && \
  apt-get install -y --no-install-recommends build-essential ca-certificates && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
ENV MPLCONFIGDIR=/tmp/matplotlib
ENV WEIGHT_PATH=/cache/esm2_t33_650M_UR50D.pt
ENV REG_WEIGHT_PATH=/cache/esm2_t33_650M_UR50D-contact-regression.pt
RUN mkdir -p /cache

WORKDIR /app
COPY . .
RUN chmod +x src/tools/ANARCI/hmmscan src/tools/voronota/voronota

RUN uv venv --python 3.10 && \
  uv pip install . -r serverless/requirements.txt

# Bake the ~2.5GB ESM-2 weights into the image so workers don't download
# them on every cold start (checksums are verified by fetch_weights)
RUN /app/.venv/bin/python -c "from scripts.inference import fetch_weights; fetch_weights()"

CMD ["/app/.venv/bin/python", "-u", "/app/serverless/handler.py"]
