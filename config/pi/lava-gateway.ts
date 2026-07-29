// pi extension: register the local LiteLLM gateway as a provider.
// Installed by 40-pi.sh into ~/.pi/agent/extensions/ (pi's global discovery
// path; TypeScript loads natively via jiti). Model list mirrors the routes
// in config/litellm.yaml that have live provider keys — extend it as more
// keys land in /etc/lavasec/lavasec.env. Costs are display-only estimates
// in $/MTok; correctness of billing lives with the providers.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("lava-gateway", {
    baseUrl: "http://127.0.0.1:4000/v1",
    apiKey: "$LITELLM_MASTER_KEY",
    api: "openai-completions",
    models: [
      {
        id: "deepseek/deepseek-chat",
        name: "DeepSeek Chat (lava-gateway)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0.27, output: 1.1, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 8192,
      },
      {
        id: "deepseek/deepseek-reasoner",
        name: "DeepSeek Reasoner (lava-gateway)",
        reasoning: true,
        input: ["text"],
        cost: { input: 0.55, output: 2.19, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 65536,
      },
      {
        id: "openrouter/openai/gpt-4o-mini",
        name: "GPT-4o mini via OpenRouter (lava-gateway)",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0.15, output: 0.6, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 16384,
      },
      {
        id: "anthropic/claude-haiku-4-5",
        name: "Claude Haiku 4.5 (lava-gateway)",
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 },
        contextWindow: 200000,
        maxTokens: 8192,
      },
      {
        id: "openai/gpt-4o-mini",
        name: "GPT-4o mini (lava-gateway)",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0.15, output: 0.6, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 16384,
      },
      {
        id: "opencode/gpt-5.5",
        name: "GPT-5.5 via OpenCode Zen (lava-gateway)",
        reasoning: true,
        input: ["text"],
        // OpenCode Zen endpoint. $/MTok = Zen credit rates, base tier
        // (≤272K input); Go-subscription usage is flat-rate but pi
        // displays the credit rates
        cost: { input: 5, output: 30, cacheRead: 0.5, cacheWrite: 0 },
        contextWindow: 272000,
        maxTokens: 32768,
      },
      {
        id: "neuralwatt/qwen3.6-35b",
        name: "Qwen 3.6 35B via Neuralwatt (lava-gateway)",
        reasoning: true,
        input: ["text"],
        // Neuralwatt bills per kWh, not per token — no $/MTok figure exists
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131072,
        maxTokens: 32768,
      },
    ],
  });
}
