# Technical Hardware Profile & Measured Benchmarks (Sanitized)

**System Architecture:** AMD64 / x86_64  
**Hardware Tier:** High-Performance Mobile Workstation  
**Benchmarking Status:** Verified via Direct Native API Measurement (October 2026)

---

## 1. Verified Hardware Baseline

| Hardware Component | Technical Specification | RAG System Role & Evaluation |
| :--- | :--- | :--- |
| **Processor (CPU)** | AMD Ryzen 9 5900HS (8 Physical Cores, 16 Threads, Boost up to 4.6 GHz) | High parallel computing capacity; optimal for text preprocessing and fallback CPU inference |
| **System Memory (RAM)** | 40 GB DDR4 (~25 GB available at runtime) | Generous memory headroom; comfortably accommodates Dify's multi-container stack (~4–5 GB) |
| **Graphics Processor (GPU)** | NVIDIA GeForce RTX 3060 Laptop GPU (6144 MiB GDDR6 VRAM) | Dedicated tensor acceleration for LLM text generation and vector embedding generation |
| **Graphics Driver & Compute** | NVIDIA Driver 621.01 / CUDA UMD 13.5 (CUDA 12.x / 13.x native support) | Full hardware offload support via cuBLAS and llamacpp CUDA runners |
| **Primary Storage (SSD)** | Fast NVMe Solid State Drive (>140 GB available) | Low-latency storage for Docker volumes, vector indexes, and model weights |

---

## 2. Measured LLM Inference Benchmarks (`qwen3.5:4b`)

Direct measurements were captured on the target workstation running native Ollama with CUDA acceleration under a standard 4096-token context window (`num_ctx: 4096`):

```
================================================================================
Benchmark Parameter               Measured Metric
================================================================================
Model Tag                         qwen3.5:4b (GGUF Q4_K_M, 3.1 GB memory image)
Context Length                    4096 tokens (num_ctx: 4096)
Hardware Accelerator              100% GPU Offload (CUDA llamacpp runner)
Model Load Duration               7.28 seconds
Total Tokens Generated            1969 tokens
Generation Duration               33.27 seconds
Measured Generation Speed         59.18 tokens/second
Baseline System VRAM              545 MiB
Active VRAM Consumption           4345 MiB (70.7% of total 6144 MiB)
Available VRAM Headroom           1650 MiB
GPU Operating Temperature         54°C (under peak generation load)
================================================================================
```

---

## 3. Embedding Model Sizing & Concurrency Strategy

With 1650 MiB of VRAM headroom remaining after loading `qwen3.5:4b` at a 4096-token context:

1. **`bge-m3` (BAAI) — Preferred High-Accuracy Option:**
   - Memory Footprint: ~1200 MiB VRAM.
   - Concurrency Analysis: Concurrent residency (`qwen3.5:4b` + `bge-m3`) consumes ~5545 MiB of 6144 MiB. This fits inside VRAM but leaves <600 MiB margin.
   - Sizing Rule: Context window must not exceed 4096 tokens to avoid KV-cache expansion forcing layer offloading to system RAM.
2. **`qwen3-embedding:0.6b` — Lean Low-Footprint Option:**
   - Memory Footprint: ~650 MiB VRAM.
   - Concurrency Analysis: Concurrent residency consumes ~4995 MiB, leaving an ample ~1150 MiB margin for OS display buffers and extended context.
3. **Sequential Model Loading (Fallback Policy):**
   - If memory contention occurs during large batch indexing, Ollama's `OLLAMA_MAX_LOADED_MODELS=1` parameter unloads the embedding model before activating the chat LLM, guaranteeing zero VRAM thrashing.
