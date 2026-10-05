#==========================================================================#
# DeepRank-Ab image for RunPod Serverless (default Dockerfile path for
# RunPod's GitHub build integration). For the plain CLI images see
# Dockerfile.cpu / Dockerfile.gpu.
#
# Kept small so RunPod's builder doesn't time out:
#  - plain ubuntu base: the PyPI torch wheel already bundles CUDA/cuDNN, and
#    the NVIDIA driver is injected by the container runtime
#  - no uv cache in the layers
#  - ESM-2 weights (~2.5GB) are downloaded on first use, to the network
#    volume when one is attached (see serverless/handler.py)
#
# Build:  docker build -t deeprank-ab-serverless .
# Local test:
#   docker run --rm --gpus all deeprank-ab-serverless \
#     /opt/handler-venv/bin/python -u /app/serverless/handler.py \
#     --test_input "$(cat serverless/test_input.json)"
#==========================================================================#
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    UV_NO_CACHE=1

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

RUN uv venv --python 3.10 && uv pip install .

# The handler gets its own venv: runpod needs requests>=2.31, which conflicts
# with deeprank-ab's requests==2.29.0 pin. It only shells out to the CLI.
RUN uv venv --python 3.10 /opt/handler-venv && \
  uv pip install --python /opt/handler-venv/bin/python -r serverless/requirements.txt

CMD ["/opt/handler-venv/bin/python", "-u", "/app/serverless/handler.py"]
