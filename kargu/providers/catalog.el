;;; kargu/providers/catalog.el --- Pre-compiled catalog of LLM providers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Complete pre-compiled catalog of 160+ LLM providers.
;; Auto-registers all built-in providers into `kargu-providers--table' at load time.

;;; Code:

(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/providers/registry)

(defconst kargu-providers-builtin-catalog
  '(
    (:id "302ai"
     :name "302.AI"
     :api "https://api.302.ai/v1"
     :env ("302AI_API_KEY")
     :models ("gpt-5.4-mini-2026-03-17" "chatgpt-4o-latest" "gpt-5.4-nano-2026-03-17" "kimi-k2-0905-preview" "grok-4.20-beta-0309-non-reasoning" "gemini-2.5-flash-nothink" "qwen-plus" "glm-4.7" "qwen3-235b-a22b-instruct-2507" "glm-4.5v" "claude-opus-4-5" "gemini-2.5-pro" "gpt-5" "claude-haiku-4-5-20251001" "kimi-k2-thinking-turbo")
     :npm "@ai-sdk/openai-compatible")
    (:id "abacus"
     :name "Abacus"
     :api "https://routellm.abacus.ai/v1"
     :env ("ABACUS_API_KEY")
     :models ("o3" "gemini-3.1-flash-lite" "route-llm" "grok-code-fast-1" "gpt-5.3-codex-xhigh" "llama-3.3-70b-versatile" "gemini-2.5-pro" "gpt-5" "claude-haiku-4-5-20251001" "grok-4.3" "gemini-2.5-flash" "gpt-4o" "o4-mini" "qwen3-max" "gemini-3.5-flash")
     :npm "@ai-sdk/openai-compatible")
    (:id "abliteration-ai"
     :name "abliteration.ai"
     :api "https://api.abliteration.ai/v1"
     :env ("ABLIT_KEY")
     :models ("abliterated-model")
     :npm "@ai-sdk/openai-compatible")
    (:id "aihubmix"
     :name "AIHubMix"
     :api "https://aihubmix.com/v1"
     :env ("AIHUBMIX_API_KEY")
     :models ("coding-minimax-m2.7" "alicloud-glm-5.1" "claude-sonnet-4-6-think" "gemini-3.1-flash-lite" "alicloud-deepseek-v4-flash" "xiaomi-mimo-v2.5-pro" "doubao-seed-2-0-code-preview" "coding-xiaomi-mimo-v2.5-pro" "doubao-seed-2-0-pro" "deep-deepseek-v4-flash" "qwen3.7-plus" "gemini-2.5-pro" "grok-4.3" "qwen3.7-max" "gemini-2.5-flash")
     :npm "@aihubmix/ai-sdk-provider")
    (:id "alibaba"
     :name "Alibaba"
     :api "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
     :env ("DASHSCOPE_API_KEY")
     :models ("qwen3-omni-flash" "qwen3-coder-plus" "qwen-plus" "qwen3-coder-30b-a3b-instruct" "qwen3-omni-flash-realtime" "qwen3-32b" "qwen-omni-turbo-realtime" "qwen-plus-character-ja" "qwen3-next-80b-a3b-instruct" "qwen3.7-plus" "qwen3.6-35b-a3b" "qwen3.7-max" "qwen3-max" "qwen2-5-omni-7b" "qwen3-8b")
     :npm "@ai-sdk/openai-compatible")
    (:id "alibaba-cn"
     :name "Alibaba (China)"
     :api "https://dashscope.aliyuncs.com/compatible-mode/v1"
     :env ("DASHSCOPE_API_KEY")
     :models ("qwen2-5-math-72b-instruct" "deepseek-r1-0528" "qwen3-omni-flash" "deepseek-v4-flash" "qwen-plus" "qwen3-coder-30b-a3b-instruct" "qwen2-5-coder-7b-instruct" "deepseek-v3" "qwen3-omni-flash-realtime" "deepseek-r1-distill-llama-70b" "qwen3-32b" "qwen-omni-turbo-realtime" "qwen2-5-math-7b-instruct" "qwen3-next-80b-a3b-instruct" "qwen3.7-plus")
     :npm "@ai-sdk/openai-compatible")
    (:id "alibaba-coding-plan"
     :name "Alibaba Coding Plan"
     :api "https://coding-intl.dashscope.aliyuncs.com/v1"
     :env ("ALIBABA_CODING_PLAN_API_KEY")
     :models ("qwen3-coder-plus" "glm-4.7" "qwen3.7-plus" "qwen3.7-max" "qwen3.6-flash" "qwen3-max-2026-01-23" "qwen3.5-plus" "kimi-k2.5" "MiniMax-M2.5" "qwen3-coder-next" "glm-5" "qwen3.6-plus")
     :npm "@ai-sdk/openai-compatible")
    (:id "alibaba-coding-plan-cn"
     :name "Alibaba Coding Plan (China)"
     :api "https://coding.dashscope.aliyuncs.com/v1"
     :env ("ALIBABA_CODING_PLAN_API_KEY")
     :models ("qwen3-coder-plus" "glm-4.7" "qwen3.7-plus" "qwen3.7-max" "qwen3.6-flash" "qwen3-max-2026-01-23" "qwen3.5-plus" "kimi-k2.5" "MiniMax-M2.5" "qwen3-coder-next" "glm-5" "qwen3.6-plus")
     :npm "@ai-sdk/openai-compatible")
    (:id "alibaba-token-plan"
     :name "Alibaba Token Plan"
     :api "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
     :env ("ALIBABA_TOKEN_PLAN_API_KEY")
     :models ("deepseek-v4-flash" "qwen3.7-plus" "qwen3.7-max" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "wan2.7-image-pro" "glm-5.2" "qwen3.6-flash" "kimi-k2.5" "qwen-image-2.0" "MiniMax-M2.5" "kimi-k2.6" "qwen-image-2.0-pro" "wan2.7-image")
     :npm "@ai-sdk/openai-compatible")
    (:id "alibaba-token-plan-cn"
     :name "Alibaba Token Plan (China)"
     :api "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
     :env ("ALIBABA_TOKEN_PLAN_API_KEY")
     :models ("deepseek-v4-flash" "qwen3.7-plus" "qwen3.7-max" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "wan2.7-image-pro" "glm-5.2" "qwen3.6-flash" "kimi-k2.5" "qwen-image-2.0" "MiniMax-M2.5" "kimi-k2.6" "qwen-image-2.0-pro" "wan2.7-image")
     :npm "@ai-sdk/openai-compatible")
    (:id "amazon-bedrock"
     :name "Amazon Bedrock"
     :api "https://bedrock-runtime.us-east-1.amazonaws.com"
     :env ("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "AWS_BEARER_TOKEN_BEDROCK")
     :models ("global.anthropic.claude-haiku-4-5-20251001-v1:0" "global.anthropic.claude-sonnet-4-5-20250929-v1:0" "jp.anthropic.claude-haiku-4-5-20251001-v1:0" "us.meta.llama4-scout-17b-instruct-v1:0" "minimax.minimax-m2" "anthropic.claude-opus-4-7" "eu.anthropic.claude-sonnet-4-6" "mistral.voxtral-small-24b-2507" "mistral.ministral-3-3b-instruct" "openai.gpt-oss-20b" "anthropic.claude-opus-4-6-v1" "openai.gpt-oss-safeguard-20b" "anthropic.claude-opus-4-5-20251101-v1:0" "global.anthropic.claude-fable-5" "openai.gpt-oss-120b-1:0")
     :npm "@ai-sdk/amazon-bedrock")
    (:id "ambient"
     :name "Ambient"
     :api "https://api.ambient.xyz/v1"
     :env ("AMBIENT_API_KEY")
     :models ("moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2.6" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5.2-FP8")
     :npm "@ai-sdk/openai-compatible")
    (:id "anthropic"
     :name "Anthropic"
     :api "https://api.anthropic.com/v1"
     :env ("ANTHROPIC_API_KEY")
     :models ("claude-3-5-sonnet-latest" "claude-3-5-haiku-latest" "claude-3-opus-latest" "claude-opus-4-5" "claude-haiku-4-5-20251001" "claude-opus-4-1-20250805" "claude-sonnet-4-5" "claude-opus-4-7" "claude-sonnet-5" "claude-opus-4-5-20251101" "claude-opus-4-8" "claude-opus-4-1" "claude-fable-5" "claude-haiku-4-5" "claude-opus-4-6")
     :npm "@ai-sdk/anthropic")
    (:id "anyapi"
     :name "AnyAPI"
     :api "https://api.anyapi.ai/v1"
     :env ("ANYAPI_API_KEY")
     :models ("xai/grok-4.3" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-2.5-flash-lite" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "openai/o3" "openai/gpt-5" "openai/o4-mini" "openai/o3-mini" "openai/gpt-5.2" "openai/gpt-5.4" "openai/gpt-4.1" "openai/gpt-5-mini" "openai/gpt-4.1-mini")
     :npm "@ai-sdk/openai-compatible")
    (:id "atomic-chat"
     :name "Atomic Chat"
     :api "http://127.0.0.1:1337/v1"
     :env ("ATOMIC_CHAT_API_KEY")
     :models ("gemma-4-E4B-it-IQ4_XS" "Meta-Llama-3_1-8B-Instruct-GGUF" "Qwen3_5-9B-MLX-4bit" "gemma-4-E4B-it-MLX-4bit" "Qwen3_5-9B-Q4_K_M")
     :npm "@ai-sdk/openai-compatible")
    (:id "auriko"
     :name "Auriko"
     :api "https://api.auriko.ai/v1"
     :env ("AURIKO_API_KEY")
     :models ("deepseek-v4-flash" "gemini-2.5-pro" "grok-4.3" "gemini-2.5-flash" "glm-5.1" "deepseek-v4-pro" "claude-opus-4-7" "minimax-m2-7-highspeed" "minimax-m2-7" "qwen-3.6-plus" "kimi-k2.5" "kimi-k2.6" "gemini-3.1-pro-preview" "claude-opus-4-6" "claude-sonnet-4-6")
     :npm "@ai-sdk/openai-compatible")
    (:id "azure"
     :name "Azure"
     :api "https://${AZURE_RESOURCE_NAME}.openai.azure.com/openai/deployments"
     :env ("AZURE_RESOURCE_NAME" "AZURE_API_KEY")
     :models ("codex-mini" "phi-3.5-moe-instruct" "gpt-3.5-turbo-instruct" "deepseek-r1-0528" "deepseek-v4-flash" "gpt-5.2-chat" "o3" "deepseek-v3-0324" "phi-3-small-128k-instruct" "meta-llama-3-8b-instruct" "mistral-small-2503" "text-embedding-3-large" "o1-mini" "phi-3.5-mini-instruct" "mistral-nemo")
     :npm "@ai-sdk/azure")
    (:id "azure-cognitive-services"
     :name "Azure Cognitive Services"
     :api "https://${AZURE_COGNITIVE_SERVICES_RESOURCE_NAME}.cognitiveservices.azure.com"
     :env ("AZURE_COGNITIVE_SERVICES_RESOURCE_NAME" "AZURE_COGNITIVE_SERVICES_API_KEY")
     :models ("claude-opus-4-5" "claude-sonnet-4-5" "gpt-5.4-nano" "claude-opus-4-8" "claude-opus-4-1" "kimi-k2.5" "claude-haiku-4-5" "gpt-5.4" "gpt-5.4-mini" "kimi-k2.6" "claude-opus-4-6" "gpt-5.4-pro" "gpt-5.5" "gpt-5.1" "meta-llama-3-70b-instruct")
     :npm "@ai-sdk/azure")
    (:id "bailing"
     :name "Bailing"
     :api "https://api.tbox.cn/api/llm/v1/chat/completions"
     :env ("BAILING_API_TOKEN")
     :models ("Ring-1T" "Ling-1T")
     :npm "@ai-sdk/openai-compatible")
    (:id "baseten"
     :name "Baseten"
     :api "https://inference.baseten.co/v1"
     :env ("BASETEN_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "openai/gpt-oss-120b" "nvidia/Nemotron-120B-A12B" "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B" "zai-org/GLM-5" "zai-org/GLM-4.7" "zai-org/GLM-5.2" "zai-org/GLM-5.1" "deepseek-ai/DeepSeek-V3.1" "deepseek-ai/DeepSeek-V4-Pro" "MiniMaxAI/MiniMax-M2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "berget"
     :name "Berget.AI"
     :api "https://api.berget.ai/v1"
     :env ("BERGET_API_KEY")
     :models ("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2.6" "google/gemma-4-31B-it" "openai/gpt-oss-120b" "mistralai/Mistral-Medium-3.5-128B" "mistralai/Mistral-Small-3.2-24B-Instruct-2506" "zai-org/GLM-4.7" "zai-org/GLM-5.2")
     :npm "@ai-sdk/openai-compatible")
    (:id "cerebras"
     :name "Cerebras"
     :api "https://api.cerebras.ai/v1"
     :env ("CEREBRAS_API_KEY")
     :models ("llama3.1-70b" "llama3.1-8b" "gemma-4-31b" "gpt-oss-120b" "zai-glm-4.7")
     :npm "@ai-sdk/cerebras")
    (:id "chutes"
     :name "Chutes"
     :api "https://llm.chutes.ai/v1"
     :env ("CHUTES_API_KEY")
     :models ("moonshotai/Kimi-K2.6-TEE" "moonshotai/Kimi-K2.5-TEE" "google/gemma-4-31B-turbo-TEE" "Qwen/Qwen3-32B-TEE" "Qwen/Qwen3.6-27B-TEE" "Qwen/Qwen3-235B-A22B-Thinking-2507-TEE" "Qwen/Qwen3.5-397B-A17B-TEE" "unsloth/Mistral-Nemo-Instruct-2407-TEE" "zai-org/GLM-5-TEE" "zai-org/GLM-5.1-TEE" "zai-org/GLM-5.2-TEE" "deepseek-ai/DeepSeek-V3.2-TEE" "MiniMaxAI/MiniMax-M2.5-TEE")
     :npm "@ai-sdk/openai-compatible")
    (:id "clarifai"
     :name "Clarifai"
     :api "https://api.clarifai.com/v2/ext/openai/v1"
     :env ("CLARIFAI_PAT")
     :models ("moonshotai/chat-completion/models/Kimi-K2_6" "minimaxai/chat-completion/models/MiniMax-M2_5-high-throughput" "openai/chat-completion/models/gpt-oss-120b-high-throughput" "openai/chat-completion/models/gpt-oss-20b" "mistralai/completion/models/Ministral-3-14B-Reasoning-2512" "mistralai/completion/models/Ministral-3-3B-Reasoning-2512" "deepseek-ai/deepseek-ocr/models/DeepSeek-OCR" "qwen/qwenLM/models/Qwen3-30B-A3B-Thinking-2507" "qwen/qwenLM/models/Qwen3-30B-A3B-Instruct-2507" "qwen/qwenCoder/models/Qwen3-Coder-30B-A3B-Instruct" "arcee_ai/AFM/models/trinity-mini" "clarifai/main/models/mm-poly-8b")
     :npm "@ai-sdk/openai-compatible")
    (:id "claudinio"
     :name "Claudinio"
     :api "https://api.claudin.io/v1"
     :env ("CLAUDINIO_API_KEY")
     :models ("claudinio" "claudius")
     :npm "@ai-sdk/openai-compatible")
    (:id "cloudferro-sherlock"
     :name "CloudFerro Sherlock"
     :api "https://api-sherlock.cloudferro.com/openai/v1"
     :env ("CLOUDFERRO_SHERLOCK_API_KEY")
     :models ("meta-llama/Llama-3.3-70B-Instruct" "openai/gpt-oss-120b" "speakleash/Bielik-11B-v3.0-Instruct" "speakleash/Bielik-11B-v2.6-Instruct" "MiniMaxAI/MiniMax-M2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "cloudflare-ai-gateway"
     :name "Cloudflare AI Gateway"
     :api "https://gateway.ai.cloudflare.com/v1/${CLOUDFLARE_ACCOUNT_ID}/${CLOUDFLARE_GATEWAY_ID}"
     :env ("CLOUDFLARE_API_TOKEN" "CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_GATEWAY_ID")
     :models ("workers-ai/@cf/baai/bge-m3" "workers-ai/@cf/baai/bge-small-en-v1.5" "workers-ai/@cf/baai/bge-reranker-base" "workers-ai/@cf/baai/bge-base-en-v1.5" "workers-ai/@cf/baai/bge-large-en-v1.5" "workers-ai/@cf/ai4bharat/indictrans2-en-indic-1B" "workers-ai/@cf/ibm-granite/granite-4.0-h-micro" "workers-ai/@cf/huggingface/distilbert-sst-2-int8" "workers-ai/@cf/moonshotai/kimi-k2.5" "workers-ai/@cf/moonshotai/kimi-k2.6" "workers-ai/@cf/mistral/mistral-7b-instruct-v0.1" "workers-ai/@cf/google/gemma-3-12b-it" "workers-ai/@cf/myshell-ai/melotts" "workers-ai/@cf/openai/gpt-oss-120b" "workers-ai/@cf/openai/gpt-oss-20b")
     :npm "ai-gateway-provider")
    (:id "cloudflare-workers-ai"
     :name "Cloudflare Workers AI"
     :api "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1"
     :env ("CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_API_KEY")
     :models ("@cf/ibm-granite/granite-4.0-h-micro" "@cf/moonshotai/kimi-k2.7-code" "@cf/moonshotai/kimi-k2.6" "@cf/google/gemma-4-26b-a4b-it" "@cf/openai/gpt-oss-120b" "@cf/openai/gpt-oss-20b" "@cf/mistralai/mistral-small-3.1-24b-instruct" "@cf/nvidia/nemotron-3-120b-a12b" "@cf/zai-org/glm-5.2" "@cf/zai-org/glm-4.7-flash" "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b" "@cf/qwen/qwen3-30b-a3b-fp8" "@cf/qwen/qwen2.5-coder-32b-instruct" "@cf/qwen/qwq-32b" "@cf/meta/llama-3.2-1b-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "cohere"
     :name "Cohere"
     :api "https://api.cohere.com/v2"
     :env ("COHERE_API_KEY")
     :models ("command-r-plus" "command-r" "c4ai-aya-expanse-32b" "command-a-03-2025" "c4ai-aya-vision-32b" "command-r7b-arabic-02-2025" "c4ai-aya-vision-8b" "command-r-08-2024" "command-r7b-12-2024" "command-a-vision-07-2025" "command-a-plus-05-2026" "command-a-translate-08-2025" "command-r-plus-08-2024" "command-a-reasoning-08-2025" "north-mini-code-1-0")
     :npm "@ai-sdk/cohere")
    (:id "cortecs"
     :name "Cortecs"
     :api "https://api.cortecs.ai/v1"
     :env ("CORTECS_API_KEY")
     :models ("deepseek-r1-0528" "deepseek-v4-flash" "minimax-m2.5" "deepseek-v3-0324" "claude-opus4-7" "glm-4.7" "qwen3-235b-a22b-instruct-2507" "qwen3-coder-30b-a3b-instruct" "minimax-m2.1" "qwen3-32b" "claude-4-6-sonnet" "claude-sonnet-4" "llama-4-maverick" "gemini-2.5-pro" "claude-4-5-sonnet")
     :npm "@ai-sdk/openai-compatible")
    (:id "crof"
     :name "CrofAI"
     :api "https://crof.ai/v1"
     :env ("CROF_API_KEY")
     :models ("deepseek-v4-flash" "minimax-m2.5" "greg-2-ultra" "glm-4.7" "deepseek-v4-pro-lightning" "greg-rp" "gemma-4-31b-it" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-5.2" "greg-2-super" "kimi-k2.5-lightning" "kimi-k2.5" "kimi-k2.6")
     :npm "@ai-sdk/openai-compatible")
    (:id "crossmodel"
     :name "CrossModel"
     :api "https://api.crossmodel.ai/v1"
     :env ("CROSSMODEL_API_KEY")
     :models ("z-ai/glm-4.7" "z-ai/glm-5.1" "z-ai/glm-5.2" "z-ai/glm-5" "z-ai/glm-5-turbo" "openai/gpt-5.4-nano" "openai/gpt-5.4" "openai/gpt-5.4-mini" "openai/gpt-5.5-pro" "openai/gpt-4o-mini" "openai/gpt-5.5" "xiaomi/mimo-v2.5" "xiaomi/mimo-v2.5-pro" "anthropic/claude-opus-4-7" "anthropic/claude-sonnet-5")
     :npm "@ai-sdk/openai-compatible")
    (:id "databricks"
     :name "Databricks"
     :api "https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1"
     :env ("DATABRICKS_HOST" "DATABRICKS_TOKEN")
     :models ("databricks-claude-opus-4-7" "databricks-gpt-5-4" "databricks-gemini-3-flash" "databricks-claude-opus-4-5" "databricks-gpt-5-nano" "databricks-gpt-5-mini" "databricks-gpt-5" "databricks-gemini-2-5-pro" "databricks-gemini-3-1-pro" "databricks-gemini-2-5-flash" "databricks-claude-sonnet-4" "databricks-glm-5-2" "databricks-claude-haiku-4-5" "databricks-gpt-5-4-nano" "databricks-claude-opus-4-6")
     :npm "@ai-sdk/openai-compatible")
    (:id "deepinfra"
     :name "Deep Infra"
     :api "https://api.deepinfra.com/v1/openai"
     :env ("DEEPINFRA_API_KEY")
     :models ("meta-llama/Meta-Llama-3.1-70B-Instruct" "meta-llama/Meta-Llama-3.1-8B-Instruct" "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" "meta-llama/Llama-4-Scout-17B-16E-Instruct" "meta-llama/Llama-3.3-70B-Instruct-Turbo" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.7-Max" "Qwen/Qwen3.6-27B" "Qwen/Qwen3-Next-80B-A3B-Instruct" "Qwen/Qwen3-Max")
     :npm "@ai-sdk/deepinfra")
    (:id "deepseek"
     :name "DeepSeek"
     :api "https://api.deepseek.com/v1"
     :env ("DEEPSEEK_API_KEY")
     :models ("deepseek-chat" "deepseek-reasoner" "deepseek-v4-flash" "deepseek-v4-pro")
     :npm "@ai-sdk/openai-compatible")
    (:id "digitalocean"
     :name "DigitalOcean"
     :api "https://inference.do-ai.run/v1"
     :env ("DIGITALOCEAN_ACCESS_TOKEN")
     :models ("anthropic-claude-haiku-4.5" "openai-gpt-image-1" "e5-large-v2" "bge-m3" "mistral-3-14B" "nemotron-3-ultra-550b" "minimax-m2.5" "openai-gpt-5.4-nano" "deepseek-v3" "openai-gpt-image-2" "openai-gpt-5.2" "deepseek-r1-distill-llama-70b" "qwen3-embedding-0.6b" "gemma-4-31B-it" "llama-4-maverick")
     :npm "@ai-sdk/openai-compatible")
    (:id "dinference"
     :name "DInference"
     :api "https://api.dinference.com/v1"
     :env ("DINFERENCE_API_KEY")
     :models ("minimax-m2.5" "glm-4.7" "glm-5.1" "gpt-oss-120b" "glm-5")
     :npm "@ai-sdk/openai-compatible")
    (:id "drun"
     :name "D.Run (China)"
     :api "https://chat.d.run/v1"
     :env ("DRUN_API_KEY")
     :models ("public/deepseek-v3" "public/deepseek-r1" "public/minimax-m25")
     :npm "@ai-sdk/openai-compatible")
    (:id "empiriolabs"
     :name "EmpirioLabs AI"
     :api "https://api.empiriolabs.ai/v1"
     :env ("EMPIRIOLABS_API_KEY")
     :models ("qwen3-5-plus" "deepseek-v4-flash" "kimi-k2-6" "qwen3-5-27b" "step-3-7-flash" "qwen3-5-397b-a17b" "qwen3-5-35b-a3b" "qwen3-max" "glm-5-1" "qwen3-7-plus" "kimi-k2-7-code" "deepseek-v4-pro" "glm-4-5-flash" "qwen3-6-flash" "minimax-m2-7-highspeed")
     :npm "@ai-sdk/openai-compatible")
    (:id "evroc"
     :name "evroc"
     :api "https://models.think.evroc.com/v1"
     :env ("EVROC_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3-Reranker-4B" "Qwen/Qwen3.6-35B-A3B-FP8" "Qwen/Qwen3-VL-30B-A3B-Instruct" "openai/gpt-oss-120b" "openai/whisper-large-v3-turbo" "openai/whisper-large-v3" "mistralai/Mistral-Medium-3.5-128B" "mistralai/Voxtral-Small-24B-2507" "nvidia/Llama-3.3-70B-Instruct-FP8" "evroc/roc" "KBLab/kb-whisper-large" "intfloat/multilingual-e5-large-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "fastrouter"
     :name "FastRouter"
     :api "https://go.fastrouter.ai/api/v1"
     :env ("FASTROUTER_API_KEY")
     :models ("wanx/wan-v2-6" "moonshotai/kimi-k2" "moonshotai/kimi-k2.6" "google/imagen-4.0-fast" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash" "google/veo3.1-lite" "google/gemma-4-31b-it" "google/veo3.1" "google/imagen-4.0-ultra" "google/gemini-3-pro-image-preview" "google/gemini-3.1-flash-image-preview" "google/gemini-3.1-pro-preview" "google/veo3.1-fast")
     :npm "@ai-sdk/openai-compatible")
    (:id "fireworks-ai"
     :name "Fireworks AI"
     :api "https://api.fireworks.ai/inference/v1"
     :env ("FIREWORKS_API_KEY")
     :models ("accounts/fireworks/routers/kimi-k2p6-turbo" "accounts/fireworks/routers/glm-5p2-fast" "accounts/fireworks/routers/kimi-k2p7-code-fast" "accounts/fireworks/routers/glm-5p1-fast" "accounts/fireworks/routers/kimi-k2p6-fast" "accounts/fireworks/models/deepseek-v4-flash" "accounts/fireworks/models/deepseek-v4-pro" "accounts/fireworks/models/minimax-m2p7" "accounts/fireworks/models/minimax-m3" "accounts/fireworks/models/kimi-k2p6" "accounts/fireworks/models/qwen3p7-plus" "accounts/fireworks/models/glm-5p1" "accounts/fireworks/models/glm-5p2" "accounts/fireworks/models/gpt-oss-120b" "accounts/fireworks/models/gpt-oss-20b")
     :npm "@ai-sdk/openai-compatible")
    (:id "freemodel"
     :name "FreeModel"
     :api "https://cc.freemodel.dev/v1"
     :env ("FREEMODEL_API_KEY")
     :models ("claude-haiku-4-5-20251001" "claude-opus-4-7" "claude-opus-4-8" "gpt-5.3-codex" "claude-fable-5" "gpt-5.4" "gpt-5.4-mini" "claude-opus-4-6" "claude-sonnet-4-6" "gpt-5.5")
     :npm "@ai-sdk/anthropic")
    (:id "friendli"
     :name "Friendli"
     :api "https://api.friendli.ai/serverless/v1"
     :env ("FRIENDLI_TOKEN")
     :models ("google/gemma-4-31B-it" "Qwen/Qwen3-235B-A22B-Instruct-2507" "zai-org/GLM-5.2" "zai-org/GLM-5.1" "deepseek-ai/DeepSeek-V3.2" "MiniMaxAI/MiniMax-M2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "frogbot"
     :name "FrogBot"
     :api "https://app.frogbot.ai/api/v1"
     :env ("FROGBOT_API_KEY")
     :models ("minimax-m2-5" "kimi-k2-6" "zai-glm-5-1" "grok-code-fast-1" "gemini-2.5-pro" "gemini-2.5-flash" "gpt-4o" "qwen-3-6-plus" "grok-4-3" "deepseek-v4-pro" "claude-opus-4-7" "grok-4-1-fast-non-reasoning" "minimax-m2-7" "gpt-5-3-codex" "gpt-5-4-nano")
     :npm "@ai-sdk/openai-compatible")
    (:id "github-copilot"
     :name "GitHub Copilot"
     :api "https://api.githubcopilot.com"
     :env ("GITHUB_TOKEN")
     :models ("claude-sonnet-4.5" "claude-sonnet-4" "gemini-2.5-pro" "claude-haiku-4.5" "gemini-3.5-flash" "kimi-k2.7-code" "claude-sonnet-5" "gpt-5.4-nano" "claude-opus-4.7" "mai-code-1-flash-picker" "gpt-5.2" "gpt-5.3-codex" "gpt-5.6-luna" "gpt-5.6-terra" "claude-opus-4.8")
     :npm "@ai-sdk/openai-compatible")
    (:id "github-models"
     :name "GitHub Models"
     :api "https://models.github.ai/inference"
     :env ("GITHUB_TOKEN")
     :models ("ai21-labs/ai21-jamba-1.5-mini" "ai21-labs/ai21-jamba-1.5-large" "core42/jais-30b-chat" "xai/grok-3-mini" "xai/grok-3" "microsoft/phi-3.5-moe-instruct" "microsoft/phi-3-small-128k-instruct" "microsoft/phi-3.5-mini-instruct" "microsoft/phi-3-medium-128k-instruct" "microsoft/phi-3-small-8k-instruct" "microsoft/phi-4-reasoning" "microsoft/mai-ds-r1" "microsoft/phi-4-mini-instruct" "microsoft/phi-4" "microsoft/phi-3.5-vision-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "gitlab"
     :name "GitLab Duo"
     :api "https://gitlab.com/api/v4/ai"
     :env ("GITLAB_TOKEN")
     :models ("duo-chat-opus-4-5" "duo-chat-opus-4-8" "duo-chat-opus-4-7" "duo-chat-gpt-5-2-codex" "duo-chat-fable-5" "duo-chat-gpt-5-5" "duo-chat-opus-4-6" "duo-chat-gpt-5-4" "duo-chat-gpt-5-codex" "duo-chat-gpt-5-4-nano" "duo-chat-sonnet-4-6" "duo-chat-gpt-5-mini" "duo-chat-sonnet-5" "duo-chat-gpt-5-4-mini" "duo-chat-gpt-5-3-codex")
     :npm "gitlab-ai-provider")
    (:id "gmicloud"
     :name "GMI Cloud"
     :api "https://api.gmi-serving.com/v1"
     :env ("GMICLOUD_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "moonshotai/kimi-k2.7-code-highspeed" "Qwen/Qwen3.7-Max" "openai/gpt-5.5" "anthropic/claude-opus-4.7" "anthropic/claude-opus-4.8" "anthropic/claude-sonnet-4.6" "anthropic/claude-opus-4.6" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5-FP8" "zai-org/GLM-5.2-FP8" "deepseek-ai/DeepSeek-V4-Flash" "deepseek-ai/DeepSeek-V4-Pro")
     :npm "@ai-sdk/openai-compatible")
    (:id "google"
     :name "Google"
     :api "https://generativelanguage.googleapis.com/v1beta/openai"
     :env ("GOOGLE_API_KEY" "GOOGLE_GENERATIVE_AI_API_KEY" "GEMINI_API_KEY")
     :models ("gemini-2.0-flash" "gemini-1.5-pro" "gemini-1.5-flash" "gemini-3.1-flash-lite" "gemini-2.5-flash-preview-tts" "gemini-2.5-pro" "gemini-2.5-flash" "gemini-3.5-flash" "gemma-4-31b-it" "gemini-embedding-001" "gemini-3.1-pro-preview-customtools" "gemini-flash-lite-latest" "gemini-3-pro-image-preview" "gemini-2.5-flash-image" "gemini-2.5-flash-lite")
     :npm "@ai-sdk/google")
    (:id "google-vertex"
     :name "Vertex"
     :api "https://${GOOGLE_VERTEX_LOCATION}-aiplatform.googleapis.com/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/publishers/google/models"
     :env ("GOOGLE_VERTEX_PROJECT" "GOOGLE_VERTEX_LOCATION" "GOOGLE_APPLICATION_CREDENTIALS")
     :models ("gemini-2.5-pro-tts" "claude-haiku-4-5@20251001" "gemini-3.1-flash-lite" "gemini-3.1-flash-image" "gemini-2.5-pro" "gemini-2.5-flash-tts" "gemini-2.5-flash" "gemini-3.5-flash" "claude-opus-4@20250514" "claude-opus-4-1@20250805" "gemini-embedding-001" "claude-opus-4-5@20251101" "claude-3-5-haiku@20241022" "gemini-3.1-pro-preview-customtools" "gemini-flash-lite-latest")
     :npm "@ai-sdk/google-vertex")
    (:id "google-vertex-anthropic"
     :name "Vertex (Anthropic)"
     :api "https://aiplatform.${GOOGLE_VERTEX_LOCATION}.rep.googleapis.com/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/publishers/anthropic/models"
     :env ("GOOGLE_VERTEX_PROJECT" "GOOGLE_VERTEX_LOCATION" "GOOGLE_APPLICATION_CREDENTIALS")
     :models ("claude-haiku-4-5@20251001" "claude-opus-4@20250514" "claude-opus-4-1@20250805" "claude-opus-4-5@20251101" "claude-3-5-haiku@20241022" "claude-sonnet-4@20250514" "claude-opus-4-7@default" "claude-sonnet-4-5@20250929" "claude-sonnet-5@default" "claude-opus-4-6@default" "claude-opus-4-8@default" "claude-sonnet-4-6@default")
     :npm "@ai-sdk/google-vertex/anthropic")
    (:id "groq"
     :name "Groq"
     :api "https://api.groq.com/openai/v1"
     :env ("GROQ_API_KEY")
     :models ("llama-3.3-70b-versatile" "llama-3.1-8b-instant" "mixtral-8x7b-32768" "whisper-large-v3-turbo" "whisper-large-v3" "meta-llama/llama-prompt-guard-2-86m" "meta-llama/llama-prompt-guard-2-22m" "meta-llama/llama-4-scout-17b-16e-instruct" "openai/gpt-oss-safeguard-20b" "openai/gpt-oss-120b" "openai/gpt-oss-20b" "canopylabs/orpheus-v1-english" "canopylabs/orpheus-arabic-saudi" "groq/compound" "groq/compound-mini")
     :npm "@ai-sdk/groq")
    (:id "helicone"
     :name "Helicone"
     :api "https://ai-gateway.helicone.ai/v1"
     :env ("HELICONE_API_KEY")
     :models ("chatgpt-4o-latest" "gpt-4.1-mini-2025-04-14" "deepseek-v3.1-terminus" "claude-3.5-haiku" "llama-3.1-8b-instruct" "o3" "llama-prompt-guard-2-86m" "qwen3-coder-30b-a3b-instruct" "hermes-2-pro-llama-3-8b" "deepseek-v3" "grok-code-fast-1" "o1-mini" "deepseek-r1-distill-llama-70b" "qwen3-32b" "claude-sonnet-4")
     :npm "@ai-sdk/openai-compatible")
    (:id "hpc-ai"
     :name "HPC-AI"
     :api "https://api.hpc-ai.com/inference/v1"
     :env ("HPC_AI_API_KEY")
     :models ("moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2.5" "openai/gpt-5.5" "anthropic/claude-opus-4.7" "zai-org/glm-5.1" "zai-org/glm-5.2" "deepseek/deepseek-v4-flash" "deepseek/deepseek-v4-pro" "minimax/minimax-m2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "huggingface"
     :name "Hugging Face"
     :api "https://router.huggingface.co/v1"
     :env ("HF_TOKEN")
     :models ("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2-Instruct-0905" "moonshotai/Kimi-K2-Instruct" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "stepfun-ai/Step-3.5-Flash" "stepfun-ai/Step-3.7-Flash" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3-Coder-Next" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3.6-27B")
     :npm "@ai-sdk/openai-compatible")
    (:id "iflowcn"
     :name "iFlow"
     :api "https://apis.iflow.cn/v1"
     :env ("IFLOW_API_KEY")
     :models ("qwen3-coder-plus" "deepseek-v3" "kimi-k2" "qwen3-32b" "qwen3-max-preview" "qwen3-max" "qwen3-235b" "glm-4.6" "qwen3-235b-a22b-thinking-2507" "deepseek-r1" "qwen3-vl-plus" "qwen3-235b-a22b-instruct" "kimi-k2-0905" "deepseek-v3.2")
     :npm "@ai-sdk/openai-compatible")
    (:id "inception"
     :name "Inception"
     :api "https://api.inceptionlabs.ai/v1"
     :env ("INCEPTION_API_KEY")
     :models ("mercury-edit-2" "mercury-2")
     :npm "@ai-sdk/openai-compatible")
    (:id "inceptron"
     :name "Inceptron"
     :api "https://api.inceptron.io/v1"
     :env ("INCEPTRON_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.7-Code" "moonshotai/Kimi-K2.6-Fast" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5.2" "MiniMaxAI/MiniMax-M2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "inference"
     :name "Inference"
     :api "https://inference.net/v1"
     :env ("INFERENCE_API_KEY")
     :models ("mistral/mistral-nemo-12b-instruct" "google/gemma-3" "osmosis/osmosis-structure-0.6b" "qwen/qwen3-embedding-4b" "qwen/qwen-2.5-7b-vision-instruct" "meta/llama-3.1-8b-instruct" "meta/llama-3.2-1b-instruct" "meta/llama-3.2-11b-vision-instruct" "meta/llama-3.2-3b-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "inferx"
     :name "InferX"
     :api "https://model.inferx.net/v1"
     :env ("INFERX_API_KEY")
     :models ("google/gemma-4-31b-it-fp8" "qwen/qwen3-coder-next-fp8-1m" "qwen/qwen3.5-122b-a10b-nvfp4" "qwen/qwen3.6-35b-a3b-fp8" "qwen/qwen3-coder-next-fp8" "qwen/qwen3.6-27b-fp8")
     :npm "@ai-sdk/openai-compatible")
    (:id "io-net"
     :name "IO.NET"
     :api "https://api.intelligence.io.solutions/api/v1"
     :env ("IOINTELLIGENCE_API_KEY")
     :models ("meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" "meta-llama/Llama-3.3-70B-Instruct" "meta-llama/Llama-3.2-90B-Vision-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2-Instruct-0905" "Qwen/Qwen2.5-VL-32B-Instruct" "Qwen/Qwen3-Next-80B-A3B-Instruct" "Qwen/Qwen3-235B-A22B-Thinking-2507" "openai/gpt-oss-120b" "openai/gpt-oss-20b" "mistralai/Devstral-Small-2505" "mistralai/Magistral-Small-2506" "mistralai/Mistral-Large-Instruct-2411" "mistralai/Mistral-Nemo-Instruct-2407" "Intel/Qwen3-Coder-480B-A35B-Instruct-int4-mixed-ar")
     :npm "@ai-sdk/openai-compatible")
    (:id "jiekou"
     :name "Jiekou.AI"
     :api "https://api.jiekou.ai/openai"
     :env ("JIEKOU_API_KEY")
     :models ("o3" "grok-code-fast-1" "gpt-5.2-pro" "gemini-2.5-pro" "claude-haiku-4-5-20251001" "gpt-5-pro" "gemini-2.5-flash" "o4-mini" "gemini-2.5-flash-lite-preview-09-2025" "claude-opus-4-1-20250805" "grok-4-1-fast-non-reasoning" "gpt-5-chat-latest" "claude-opus-4-5-20251101" "gpt-5.1-codex" "gpt-5.1-codex-max")
     :npm "@ai-sdk/openai-compatible")
    (:id "kenari"
     :name "Kenari"
     :api "https://kenari.id/v1"
     :env ("KENARI_API_KEY")
     :models ("deepseek-v4-flash" "kimi-k2-6" "glm-5-1" "gemma-4-31b-it" "grok-4-3" "qwen3-7-plus" "kimi-k2-7-code" "deepseek-v4-pro" "deepseek-v4-flash:free" "claude-opus-4-7" "minimax-m3" "claude-opus-4-8" "gpt-5-4-mini" "mimo-v2-5" "gpt-oss-120b")
     :npm "@ai-sdk/openai-compatible")
    (:id "kilo"
     :name "Kilo Gateway"
     :api "https://api.kilo.ai/api/gateway"
     :env ("KILO_API_KEY")
     :models ("inclusionai/ling-2.6-1t" "inclusionai/ring-2.6-1t" "inclusionai/ling-2.6-flash" "ibm-granite/granite-4.0-h-micro" "ibm-granite/granite-4.1-8b" "meta-llama/llama-3.1-8b-instruct" "meta-llama/llama-3-70b-instruct" "meta-llama/llama-3.1-70b-instruct" "meta-llama/llama-3.2-1b-instruct" "meta-llama/llama-4-maverick" "meta-llama/llama-3.2-11b-vision-instruct" "meta-llama/llama-3.3-70b-instruct" "meta-llama/llama-guard-3-8b" "meta-llama/llama-guard-4-12b" "meta-llama/llama-3-8b-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "kimi-for-coding"
     :name "Kimi For Coding"
     :api "https://api.kimi.com/coding/v1"
     :env ("KIMI_API_KEY")
     :models ("k2p7" "kimi-k2-thinking" "k2p5" "k2p6")
     :npm "@ai-sdk/anthropic")
    (:id "kuae-cloud-coding-plan"
     :name "KUAE Cloud Coding Plan"
     :api "https://coding-plan-endpoint.kuaecloud.net/v1"
     :env ("KUAE_API_KEY")
     :models ("GLM-4.7")
     :npm "@ai-sdk/openai-compatible")
    (:id "lilac"
     :name "Lilac"
     :api "https://api.getlilac.com/v1"
     :env ("LILAC_API_KEY")
     :models ("moonshotai/kimi-k2.6" "minimaxai/minimax-m3" "google/gemma-4-31b-it" "zai-org/glm-5.2")
     :npm "@ai-sdk/openai-compatible")
    (:id "llama"
     :name "Llama"
     :api "https://api.llama.com/compat/v1"
     :env ("LLAMA_API_KEY")
     :models ("llama-4-scout-17b-16e-instruct-fp8" "cerebras-llama-4-maverick-17b-128e-instruct" "llama-3.3-70b-instruct" "groq-llama-4-maverick-17b-128e-instruct" "cerebras-llama-4-scout-17b-16e-instruct" "llama-3.3-8b-instruct" "llama-4-maverick-17b-128e-instruct-fp8")
     :npm "@ai-sdk/openai-compatible")
    (:id "llamacpp"
     :name "llama.cpp"
     :api "http://127.0.0.1:8080/v1"
     :env nil
     :models nil
     :npm "llamacpp")
    (:id "llmgateway"
     :name "LLM Gateway"
     :api "https://api.llmgateway.io/v1"
     :env ("LLMGATEWAY_API_KEY")
     :models ("qwen-coder-plus" "mistral-large-latest" "qwen3-vl-235b-a22b-thinking" "devstral-small-2507" "qwen3-vl-30b-a3b-thinking" "deepseek-v4-flash" "qwen3-coder-plus" "minimax-m2.7-highspeed" "qwen-plus" "o3" "nemotron-3-ultra-550b" "minimax-m2.5" "grok-4-20-beta-0309-non-reasoning" "glm-4.7" "gemini-3.1-flash-lite")
     :npm "@ai-sdk/openai-compatible")
    (:id "llmtr"
     :name "LLMTR"
     :api "https://llmtr.com/v1"
     :env ("LLMTR_API_KEY")
     :models ("sincap" "magibu-11b-v8" "gemma-4" "medgemma-4b" "qwen3-6-35b" "trendyol-7b")
     :npm "@ai-sdk/openai-compatible")
    (:id "lmstudio"
     :name "LMStudio"
     :api "http://127.0.0.1:1234/v1"
     :env ("LMSTUDIO_API_KEY")
     :models ("openai/gpt-oss-20b" "qwen/qwen3-30b-a3b-2507" "qwen/qwen3-coder-30b")
     :npm "@ai-sdk/openai-compatible")
    (:id "longcat"
     :name "LongCat"
     :api "https://api.longcat.chat/openai"
     :env ("LONGCAT_API_KEY")
     :models ("LongCat-2.0")
     :npm "@ai-sdk/openai-compatible")
    (:id "lucidquery"
     :name "LucidQuery"
     :api "https://api.lucidquery.com/v1"
     :env ("LUCIDQUERY_API_KEY")
     :models ("lucidnova-rf1-100b" "lucidquery-nexus-coder" "lucidquery-agi-01-swift" "lucidquery-agi-01-frontier")
     :npm "@ai-sdk/openai-compatible")
    (:id "meganova"
     :name "Meganova"
     :api "https://api.meganova.ai/v1"
     :env ("MEGANOVA_API_KEY")
     :models ("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2.5" "Qwen/Qwen2.5-VL-32B-Instruct" "Qwen/Qwen3.5-Plus" "Qwen/Qwen3-235B-A22B-Instruct-2507" "XiaomiMiMo/MiMo-V2-Flash" "mistralai/Mistral-Small-3.2-24B-Instruct-2506" "mistralai/Mistral-Nemo-Instruct-2407" "zai-org/GLM-4.6" "zai-org/GLM-5" "zai-org/GLM-4.7" "deepseek-ai/DeepSeek-V3-0324" "deepseek-ai/DeepSeek-R1-0528" "deepseek-ai/DeepSeek-V3.1")
     :npm "@ai-sdk/openai-compatible")
    (:id "merge-gateway"
     :name "Merge Gateway"
     :api "https://ai.mergegateway.com/v1"
     :env ("MERGE_GATEWAY_API_KEY")
     :models ("xai/grok-4.3" "xai/grok-4.20-0309-reasoning" "moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2.7-code-highspeed" "mistral/codestral-latest" "mistral/mistral-large-latest" "mistral/devstral-small-2507" "mistral/pixtral-large-latest" "mistral/mistral-medium-latest" "mistral/mistral-small-latest" "mistral/mistral-medium-2505" "mistral/mistral-large-2411")
     :npm "merge-gateway-ai-sdk-provider")
    (:id "meta"
     :name "Meta"
     :api "https://api.meta.ai/v1"
     :env ("META_MODEL_API_KEY")
     :models ("muse-spark-1.1")
     :npm "@ai-sdk/openai")
    (:id "minimax"
     :name "MiniMax (minimax.io)"
     :api "https://api.minimax.io/anthropic/v1"
     :env ("MINIMAX_API_KEY")
     :models ("MiniMax-M2.1" "MiniMax-M2.5-highspeed" "MiniMax-M2.7-highspeed" "MiniMax-M2" "MiniMax-M2.5" "MiniMax-M3" "MiniMax-M2.7")
     :npm "@ai-sdk/anthropic")
    (:id "minimax-cn"
     :name "MiniMax (minimaxi.com)"
     :api "https://api.minimaxi.com/anthropic/v1"
     :env ("MINIMAX_API_KEY")
     :models ("MiniMax-M2.1" "MiniMax-M2.5-highspeed" "MiniMax-M2.7-highspeed" "MiniMax-M2" "MiniMax-M2.5" "MiniMax-M3" "MiniMax-M2.7")
     :npm "@ai-sdk/anthropic")
    (:id "minimax-cn-coding-plan"
     :name "MiniMax Token Plan (minimaxi.com)"
     :api "https://api.minimaxi.com/anthropic/v1"
     :env ("MINIMAX_API_KEY")
     :models ("MiniMax-M2.1" "MiniMax-M2.5-highspeed" "MiniMax-M2.7-highspeed" "MiniMax-M2" "MiniMax-M2.5" "MiniMax-M3" "MiniMax-M2.7")
     :npm "@ai-sdk/anthropic")
    (:id "minimax-coding-plan"
     :name "MiniMax Token Plan (minimax.io)"
     :api "https://api.minimax.io/anthropic/v1"
     :env ("MINIMAX_API_KEY")
     :models ("MiniMax-M2.1" "MiniMax-M2.5-highspeed" "MiniMax-M2.7-highspeed" "MiniMax-M2" "MiniMax-M2.5" "MiniMax-M3" "MiniMax-M2.7")
     :npm "@ai-sdk/anthropic")
    (:id "mistral"
     :name "Mistral"
     :api "https://api.mistral.ai/v1"
     :env ("MISTRAL_API_KEY")
     :models ("mistral-large-latest" "mistral-small-latest" "codestral-latest" "open-mistral-7b" "devstral-small-2507" "ministral-3b-latest" "pixtral-large-latest" "mistral-nemo" "mistral-embed" "mistral-small-2506" "ministral-8b-latest" "open-mixtral-8x22b" "mistral-medium-latest" "devstral-small-2505" "magistral-small")
     :npm "@ai-sdk/mistral")
    (:id "mixlayer"
     :name "Mixlayer"
     :api "https://models.mixlayer.ai/v1"
     :env ("MIXLAYER_API_KEY")
     :models ("qwen/qwen3.5-27b" "qwen/qwen3.5-35b-a3b" "qwen/qwen3.5-9b" "qwen/qwen3.5-397b-a17b" "qwen/qwen3.5-122b-a10b")
     :npm "@ai-sdk/openai-compatible")
    (:id "moark"
     :name "Moark"
     :api "https://moark.com/v1"
     :env ("MOARK_API_KEY")
     :models ("MiniMax-M2.1" "GLM-4.7")
     :npm "@ai-sdk/openai-compatible")
    (:id "model-oracle-ai"
     :name "Model Oracle AI"
     :api "https://api.modeloracle.com/api/v1"
     :env ("MODEL_ORACLE_API_KEY")
     :models ("gpt-5" "claude-haiku-4.5" "o4-mini" "deepseek-v4-pro" "claude-sonnet-5" "gpt-5.4-nano" "glm-5.2" "claude-opus-4.8" "claude-fable-5" "gpt-5.4" "gpt-5.4-mini" "gpt-4.1" "gpt-4.1-mini" "auto" "gpt-5.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "modelscope"
     :name "ModelScope"
     :api "https://api-inference.modelscope.cn/v1"
     :env ("MODELSCOPE_API_KEY")
     :models ("Qwen/Qwen3-30B-A3B-Thinking-2507" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-30B-A3B-Instruct" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-235B-A22B-Instruct-2507" "ZhipuAI/GLM-4.6" "ZhipuAI/GLM-4.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "moonshotai"
     :name "Moonshot AI"
     :api "https://api.moonshot.ai/v1"
     :env ("MOONSHOT_API_KEY")
     :models ("kimi-k2-0905-preview" "kimi-k2-thinking-turbo" "kimi-k2.7-code" "kimi-k2-thinking" "kimi-k2-0711-preview" "kimi-k2-turbo-preview" "kimi-k2.5" "kimi-k2.6" "kimi-k2.7-code-highspeed")
     :npm "@ai-sdk/openai-compatible")
    (:id "moonshotai-cn"
     :name "Moonshot AI (China)"
     :api "https://api.moonshot.cn/v1"
     :env ("MOONSHOT_API_KEY")
     :models ("kimi-k2.7-code-highspeed" "kimi-k2.6" "kimi-k2.5" "kimi-k2-turbo-preview" "kimi-k2-0711-preview" "kimi-k2-thinking" "kimi-k2.7-code" "kimi-k2-thinking-turbo" "kimi-k2-0905-preview")
     :npm "@ai-sdk/openai-compatible")
    (:id "morph"
     :name "Morph"
     :api "https://api.morphllm.com/v1"
     :env ("MORPH_API_KEY")
     :models ("morph-v3-fast" "morph-v3-large" "auto")
     :npm "@ai-sdk/openai-compatible")
    (:id "nano-gpt"
     :name "NanoGPT"
     :api "https://nano-gpt.com/api/v1"
     :env ("NANO_GPT_API_KEY")
     :models ("step-3" "qwen3.5-35b-a3b:thinking" "glm-4.1v-thinking-flashx" "ernie-x1.1-preview" "qwen25-vl-72b-instruct" "gemini-2.0-pro-exp-02-05" "doubao-seed-2-0-lite-260215" "Qwen3.5-27B-Writer-V2-Derestricted" "claude-opus-4-thinking:8192" "qwen3-vl-235b-a22b-thinking" "glm-4-air-0111" "Qwen3.5-27B-Queen-Derestricted" "gemini-2.5-pro-preview-03-25" "brave-research" "qwen-plus")
     :npm "@ai-sdk/openai-compatible")
    (:id "nearai"
     :name "NEAR AI Cloud"
     :api "https://cloud-api.near.ai/v1"
     :env ("NEARAI_API_KEY")
     :models ("google/gemini-3.1-flash-lite" "google/gemma-4-31B-it" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash" "google/gemini-3-pro" "google/gemini-2.5-flash-lite" "Qwen/Qwen3-Embedding-0.6B" "Qwen/Qwen3-Reranker-0.6B" "Qwen/Qwen3.6-35B-A3B-FP8" "Qwen/Qwen3.5-122B-A10B" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-VL-30B-A3B-Instruct" "openai/o3" "openai/gpt-5")
     :npm "@ai-sdk/openai-compatible")
    (:id "nebius"
     :name "Nebius Token Factory"
     :api "https://api.tokenfactory.nebius.com/v1"
     :env ("NEBIUS_API_KEY")
     :models ("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2.5-fast" "moonshotai/Kimi-K2.5" "google/gemma-3-27b-it" "Qwen/Qwen3-Next-80B-A3B-Thinking-fast" "Qwen/Qwen2.5-VL-72B-Instruct" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3.5-397B-A17B-fast" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-Next-80B-A3B-Thinking" "Qwen/Qwen3-235B-A22B-Instruct-2507" "Qwen/Qwen3-32B" "Qwen/Qwen3-235B-A22B-Thinking-2507-fast" "openai/gpt-oss-120b-fast")
     :npm "@ai-sdk/openai-compatible")
    (:id "neon"
     :name "Neon"
     :api "${NEON_AI_GATEWAY_BASE_URL}/ai-gateway/mlflow/v1"
     :env ("NEON_AI_GATEWAY_BASE_URL" "NEON_AI_GATEWAY_TOKEN")
     :models ("gemini-3-flash" "claude-sonnet-4" "qwen3-next-80b-a3b-instruct" "llama-4-maverick" "claude-opus-4-5" "gpt-5" "gemma-3-12b" "gpt-5-1-codex-mini" "gpt-5-1" "meta-llama-3-3-70b-instruct" "gemini-3-pro" "gpt-5-2" "gemini-3-1-flash-lite" "claude-sonnet-4-5" "claude-opus-4-7")
     :npm "@ai-sdk/openai-compatible")
    (:id "neuralwatt"
     :name "Neuralwatt"
     :api "https://api.neuralwatt.com/v1"
     :env ("NEURALWATT_API_KEY")
     :models ("kimi-k2.5-fast" "kimi-k2.6-flex" "glm-5.2-short-fast-flex" "glm-5.2-flex" "glm-5.2" "glm-5.2-short-fast" "qwen3.5-397b-fast" "kimi-k2.6-fast" "qwen3.6-35b-fast" "glm-5.2-short-flex" "glm-5.2-fast" "glm-5.2-short" "kimi-k2.7-code-flex" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5")
     :npm "@ai-sdk/openai-compatible")
    (:id "nova"
     :name "Nova"
     :api "https://api.nova.amazon.com/v1"
     :env ("NOVA_API_KEY")
     :models ("nova-2-pro-v1" "nova-2-lite-v1")
     :npm "@ai-sdk/openai-compatible")
    (:id "novita-ai"
     :name "NovitaAI"
     :api "https://api.novita.ai/openai"
     :env ("NOVITA_API_KEY")
     :models ("inclusionai/ling-2.6-1t" "inclusionai/ring-2.6-1t" "inclusionai/ling-2.6-flash" "meta-llama/llama-3.1-8b-instruct" "meta-llama/llama-3-70b-instruct" "meta-llama/llama-4-scout-17b-16e-instruct" "meta-llama/llama-3.3-70b-instruct" "meta-llama/llama-3-8b-instruct" "meta-llama/llama-3.2-3b-instruct" "meta-llama/llama-4-maverick-17b-128e-instruct-fp8" "moonshotai/kimi-k2-instruct" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2-0905")
     :npm "@ai-sdk/openai-compatible")
    (:id "nvidia"
     :name "Nvidia"
     :api "https://integrate.api.nvidia.com/v1"
     :env ("NVIDIA_API_KEY")
     :models ("baai/bge-m3" "moonshotai/kimi-k2-instruct-0905" "moonshotai/kimi-k2.6" "minimaxai/minimax-m3" "minimaxai/minimax-m2.7" "stepfun-ai/step-3.7-flash" "stepfun-ai/step-3.5-flash" "google/gemma-3n-e4b-it" "google/gemma-3n-e2b-it" "google/google-paligemma" "google/gemma-4-31b-it" "google/gemma-2-2b-it" "microsoft/phi-4-mini-instruct" "microsoft/phi-4-multimodal-instruct" "z-ai/glm-5.2")
     :npm "@ai-sdk/openai-compatible")
    (:id "ollama"
     :name "Ollama"
     :api "http://localhost:11434/v1"
     :env nil
     :models ("qwen2.5-coder:latest" "deepseek-r1:latest" "llama3.2:latest")
     :npm "ollama")
    (:id "ollama-cloud"
     :name "Ollama Cloud"
     :api "https://ollama.com/v1"
     :env ("OLLAMA_API_KEY")
     :models ("deepseek-v4-flash" "minimax-m2.5" "devstral-small-2:24b" "glm-4.7" "cogito-2.1:671b" "minimax-m2.1" "gpt-oss:120b" "nemotron-3-nano:30b" "ministral-3:8b" "rnj-1:8b" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-4.6" "kimi-k2-thinking")
     :npm "@ai-sdk/openai-compatible")
    (:id "openai"
     :name "OpenAI"
     :api "https://api.openai.com/v1"
     :env ("OPENAI_API_KEY")
     :models ("gpt-4o" "gpt-4o-mini" "o1" "o3-mini" "gpt-4.5-preview" "o3" "text-embedding-3-large" "gpt-5.2-pro" "gpt-5.6" "gpt-5" "gpt-3.5-turbo" "gpt-5-pro" "gpt-4" "o4-mini" "o3-pro")
     :npm "@ai-sdk/openai")
    (:id "opencode"
     :name "OpenCode Zen"
     :api "https://opencode.ai/zen/v1"
     :env ("OPENCODE_API_KEY")
     :models ("ring-2.6-1t-free" "mimo-v2-pro-free" "deepseek-v4-flash" "minimax-m2.5" "glm-4.7" "mimo-v2.5-free" "kimi-k2" "minimax-m2.1" "nemotron-3-ultra-free" "glm-4.7-free" "gemini-3-flash" "deepseek-v4-flash-free" "claude-sonnet-4" "claude-opus-4-5" "gpt-5")
     :npm "@ai-sdk/openai-compatible")
    (:id "opencode-go"
     :name "OpenCode Go"
     :api "https://opencode.ai/zen/go/v1"
     :env ("OPENCODE_API_KEY")
     :models ("deepseek-v4-flash" "minimax-m2.5" "qwen3.7-plus" "qwen3.7-max" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-5.2" "minimax-m3" "qwen3.5-plus" "minimax-m2.7" "kimi-k2.5" "mimo-v2.5" "mimo-v2-omni" "kimi-k2.6")
     :npm "@ai-sdk/openai-compatible")
    (:id "openrouter"
     :name "OpenRouter"
     :api "https://openrouter.ai/api/v1"
     :env ("OPENROUTER_API_KEY")
     :models ("inclusionai/ling-2.6-1t" "inclusionai/ring-2.6-1t" "inclusionai/ling-2.6-flash" "ibm-granite/granite-4.0-h-micro" "ibm-granite/granite-4.1-8b" "meta-llama/llama-3.1-8b-instruct" "meta-llama/llama-3.1-70b-instruct" "meta-llama/llama-3.2-1b-instruct" "meta-llama/llama-4-maverick" "meta-llama/llama-3.2-11b-vision-instruct" "meta-llama/llama-3.3-70b-instruct:free" "meta-llama/llama-3.3-70b-instruct" "meta-llama/llama-3.2-3b-instruct:free" "meta-llama/llama-guard-4-12b" "meta-llama/llama-4-scout")
     :npm "@openrouter/ai-sdk-provider")
    (:id "orcarouter"
     :name "OrcaRouter"
     :api "https://api.orcarouter.ai/v1"
     :env ("ORCAROUTER_API_KEY")
     :models ("google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemma-4-31b-it" "google/gemini-3.1-pro-preview-customtools" "google/gemini-flash-lite-latest" "google/gemini-2.5-flash-lite" "google/gemini-3.1-pro-preview" "google/gemma-4-26b-a4b-it" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "google/gemini-flash-latest" "google/gemini-3.1-flash-lite-preview" "z-ai/glm-4.7" "z-ai/glm-4.5" "z-ai/glm-5.1")
     :npm "@ai-sdk/openai-compatible")
    (:id "ovhcloud"
     :name "OVHcloud AI Endpoints"
     :api "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1"
     :env ("OVHCLOUD_API_KEY")
     :models ("qwen3-coder-30b-a3b-instruct" "qwen3-32b" "qwen3guard-gen-8b" "qwen3guard-gen-0.6b" "meta-llama-3_3-70b-instruct" "mistral-small-3.2-24b-instruct-2506" "qwen2.5-vl-72b-instruct" "gpt-oss-120b" "mistral-7b-instruct-v0.3" "mistral-nemo-instruct-2407" "qwen3.6-27b" "qwen3.5-9b" "qwen3.5-397b-a17b" "gpt-oss-20b")
     :npm "@ai-sdk/openai-compatible")
    (:id "perplexity"
     :name "Perplexity"
     :api "https://api.perplexity.ai"
     :env ("PERPLEXITY_API_KEY")
     :models ("sonar" "sonar-pro" "sonar-reasoning" "sonar-reasoning-pro" "sonar-deep-research")
     :npm "@ai-sdk/perplexity")
    (:id "perplexity-agent"
     :name "Perplexity Agent"
     :api "https://api.perplexity.ai/v1"
     :env ("PERPLEXITY_API_KEY")
     :models ("xai/grok-4-1-fast-non-reasoning" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.1-pro-preview" "google/gemini-3-flash-preview" "openai/gpt-5.2" "openai/gpt-5.4" "openai/gpt-5-mini" "openai/gpt-5.1" "openai/gpt-5.5" "nvidia/nemotron-3-super-120b-a12b" "anthropic/claude-opus-4-5" "anthropic/claude-sonnet-4-5" "anthropic/claude-opus-4-7" "anthropic/claude-haiku-4-5")
     :npm "@ai-sdk/openai")
    (:id "pioneer"
     :name "Pioneer"
     :api "https://api.pioneer.ai/v1"
     :env ("PIONEER_API_KEY")
     :models ("gemini-3-flash" "qwen3.7-plus" "claude-opus-4-5" "qwen3.7-max" "gpt-4o" "gemini-3.5-flash" "claude-sonnet-4-5" "claude-opus-4-7" "gpt-5.4-nano" "qwen3.6-flash" "claude-opus-4-8" "mistral-medium-3.5" "gpt-5.3-codex" "claude-opus-4-1" "gpt-4.1-nano")
     :npm "@ai-sdk/openai-compatible")
    (:id "poe"
     :name "Poe"
     :api "https://api.poe.com/v1"
     :env ("POE_API_KEY")
     :models ("trytako/tako" "xai/grok-code-fast-1" "xai/grok-4.1-fast-reasoning" "xai/grok-3-mini" "xai/grok-4.1-fast-non-reasoning" "xai/grok-3" "xai/grok-4-fast-reasoning" "xai/grok-4" "xai/grok-4-fast-non-reasoning" "xai/grok-4.20-multi-agent" "topazlabs-co/topazlabs" "fireworks-ai/kimi-k2.5-fw" "google/veo-3.1-fast" "google/imagen-3" "google/nano-banana-pro")
     :npm "@ai-sdk/openai-compatible")
    (:id "poolside"
     :name "Poolside"
     :api "https://inference.poolside.ai/v1"
     :env ("POOLSIDE_API_KEY")
     :models ("poolside/laguna-xs.2" "poolside/laguna-m.1" "poolside/laguna-xs-2.1")
     :npm "@ai-sdk/openai-compatible")
    (:id "privatemode-ai"
     :name "Privatemode AI"
     :api "http://localhost:8080/v1"
     :env ("PRIVATEMODE_API_KEY" "PRIVATEMODE_ENDPOINT")
     :models ("qwen3-embedding-4b" "gemma-3-27b" "gpt-oss-120b" "whisper-large-v3" "qwen3-coder-30b-a3b")
     :npm "@ai-sdk/openai-compatible")
    (:id "qihang-ai"
     :name "QiHang"
     :api "https://api.qhaigc.net/v1"
     :env ("QIHANG_API_KEY")
     :models ("claude-haiku-4-5-20251001" "gemini-2.5-flash" "claude-opus-4-5-20251101" "gpt-5.2" "claude-sonnet-4-5-20250929" "gemini-3-pro-preview" "gpt-5-mini" "gemini-3-flash-preview" "gpt-5.2-codex")
     :npm "@ai-sdk/openai-compatible")
    (:id "qiniu-ai"
     :name "Qiniu"
     :api "https://api.qnaigc.com/v1"
     :env ("QINIU_API_KEY")
     :models ("deepseek-r1-0528" "doubao-1.5-thinking-pro" "qwen3-vl-30b-a3b-thinking" "claude-3.5-haiku" "deepseek-v3-0324" "qwen3-235b-a22b-instruct-2507" "deepseek-v3" "kimi-k2" "qwen3-32b" "qwen3-max-preview" "claude-3.5-sonnet" "qwen3-next-80b-a3b-instruct" "gemini-2.5-pro" "claude-4.5-haiku" "kling-v2-6")
     :npm "@ai-sdk/openai-compatible")
    (:id "regolo-ai"
     :name "Regolo AI"
     :api "https://api.regolo.ai/v1"
     :env ("REGOLO_API_KEY")
     :models ("llama-3.1-8b-instruct" "minimax-m2.5" "mistral-small3.2" "qwen3-reranker-4b" "qwen3-embedding-8b" "llama-3.3-70b-instruct" "qwen-image" "qwen3.5-122b" "gpt-oss-120b" "qwen3-coder-next" "qwen3.5-9b" "mistral-small-4-119b" "gpt-oss-20b")
     :npm "@ai-sdk/openai-compatible")
    (:id "requesty"
     :name "Requesty"
     :api "https://router.requesty.ai/v1"
     :env ("REQUESTY_API_KEY")
     :models ("xai/grok-4" "xai/grok-4-fast" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "openai/gpt-5.2-chat" "openai/gpt-5.2-pro" "openai/gpt-5" "openai/gpt-5-chat" "openai/gpt-5-pro" "openai/o4-mini" "openai/gpt-5.1-chat" "openai/gpt-5.1-codex" "openai/gpt-5.1-codex-max")
     :npm "@ai-sdk/openai-compatible")
    (:id "routing-run"
     :name "routing.run"
     :api "https://api.routing.run/v1"
     :env ("ROUTING_RUN_API_KEY")
     :models ("kimi-k2.6-nitro" "deepseek-v4-flash" "kimi-k2.7-code" "deepseek-v4-pro" "glm-5.2" "claude-opus-4-8" "gpt-5.6-luna" "gpt-5.6-terra" "glm-5.2-nitro" "kimi-k2.6" "qwen3.5-9b" "claude-sonnet-4-6" "nemotron-3-ultra" "gpt-5.6-sol" "kimi-k2.7-code-nitro")
     :npm "@ai-sdk/openai-compatible")
    (:id "sakana"
     :name "Sakana AI"
     :api "https://api.sakana.ai/v1"
     :env ("SAKANA_API_KEY")
     :models ("fugu-ultra-20260615" "fugu" "fugu-ultra")
     :npm "@ai-sdk/openai-compatible")
    (:id "sap-ai-core"
     :name "SAP AI Core"
     :api "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2"
     :env ("AICORE_SERVICE_KEY")
     :models ("anthropic--claude-4.8-opus" "gemini-3.1-flash-lite" "anthropic--claude-4.6-sonnet" "anthropic--claude-3-sonnet" "anthropic--claude-4-sonnet" "gemini-2.5-pro" "gpt-5" "gemini-2.5-flash" "gemini-3.5-flash" "anthropic--claude-4.5-haiku" "anthropic--claude-3-haiku" "anthropic--claude-4-opus" "anthropic--claude-4.5-sonnet" "anthropic--claude-3.5-sonnet" "anthropic--claude-4.6-opus")
     :npm "@jerome-benoit/sap-ai-provider-v2")
    (:id "sarvam"
     :name "Sarvam AI"
     :api "https://api.sarvam.ai/v1"
     :env ("SARVAM_API_KEY")
     :models ("sarvam-105b" "sarvam-30b")
     :npm "@ai-sdk/openai-compatible")
    (:id "scaleway"
     :name "Scaleway"
     :api "https://api.scaleway.ai/v1"
     :env ("SCALEWAY_API_KEY")
     :models ("qwen3-235b-a22b-instruct-2507" "qwen3-coder-30b-a3b-instruct" "qwen3-embedding-8b" "bge-multilingual-gemma2" "qwen3.6-35b-a3b" "llama-3.3-70b-instruct" "glm-5.2" "pixtral-12b-2409" "mistral-small-3.2-24b-instruct-2506" "gpt-oss-120b" "gemma-4-26b-a4b-it" "mistral-medium-3.5-128b" "qwen3.5-397b-a17b" "whisper-large-v3" "gemma-3-27b-it")
     :npm "@ai-sdk/openai-compatible")
    (:id "siliconflow"
     :name "SiliconFlow"
     :api "https://api.siliconflow.com/v1"
     :env ("SILICONFLOW_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "baidu/ERNIE-4.5-300B-A47B" "ByteDance-Seed/Seed-OSS-36B-Instruct" "stepfun-ai/Step-3.5-Flash" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "inclusionAI/Ling-flash-2.0" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen2.5-7B-Instruct" "Qwen/Qwen3-VL-235B-A22B-Instruct" "Qwen/Qwen3.6-27B" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "siliconflow-cn"
     :name "SiliconFlow (China)"
     :api "https://api.siliconflow.cn/v1"
     :env ("SILICONFLOW_CN_API_KEY")
     :models ("baidu/ERNIE-4.5-300B-A47B" "ByteDance-Seed/Seed-OSS-36B-Instruct" "stepfun-ai/Step-3.5-Flash" "inclusionAI/Ling-flash-2.0" "Pro/moonshotai/Kimi-K2.6" "Pro/moonshotai/Kimi-K2.5" "Pro/zai-org/GLM-5" "Pro/zai-org/GLM-5.1" "Pro/deepseek-ai/DeepSeek-R1" "Pro/deepseek-ai/DeepSeek-V3.1-Terminus" "Pro/deepseek-ai/DeepSeek-V3.2" "Pro/deepseek-ai/DeepSeek-V3" "Pro/MiniMaxAI/MiniMax-M2.5" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.5-397B-A17B")
     :npm "@ai-sdk/openai-compatible")
    (:id "snowflake-cortex"
     :name "Snowflake Cortex"
     :api "https://${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com/api/v2/cortex/v1"
     :env ("SNOWFLAKE_ACCOUNT" "SNOWFLAKE_CORTEX_PAT")
     :models ("openai-gpt-5.1" "snowflake-llama3.3-70b" "openai-gpt-5.2" "claude-sonnet-4-5" "claude-opus-4-7" "deepseek-r1" "claude-opus-4-8" "openai-gpt-5" "openai-gpt-5.5" "claude-fable-5" "openai-gpt-5-nano" "claude-haiku-4-5" "mistral-large2" "openai-gpt-4.1" "claude-sonnet-4-6")
     :npm "@ai-sdk/openai-compatible")
    (:id "stackit"
     :name "STACKIT"
     :api "https://api.openai-compat.model-serving.eu01.onstackit.cloud/v1"
     :env ("STACKIT_API_KEY")
     :models ("cortecs/Llama-3.3-70B-Instruct-FP8-Dynamic" "google/gemma-3-27b-it" "Qwen/Qwen3.6-27B" "Qwen/Qwen3-VL-Embedding-8B" "Qwen/Qwen3-VL-235B-A22B-Instruct-FP8" "openai/gpt-oss-120b" "openai/gpt-oss-20b" "intfloat/e5-mistral-7b-instruct")
     :npm "@ai-sdk/openai-compatible")
    (:id "stepfun"
     :name "StepFun"
     :api "https://api.stepfun.com/v1"
     :env ("STEPFUN_API_KEY")
     :models ("step-1-32k" "step-3.7-flash" "step-3.5-flash-2603" "stepaudio-2.5-tts" "stepaudio-2.5-asr" "step-3.5-flash" "step-tts-2" "step-2-16k")
     :npm "@ai-sdk/openai-compatible")
    (:id "stepfun-ai"
     :name "StepFun AI"
     :api "https://api.stepfun.ai/step_plan/v1"
     :env ("STEPFUN_API_KEY")
     :models ("step-2-16k" "step-tts-2" "step-3.5-flash" "stepaudio-2.5-asr" "stepaudio-2.5-tts" "step-3.5-flash-2603" "step-3.7-flash" "step-1-32k")
     :npm "@ai-sdk/openai-compatible")
    (:id "subconscious"
     :name "Subconscious"
     :api "https://api.subconscious.dev/v1"
     :env ("SUBCONSCIOUS_API_KEY")
     :models ("subconscious/glm-5.2" "subconscious/tim-qwen3.6-27b")
     :npm "@ai-sdk/anthropic")
    (:id "submodel"
     :name "submodel"
     :api "https://llm.submodel.ai/v1"
     :env ("SUBMODEL_INSTAGEN_ACCESS_KEY")
     :models ("Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8" "Qwen/Qwen3-235B-A22B-Instruct-2507" "openai/gpt-oss-120b" "zai-org/GLM-4.5-FP8" "zai-org/GLM-4.5-Air" "deepseek-ai/DeepSeek-V3-0324" "deepseek-ai/DeepSeek-R1-0528" "deepseek-ai/DeepSeek-V3.1")
     :npm "@ai-sdk/openai-compatible")
    (:id "synthetic"
     :name "Synthetic"
     :api "https://api.synthetic.new/openai/v1"
     :env ("SYNTHETIC_API_KEY")
     :models ("hf:moonshotai/Kimi-K2.7-Code" "hf:zai-org/GLM-4.7-Flash" "hf:zai-org/GLM-5.2" "hf:MiniMaxAI/MiniMax-M3" "hf:openai/gpt-oss-120b" "hf:Qwen/Qwen3.6-27B" "hf:nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4")
     :npm "@ai-sdk/openai-compatible")
    (:id "tencent-coding-plan"
     :name "Tencent Coding Plan (China)"
     :api "https://api.lkeap.cloud.tencent.com/coding/v3"
     :env ("TENCENT_CODING_PLAN_API_KEY")
     :models ("minimax-m2.5" "kimi-k2.5" "hunyuan-turbos" "hunyuan-t1" "tc-code-latest" "glm-5" "hunyuan-2.0-instruct" "hunyuan-2.0-thinking")
     :npm "@ai-sdk/openai-compatible")
    (:id "tencent-token-plan"
     :name "Tencent Token Plan"
     :api "https://api.lkeap.cloud.tencent.com/plan/v3"
     :env ("TENCENT_TOKEN_PLAN_API_KEY")
     :models ("hy3")
     :npm "@ai-sdk/openai-compatible")
    (:id "tencent-tokenhub"
     :name "Tencent TokenHub"
     :api "https://tokenhub.tencentmaas.com/v1"
     :env ("TENCENT_TOKENHUB_API_KEY")
     :models ("hy3" "hy3-preview")
     :npm "@ai-sdk/openai-compatible")
    (:id "the-grid-ai"
     :name "The Grid AI"
     :api "https://api.thegrid.ai/v1"
     :env ("THEGRIDAI_API_KEY")
     :models ("agent-prime" "agent-max" "text-standard" "code-prime" "text-prime" "code-max" "agent-standard" "text-max" "code-standard")
     :npm "@ai-sdk/openai-compatible")
    (:id "tinfoil"
     :name "Tinfoil"
     :api "https://inference.tinfoil.sh/v1"
     :env ("TINFOIL_API_KEY")
     :models ("kimi-k2-6" "llama3-3-70b" "gpt-oss-safeguard-120b" "nomic-embed-text" "gpt-oss-120b" "glm-5-2" "gemma4-31b")
     :npm "@ai-sdk/openai-compatible")
    (:id "togetherai"
     :name "Together AI"
     :api "https://api.together.xyz/v1"
     :env ("TOGETHER_API_KEY")
     :models ("meta-llama/Llama-3.3-70B-Instruct-Turbo" "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo" "LiquidAI/LFM2-24B-A2B" "meta-llama/Meta-Llama-3-8B-Instruct-Lite" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "google/gemma-3n-E4B-it" "Qwen/Qwen3.7-Max" "Qwen/Qwen3.6-Plus" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3-Coder-Next-FP8" "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8" "Qwen/Qwen3-235B-A22B-Instruct-2507-tput")
     :npm "@ai-sdk/togetherai")
    (:id "trustedrouter"
     :name "TrustedRouter"
     :api "https://api.trustedrouter.com/v1"
     :env ("TRUSTEDROUTER_API_KEY")
     :models ("zdr" "e2e" "synth-code" "fast" "synth" "auto" "cheap")
     :npm "@ai-sdk/openai-compatible")
    (:id "umans-ai"
     :name "Umans AI"
     :api "https://api.code.umans.ai/v1"
     :env ("UMANS_AI_API_KEY")
     :models ("umans-kimi-k2.7" "umans-glm-5.1" "umans-coder" "umans-flash" "umans-glm-5.2")
     :npm "@ai-sdk/openai-compatible")
    (:id "umans-ai-coding-plan"
     :name "Umans AI Coding Plan"
     :api "https://api.code.umans.ai/v1"
     :env ("UMANS_AI_CODING_PLAN_API_KEY")
     :models ("umans-kimi-k2.7" "umans-glm-5.1" "umans-coder" "umans-flash" "umans-glm-5.2" "umans-qwen3.6-35b-a3b")
     :npm "@ai-sdk/openai-compatible")
    (:id "unorouter"
     :name "UnoRouter"
     :api "https://api.unorouter.com/v1"
     :env ("UNOROUTER_API_KEY")
     :models ("gpt-5.5:free" "deepseek-v4-flash" "gpt-5.4:free" "glm-4.5-flash:free" "minimax-m2.7:free" "step-3.7-flash:free" "claude-haiku-4-5-20251001" "qwen3.5-397b-a17b:free" "nemotron-3-ultra-550b-a55b:free" "gemini-3.5-flash" "deepseek-v4-pro" "deepseek-v4-flash:free" "claude-sonnet-5" "glm-5.2" "claude-opus-4-8")
     :npm "@ai-sdk/openai-compatible")
    (:id "upstage"
     :name "Upstage"
     :api "https://api.upstage.ai/v1/solar"
     :env ("UPSTAGE_API_KEY")
     :models ("solar-pro2" "solar-pro3" "solar-mini")
     :npm "@ai-sdk/openai-compatible")
    (:id "v0"
     :name "v0"
     :api "https://api.v0.dev/v1"
     :env ("V0_API_KEY")
     :models ("v0-1.0-md" "v0-1.5-lg" "v0-1.5-md")
     :npm "@ai-sdk/vercel")
    (:id "venice"
     :name "Venice AI"
     :api "https://api.venice.ai/api/v1"
     :env ("VENICE_API_KEY")
     :models ("llama-3.3-70b" "deepseek-r1-llama-70b" "z-ai-glm-5-turbo" "grok-4-20-multi-agent" "deepseek-v4-flash" "google-gemma-4-31b-it" "kimi-k2-6" "openai-gpt-56-terra-pro" "qwen3-235b-a22b-instruct-2507" "openai-gpt-56-sol-pro" "nvidia-nemotron-cascade-2-30b-a3b" "claude-opus-4-7-fast" "openai-gpt-55-pro" "qwen3-5-397b-a17b" "claude-opus-4-5")
     :npm "venice-ai-sdk-provider")
    (:id "vercel"
     :name "Vercel AI Gateway"
     :api "https://api.vercel.com/v1/ai"
     :env ("AI_GATEWAY_API_KEY")
     :models ("xai/grok-imagine-video-1.5" "xai/grok-4.1-fast-reasoning" "xai/grok-4.20-non-reasoning-beta" "xai/grok-4.3" "xai/grok-tts" "xai/grok-4.1-fast-non-reasoning" "xai/grok-voice-think-fast-1.0" "xai/grok-imagine-video" "xai/grok-4.20-multi-agent-beta" "xai/grok-stt" "xai/grok-4.5" "xai/grok-4.20-reasoning" "xai/grok-4.20-reasoning-beta" "xai/grok-imagine-video-1.5-preview" "xai/grok-4.20-non-reasoning")
     :npm "@ai-sdk/gateway")
    (:id "vivgrid"
     :name "Vivgrid"
     :api "https://api.vivgrid.com/v1"
     :env ("VIVGRID_API_KEY")
     :models ("deepseek-v4-pro" "gpt-5.4-nano" "glm-5.2" "gpt-5.1-codex" "gpt-5.1-codex-max" "gpt-5.3-codex" "gpt-5.6-luna" "gpt-5.6-terra" "gpt-5.4" "gpt-5.4-mini" "gemini-3.1-pro-preview" "gpt-5-mini" "gpt-5.6-sol" "deepseek-v3.2" "gemini-3.1-flash-lite-preview")
     :npm "@ai-sdk/openai")
    (:id "vultr"
     :name "Vultr"
     :api "https://api.vultrinference.com/v1"
     :env ("VULTR_API_KEY")
     :models ("moonshotai/Kimi-K2.6" "Qwen/Qwen3.6-27B" "Qwen/Qwen3.5-397B-A17B" "XiaomiMiMo/MiMo-V2.5-Pro" "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16" "nvidia/DeepSeek-V3.2-NVFP4" "nvidia/Nemotron-Cascade-2-30B-A3B" "zai-org/GLM-5.2-FP8" "deepseek-ai/DeepSeek-V4-Flash" "MiniMaxAI/MiniMax-M2.7")
     :npm "@ai-sdk/openai-compatible")
    (:id "wafer.ai"
     :name "Wafer"
     :api "https://pass.wafer.ai/v1"
     :env ("WAFER_API_KEY")
     :models ("glm5.2-fast" "Kimi-K2.6" "MiniMax-M3" "GLM-5.2" "GLM-5.1")
     :npm "@ai-sdk/openai-compatible")
    (:id "wandb"
     :name "Weights & Biases"
     :api "https://api.inference.wandb.ai/v1"
     :env ("WANDB_API_KEY")
     :models ("ibm-granite/granite-4.1-8b" "meta-llama/Llama-3.3-70B-Instruct" "meta-llama/Llama-3.1-70B-Instruct" "meta-llama/Llama-3.1-8B-Instruct" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "microsoft/Phi-4-mini-instruct" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.6-27B" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct" "Qwen/Qwen3.5-27B" "Qwen/Qwen3-30B-A3B-Instruct-2507")
     :npm "@ai-sdk/openai-compatible")
    (:id "xai"
     :name "xAI"
     :api "https://api.x.ai/v1"
     :env ("XAI_API_KEY")
     :models ("grok-2-latest" "grok-2-vision-latest" "grok-beta" "grok-4.20-multi-agent-0309" "grok-4.20-0309-non-reasoning" "grok-4.3" "grok-imagine-image-quality" "grok-imagine-video" "grok-4.5" "grok-4.20-0309-reasoning" "grok-imagine-image" "grok-build-0.1")
     :npm "@ai-sdk/xai")
    (:id "xiaomi"
     :name "Xiaomi"
     :api "https://api.xiaomimimo.com/v1"
     :env ("XIAOMI_API_KEY")
     :models ("mimo-v2.5-pro-ultraspeed" "mimo-v2.5" "mimo-v2-omni" "mimo-v2-flash" "mimo-v2-pro" "mimo-v2.5-pro")
     :npm "@ai-sdk/openai-compatible")
    (:id "xiaomi-token-plan-ams"
     :name "Xiaomi Token Plan (Europe)"
     :api "https://token-plan-ams.xiaomimimo.com/v1"
     :env ("XIAOMI_API_KEY")
     :models ("mimo-v2.5-tts" "mimo-v2.5-pro" "mimo-v2-pro" "mimo-v2-tts" "mimo-v2.5" "mimo-v2.5-tts-voicedesign" "mimo-v2.5-tts-voiceclone")
     :npm "@ai-sdk/openai-compatible")
    (:id "xiaomi-token-plan-cn"
     :name "Xiaomi Token Plan (China)"
     :api "https://token-plan-cn.xiaomimimo.com/v1"
     :env ("XIAOMI_API_KEY")
     :models ("mimo-v2.5-tts-voiceclone" "mimo-v2.5-tts-voicedesign" "mimo-v2.5" "mimo-v2-tts" "mimo-v2-pro" "mimo-v2.5-pro" "mimo-v2.5-tts")
     :npm "@ai-sdk/openai-compatible")
    (:id "xiaomi-token-plan-sgp"
     :name "Xiaomi Token Plan (Singapore)"
     :api "https://token-plan-sgp.xiaomimimo.com/v1"
     :env ("XIAOMI_API_KEY")
     :models ("mimo-v2.5-tts" "mimo-v2.5-pro" "mimo-v2-pro" "mimo-v2-tts" "mimo-v2.5" "mimo-v2.5-tts-voicedesign" "mimo-v2.5-tts-voiceclone")
     :npm "@ai-sdk/openai-compatible")
    (:id "xpersona"
     :name "Xpersona"
     :api "https://www.xpersona.co/v1"
     :env ("XPERSONA_API_KEY")
     :models ("xpersona-gpt-5.5" "xpersona-frieren-coder" "claude-fable-5")
     :npm "@ai-sdk/openai-compatible")
    (:id "zai"
     :name "Z.AI"
     :api "https://api.z.ai/api/paas/v4"
     :env ("ZHIPU_API_KEY")
     :models ("glm-4.7" "glm-4.5v" "glm-4.5" "glm-4.7-flashx" "glm-5.1" "glm-4.6" "glm-5.2" "glm-4.6v" "glm-5v-turbo" "glm-4.5-air" "glm-4.7-flash" "glm-4.5-flash" "glm-5" "glm-5-turbo")
     :npm "@ai-sdk/openai-compatible")
    (:id "zai-coding-plan"
     :name "Z.AI Coding Plan"
     :api "https://api.z.ai/api/coding/paas/v4"
     :env ("ZHIPU_API_KEY")
     :models ("glm-4.7" "glm-5.1" "glm-5.2" "glm-5v-turbo" "glm-4.5-air" "glm-5-turbo")
     :npm "@ai-sdk/openai-compatible")
    (:id "zeldoc"
     :name "Zeldoc"
     :api "https://api.zeldoc.ai/v1"
     :env ("ZELDOC_API_KEY")
     :models ("z-code")
     :npm "@ai-sdk/openai-compatible")
    (:id "zenifra"
     :name "Zenifra"
     :api "https://ai.zenifra.com/v1"
     :env ("ZENIFRA_AI_KEY")
     :models ("alibaba/qwen3.6-35b-a3b")
     :npm "@ai-sdk/openai-compatible")
    (:id "zenmux"
     :name "ZenMux"
     :api "https://zenmux.ai/api/v1"
     :env ("ZENMUX_API_KEY")
     :models ("inclusionai/ling-1t" "inclusionai/ring-2.6-1t" "inclusionai/ring-1t" "moonshotai/kimi-k2.7-code-free" "moonshotai/kimi-k2-thinking-turbo" "moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2-0905" "baidu/ernie-5.0-thinking-preview" "google/gemini-3.1-flash-lite" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash")
     :npm "@ai-sdk/openai-compatible")
    (:id "zhipuai"
     :name "Zhipu AI"
     :api "https://open.bigmodel.cn/api/paas/v4"
     :env ("ZHIPU_API_KEY")
     :models ("glm-5.1" "glm-5.2" "glm-5v-turbo" "glm-5" "glm-4.5-flash" "glm-4.7-flash" "glm-4.5-air" "glm-4.6v" "glm-4.6" "glm-4.7-flashx" "glm-4.5" "glm-4.5v" "glm-4.7")
     :npm "@ai-sdk/openai-compatible")
    (:id "zhipuai-coding-plan"
     :name "Zhipu AI Coding Plan"
     :api "https://open.bigmodel.cn/api/coding/paas/v4"
     :env ("ZHIPU_API_KEY")
     :models ("glm-5.1" "glm-5v-turbo" "glm-5-turbo" "glm-4.5-air" "glm-4.6v" "glm-5.2" "glm-4.7")
     :npm "@ai-sdk/openai-compatible")
   )
  "Built-in metadata for all supported LLM providers.")

;; Populate the registry table:
(dolist (item kargu-providers-builtin-catalog)
  (apply #'kargu-register-provider item))

(provide 'kargu/providers/catalog)

;;; catalog.el ends here
