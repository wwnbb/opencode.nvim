---
source: https://models.dev/models?q=opencode-go
title: OpenCode Go — Available Models
fetched: 2026-06-03
---

# OpenCode Go — Available Models

Source: [models.dev](https://models.dev/models?q=opencode-go) | Provider page: [opencode.ai/docs/zen](https://opencode.ai/docs/zen)

---

## Provider: OpenCode Go (`opencode-go`)

| Field | Value |
|-------|-------|
| **Provider ID** | `opencode-go` |
| **Name** | OpenCode Go |
| **API Base** | `https://opencode.ai/zen/go/v1` |
| **SDK** | `@ai-sdk/openai-compatible` |
| **Env Variable** | `OPENCODE_API_KEY` |
| **Documentation** | https://opencode.ai/docs/zen |

### Models

| Model ID | Name | Family | Reasoning | Tool Call | Input Cost | Output Cost | Cache Read Cost | Context | Output Limit | Modalities | Open Weights |
|----------|------|--------|-----------|-----------|------------|-------------|-----------------|---------|--------------|------------|--------------|
| `deepseek-v4-flash` | DeepSeek V4 Flash | deepseek-flash | ✅ | ✅ | $0.14 / 1M tok | $0.28 / 1M tok | $0.0028 / 1M tok | 1,000,000 | 384,000 | text → text | ✅ |
| `deepseek-v4-pro` | DeepSeek V4 Pro | deepseek-thinking | ✅ | ✅ | $1.74 / 1M tok | $3.48 / 1M tok | $0.0145 / 1M tok | 1,000,000 | 384,000 | text → text | ✅ |
| `minimax-m3` | MiniMax M3 | minimax-m3 | ✅ | ✅ | $0.60 / 1M tok | $2.40 / 1M tok | $0.12 / 1M tok | 512,000 | 131,072 | text, image, video → text | ✅ |
| `minimax-m2.7` | MiniMax M2.7 | minimax-m2.7 | ✅ | ✅ | $0.30 / 1M tok | $1.20 / 1M tok | $0.06 / 1M tok | 204,800 | 131,072 | text → text | ✅ |
| `minimax-m2.5` | MiniMax M2.5 | minimax-m2.5 | ✅ | ✅ | $0.30 / 1M tok | $1.20 / 1M tok | $0.03 / 1M tok | 204,800 | 65,536 | text → text | ✅ |
| `qwen3.7-plus` | Qwen3.7 Plus | qwen3.7-plus | ✅ | ✅ | $0.40 / 1M tok | $1.60 / 1M tok | $0.04 / 1M tok | 262,144 | 65,536 | text, image, video → text | ❌ |
| `qwen3.7-max` | Qwen3.7 Max | qwen3.7-max | ✅ | ✅ | $2.50 / 1M tok | $7.50 / 1M tok | $0.50 / 1M tok | 1,000,000 | 65,536 | text → text | ❌ |
| `qwen3.6-plus` | Qwen3.6 Plus | qwen3.6 | ✅ | ✅ | $0.50 / 1M tok | $3.00 / 1M tok | $0.05 / 1M tok | 262,144 | 65,536 | text, image, video → text | ❌ |
| `kimi-k2.6` | Kimi K2.6 | kimi-k2.6 | ✅ | ✅ | $0.95 / 1M tok | $4.00 / 1M tok | $0.16 / 1M tok | 262,144 | 65,536 | text, image, video → text | ✅ |
| `kimi-k2.5` | Kimi K2.5 | kimi-k2.5 | ✅ | ✅ | $0.60 / 1M tok | $3.00 / 1M tok | $0.10 / 1M tok | 262,144 | 65,536 | text, image, video → text | ✅ |
| `glm-5.1` | GLM-5.1 | glm | ✅ | ✅ | $1.40 / 1M tok | $4.40 / 1M tok | $0.26 / 1M tok | 202,752 | 32,768 | text → text | ✅ |
| `glm-5` | GLM-5 | glm | ✅ | ✅ | $1.00 / 1M tok | $3.20 / 1M tok | $0.20 / 1M tok | 202,752 | 32,768 | text → text | ✅ |
| `mimo-v2.5` | MiMo V2.5 | mimo-v2.5 | ✅ | ✅ | $0.14 / 1M tok | $0.28 / 1M tok | $0.0028 / 1M tok | 1,000,000 | 128,000 | text, image, audio, video → text | ✅ |
| `mimo-v2.5-pro` | MiMo V2.5 Pro | mimo-v2.5-pro | ✅ | ✅ | $1.74 / 1M tok | $3.48 / 1M tok | $0.0145 / 1M tok | 1,048,576 | 128,000 | text → text | ✅ |

**Deprecated models:** `qwen3.5-plus`, `mimo-v2-omni`, `mimo-v2-pro`

### Model Details

#### DeepSeek V4 Flash
- **Model ID:** `deepseek-v4-flash`
- **Family:** deepseek-flash
- **Knowledge cutoff:** 2025-05
- **Release date:** 2026-04-24
- **Capabilities:** reasoning, tool calls, structured output, temperature control
- **Interleaved reasoning:** `reasoning_content` field
- **Context window:** 1,000,000 tokens
- **Max output:** 384,000 tokens
- **Pricing:**
  - Input: $0.14/1M tokens
  - Output: $0.28/1M tokens
  - Cache read: $0.0028/1M tokens

#### DeepSeek V4 Pro
- **Model ID:** `deepseek-v4-pro`
- **Family:** deepseek-thinking
- **Knowledge cutoff:** 2025-05
- **Release date:** 2026-04-24
- **Capabilities:** reasoning, tool calls, structured output, temperature control
- **Interleaved reasoning:** `reasoning_content` field
- **Context window:** 1,000,000 tokens
- **Max output:** 384,000 tokens
- **Pricing:**
  - Input: $1.74/1M tokens
  - Output: $3.48/1M tokens
  - Cache read: $0.0145/1M tokens

#### MiniMax M3
- **Model ID:** `minimax-m3`
- **Family:** minimax-m3
- **Knowledge cutoff:** 2025-01
- **Release date:** 2026-05-31
- **Capabilities:** reasoning, tool calls, temperature control
- **Context window:** 512,000 tokens
- **Max output:** 131,072 tokens
- **Modalities:** text, image, video → text
- **Pricing:**
  - Input: $0.60/1M tokens
  - Output: $2.40/1M tokens
  - Cache read: $0.12/1M tokens

#### Qwen3.7 Plus
- **Model ID:** `qwen3.7-plus`
- **Family:** qwen3.7-plus
- **Release date:** 2026-06-02
- **Capabilities:** reasoning, tool calls, temperature control, attachment support
- **Context window:** 262,144 tokens
- **Max output:** 65,536 tokens
- **Modalities:** text, image, video → text
- **Pricing:**
  - Input: $0.40/1M tokens
  - Output: $1.60/1M tokens
  - Cache read: $0.04/1M tokens
  - Cache write: $0.50/1M tokens

#### Qwen3.7 Max
- **Model ID:** `qwen3.7-max`
- **Family:** qwen3.7-max
- **Release date:** 2026-05-21
- **Capabilities:** reasoning, tool calls, temperature control
- **Context window:** 1,000,000 tokens
- **Max output:** 65,536 tokens
- **Pricing:**
  - Input: $2.50/1M tokens
  - Output: $7.50/1M tokens
  - Cache read: $0.50/1M tokens
  - Cache write: $3.125/1M tokens

#### Qwen3.6 Plus
- **Model ID:** `qwen3.6-plus`
- **Family:** qwen3.6
- **Knowledge cutoff:** 2025-04
- **Release date:** 2026-04-02
- **Capabilities:** reasoning, tool calls, temperature control, attachment support
- **Context window:** 262,144 tokens
- **Max output:** 65,536 tokens
- **Modalities:** text, image, video → text
- **Pricing:**
  - Input: $0.50/1M tokens
  - Output: $3.00/1M tokens
  - Cache read: $0.05/1M tokens
  - Cache write: $0.625/1M tokens

#### Kimi K2.6
- **Model ID:** `kimi-k2.6`
- **Family:** kimi-k2.6
- **Knowledge cutoff:** 2024-10
- **Release date:** 2026-04-21
- **Capabilities:** reasoning, tool calls, temperature control, attachment support
- **Context window:** 262,144 tokens
- **Max output:** 65,536 tokens
- **Modalities:** text, image, video → text
- **Pricing:**
  - Input: $0.95/1M tokens
  - Output: $4.00/1M tokens
  - Cache read: $0.16/1M tokens

#### GLM-5.1
- **Model ID:** `glm-5.1`
- **Family:** glm
- **Knowledge cutoff:** 2025-04
- **Release date:** 2026-04-07
- **Capabilities:** reasoning, tool calls, temperature control
- **Context window:** 202,752 tokens
- **Max output:** 32,768 tokens
- **Pricing:**
  - Input: $1.40/1M tokens
  - Output: $4.40/1M tokens
  - Cache read: $0.26/1M tokens

#### MiMo V2.5
- **Model ID:** `mimo-v2.5`
- **Family:** mimo-v2.5
- **Knowledge cutoff:** 2024-12
- **Release date:** 2026-04-22
- **Capabilities:** reasoning, tool calls, temperature control, attachment support
- **Context window:** 1,000,000 tokens
- **Max output:** 128,000 tokens
- **Modalities:** text, image, audio, video → text
- **Pricing:**
  - Input: $0.14/1M tokens
  - Output: $0.28/1M tokens
  - Cache read: $0.0028/1M tokens

#### MiMo V2.5 Pro
- **Model ID:** `mimo-v2.5-pro`
- **Family:** mimo-v2.5-pro
- **Knowledge cutoff:** 2024-12
- **Release date:** 2026-04-22
- **Capabilities:** reasoning, tool calls, temperature control, attachment support
- **Context window:** 1,048,576 tokens
- **Max output:** 128,000 tokens
- **Pricing:**
  - Input: $1.74/1M tokens
  - Output: $3.48/1M tokens
  - Cache read: $0.0145/1M tokens

---

## Provider: OpenCode (`opencode`)

A related provider in the same ecosystem.

| Field | Value |
|-------|-------|
| **Provider ID** | `opencode` |
| **Name** | OpenCode |
| **API Base** | (OpenCode server) |

### Models

| Model ID | Name | Family | Reasoning | Tool Call | Cost | Context | Output Limit |
|----------|------|--------|-----------|-----------|------|---------|--------------|
| `deepseek-v4-flash-free` | DeepSeek V4 Flash Free | deepseek-flash-free | ✅ | ✅ | Free | 200,000 | 128,000 |
| `deepseek-v4-flash` | DeepSeek V4 Flash | deepseek-flash | ✅ | ✅ | $0.14/$0.28 | 1,000,000 | 384,000 |

---

## Notes

- All prices are in USD per 1 million tokens.
- "Structured Output" support is indicated in the DeepSeek V4 Flash and DeepSeek V4 Pro models.
- "Interleaved reasoning" models support thinking/reasoning content delivered via the `reasoning_content` field during streaming.
- Models with `open_weights: true` have publicly available model weights.
- Attachment support enables vision (image/video/audio/pdf) inputs depending on model modalities.
