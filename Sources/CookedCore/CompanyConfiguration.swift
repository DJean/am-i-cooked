// One entry per model author; price sources only select where to look up exact-match prices.
// IDs correspond to the namespace in https://models.dev/models.json.
extension ModelCompany {
    public static func configured() -> [Self] {
        [
            Self(id: "anthropic", name: "Anthropic", priceSources: ["anthropic"]),
            Self(id: "openai", name: "OpenAI", priceSources: ["openai"]),
            Self(id: "google", name: "Google", priceSources: ["google"]),
            Self(id: "meta", name: "Meta", priceSources: ["meta", "llama"]),
            Self(id: "xai", name: "SpaceX AI", priceSources: ["xai"]),
            Self(id: "deepseek", name: "DeepSeek", priceSources: ["deepseek"]),
            Self(id: "mistral", name: "Mistral", priceSources: ["mistral"]),
            Self(id: "moonshotai", name: "Moonshot AI", priceSources: ["moonshotai"]),
            Self(id: "zhipuai", name: "Z.ai", priceSources: ["zai", "zhipuai"]),
            Self(id: "alibaba", name: "Qwen", priceSources: ["alibaba"]),
            Self(id: "nvidia", name: "NVIDIA", priceSources: ["nvidia"])
        ]
    }
}
