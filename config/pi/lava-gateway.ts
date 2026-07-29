// pi extension: register the local LiteLLM gateway as a provider.
// Installed by 40-pi.sh into ~/.pi/agent/extensions/ (TS loads via jiti).
//
// The model list is sourced DYNAMICALLY from the gateway's /model/info —
// LiteLLM maintains that catalog (context windows, per-token costs,
// modality) upstream, so new provider models appear here without edits.
// If the gateway is unreachable at load time, a small static fallback
// keeps pi usable.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const GATEWAY = "http://127.0.0.1:4000";

interface GatewayModelInfo {
  model_name?: string;
  model_info?: {
    mode?: string;
    max_input_tokens?: number;
    max_output_tokens?: number;
    input_cost_per_token?: number;
    output_cost_per_token?: number;
    cache_read_input_token_cost?: number;
    cache_creation_input_token_cost?: number;
    supports_vision?: boolean;
    supports_reasoning?: boolean;
  };
}

const FALLBACK = [
  { id: "deepseek/deepseek-chat", name: "DeepSeek Chat", reasoning: false, vision: false, inCost: 0.27, outCost: 1.1, ctx: 128000, maxOut: 8192 },
  { id: "deepseek/deepseek-reasoner", name: "DeepSeek Reasoner", reasoning: true, vision: false, inCost: 0.55, outCost: 2.19, ctx: 128000, maxOut: 65536 },
  { id: "openrouter/openai/gpt-4o-mini", name: "GPT-4o mini via OpenRouter", reasoning: false, vision: true, inCost: 0.15, outCost: 0.6, ctx: 128000, maxOut: 16384 },
  { id: "anthropic/claude-haiku-4-5", name: "Claude Haiku 4.5", reasoning: true, vision: true, inCost: 1, outCost: 5, cacheRead: 0.1, cacheWrite: 1.25, ctx: 200000, maxOut: 8192 },
  { id: "openai/gpt-4o-mini", name: "GPT-4o mini", reasoning: false, vision: true, inCost: 0.15, outCost: 0.6, ctx: 128000, maxOut: 16384 },
  { id: "opencode/gpt-5.5", name: "GPT-5.5 via OpenCode Zen", reasoning: true, vision: false, inCost: 5, outCost: 30, cacheRead: 0.5, ctx: 272000, maxOut: 32768 },
  { id: "neuralwatt/qwen3.6-35b", name: "Qwen 3.6 35B via Neuralwatt", reasoning: true, vision: false, inCost: 0, outCost: 0, ctx: 131072, maxOut: 32768 },
];

function toPiModel(m: { id: string; name?: string; reasoning: boolean; vision: boolean; inCost: number; outCost: number; ctx: number; maxOut: number; cacheRead?: number; cacheWrite?: number }) {
  return {
    id: m.id,
    name: `${m.name ?? m.id} (lava-gateway)`,
    reasoning: m.reasoning,
    input: m.vision ? (["text", "image"] as const) : (["text"] as const),
    cost: { input: m.inCost, output: m.outCost, cacheRead: m.cacheRead ?? 0, cacheWrite: m.cacheWrite ?? 0 },
    contextWindow: m.ctx,
    maxTokens: m.maxOut,
  };
}

async function fetchGatewayModels() {
  const key = process.env.LITELLM_MASTER_KEY;
  if (!key) return null;
  const res = await fetch(`${GATEWAY}/model/info`, {
    headers: { Authorization: `Bearer ${key}` },
    signal: AbortSignal.timeout(3000),
  });
  if (!res.ok) return null;
  const body = (await res.json()) as { data?: GatewayModelInfo[] };
  const seen = new Set<string>();
  const models = (body.data ?? [])
    .filter((m) => m.model_info?.mode === "chat")
    .filter((m) => m.model_name && !m.model_name.includes("*"))
    .filter((m) => (seen.has(m.model_name!) ? false : (seen.add(m.model_name!), true)))
    .map((m) =>
      toPiModel({
        id: m.model_name!,
        reasoning: m.model_info?.supports_reasoning ?? false,
        vision: m.model_info?.supports_vision ?? false,
        // gateway reports $/token; pi displays $/MTok
        inCost: (m.model_info?.input_cost_per_token ?? 0) * 1e6,
        outCost: (m.model_info?.output_cost_per_token ?? 0) * 1e6,
        cacheRead: (m.model_info?.cache_read_input_token_cost ?? 0) * 1e6,
        cacheWrite: (m.model_info?.cache_creation_input_token_cost ?? 0) * 1e6,
        ctx: m.model_info?.max_input_tokens ?? 128000,
        maxOut: m.model_info?.max_output_tokens ?? 8192,
      }),
    );
  return models.length > 0 ? models : null;
}

export default async function (pi: ExtensionAPI) {
  let models;
  try {
    models = await fetchGatewayModels();
  } catch {
    models = null; // gateway down or unreachable — fall back
  }
  pi.registerProvider("lava-gateway", {
    baseUrl: `${GATEWAY}/v1`,
    apiKey: "$LITELLM_MASTER_KEY",
    api: "openai-completions",
    models: models ?? FALLBACK.map(toPiModel),
  });
}
