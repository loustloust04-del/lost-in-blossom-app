import Foundation

/// 单个模型的官方参考价（USD per 1M tokens）。
/// 中转站不读这里的价，改通过 provider 级倍率×官方价 近似。
struct ModelPricing: Equatable {
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double

    init(_ input: Double, _ output: Double) {
        self.inputUSDPerMTok = input
        self.outputUSDPerMTok = output
    }
}

enum PricingCatalog {
    /// 前缀/包含模糊匹配。支持 "anthropic/claude-sonnet-4-5" 或 "custom/claude-sonnet-4-5"
    /// 这类中转站写法，剥离 vendor 前缀后找表。
    static func price(for modelId: String) -> ModelPricing {
        let lower = modelId.lowercased()
        // 先尝试精确匹配
        if let exact = table[lower] { return exact }
        // 再尝试去掉 vendor/ 前缀后匹配
        if let slash = lower.firstIndex(of: "/") {
            let stripped = String(lower[lower.index(after: slash)...])
            if let m = table[stripped] { return m }
            // 按前缀匹配表里的键
            for (key, price) in table where stripped.hasPrefix(key) || key.hasPrefix(stripped) {
                return price
            }
        }
        // 最后按 contains 匹配表里键
        for (key, price) in table where lower.contains(key) {
            return price
        }
        return fallback
    }

    /// 公开价格表（USD per 1M tokens）。数值取自各家 2026-04 官方公开价，供保险闸粗估。
    /// 实际扣费按响应的 usage 回填，不依赖这里的绝对精确。
    private static let table: [String: ModelPricing] = [
        // Anthropic
        "claude-opus-4-7":           ModelPricing(15, 75),
        "claude-opus-4-6":           ModelPricing(15, 75),
        "claude-opus-4-0":           ModelPricing(15, 75),
        "claude-opus-4":             ModelPricing(15, 75),
        "claude-sonnet-4-6":         ModelPricing(3, 15),
        "claude-sonnet-4-5":         ModelPricing(3, 15),
        "claude-sonnet-4-0":         ModelPricing(3, 15),
        "claude-sonnet-4":           ModelPricing(3, 15),
        "claude-haiku-4-5":          ModelPricing(0.8, 4),
        "claude-haiku-4":            ModelPricing(0.8, 4),
        "claude-3-7-sonnet":         ModelPricing(3, 15),
        "claude-3-5-haiku":          ModelPricing(0.8, 4),

        // OpenAI
        "gpt-4o":                    ModelPricing(2.5, 10),
        "gpt-4o-mini":               ModelPricing(0.15, 0.6),
        "gpt-4.1":                   ModelPricing(2, 8),
        "gpt-4.1-mini":              ModelPricing(0.4, 1.6),
        "gpt-4.1-nano":              ModelPricing(0.1, 0.4),
        "o3":                        ModelPricing(2, 8),
        "o3-mini":                   ModelPricing(1.1, 4.4),
        "o4-mini":                   ModelPricing(1.1, 4.4),

        // DeepSeek
        "deepseek-chat":             ModelPricing(0.27, 1.1),
        "deepseek-reasoner":         ModelPricing(0.55, 2.19),

        // Google Gemini
        "gemini-2.5-pro":            ModelPricing(1.25, 5),
        "gemini-2.5-flash":          ModelPricing(0.075, 0.3),

        // xAI Grok
        "grok-3":                    ModelPricing(3, 15),
        "grok-3-mini":               ModelPricing(0.3, 0.5),

        // Groq / Llama etc. — 给个保守价
        "llama-3.3-70b-versatile":   ModelPricing(0.59, 0.79),
        "llama-3.1-8b-instant":      ModelPricing(0.05, 0.08),
    ]

    /// 查不到时的兜底价（保守偏贵，防止 runaway 烧钱）
    static let fallback = ModelPricing(3, 15)
}
