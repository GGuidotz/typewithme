#!/bin/zsh
# Scarica gli header C di llama.cpp della build scritta in packaging/llama.cpp-version in Vendor/llama/include:
# il motore dentro l'app (LlamaRuntime.swift) si compila contro questi e si collega alle librerie della stessa build.
set -euo pipefail
cd "${0:A:h}/.."
TAG=$(tr -d '[:space:]' < packaging/llama.cpp-version)
[ "$TAG" = latest ] && { echo "Scrivi una build precisa (bNNNN) in packaging/llama.cpp-version." >&2; exit 1; }
mkdir -p Vendor/llama/include
BASE="https://raw.githubusercontent.com/ggml-org/llama.cpp/$TAG"
for f in include/llama.h ggml/include/ggml.h ggml/include/ggml-cpu.h ggml/include/ggml-backend.h \
         ggml/include/ggml-alloc.h ggml/include/ggml-opt.h ggml/include/gguf.h; do
  curl -fsSL -o "Vendor/llama/include/${f:t}" "$BASE/$f"
done
echo "$TAG" > Vendor/llama/TAG
echo "Header di llama.cpp $TAG in Vendor/llama/include."
