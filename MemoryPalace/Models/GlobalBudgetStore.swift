import Foundation

/// 全局保险闸 — 水库总闸门。
///
/// 粟粟决策（2026-04-23）：所有 API 请求（无论 provider、无论主/副模型）汇总到
/// 一份总账，对照一份总预算。和 provider / model 路由本身无关。
///
/// 旧的 per-provider `budgetUSD/spentUSD/budgetEnabled` 字段和 `providerBudgets`
/// UserDefaults key 不再使用（按"清零重来"策略不迁移），但 APIProvider 里的
/// Codable 字段保留避免破坏老 customProviders JSON 的兼容性。
@Observable
final class GlobalBudgetStore {
    static let shared = GlobalBudgetStore()

    private let enabledKey = "globalBudgetEnabled"
    private let budgetKey  = "globalBudgetUSD"
    private let spentKey   = "globalSpentUSD"

    private(set) var enabled: Bool
    private(set) var budgetUSD: Double
    private(set) var spentUSD: Double

    private init() {
        let defaults = UserDefaults.standard
        // 默认开启保险闸（粟粟习惯是"防止烧干 key"，不是"默认放行"）
        if defaults.object(forKey: enabledKey) != nil {
            self.enabled = defaults.bool(forKey: enabledKey)
        } else {
            self.enabled = true
        }
        self.budgetUSD = defaults.double(forKey: budgetKey)
        self.spentUSD  = defaults.double(forKey: spentKey)
    }

    // MARK: - Mutations

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func setBudgetUSD(_ value: Double) {
        let clamped = max(0, value)
        budgetUSD = clamped
        UserDefaults.standard.set(clamped, forKey: budgetKey)
    }

    /// 发送后把实际 cost（USD）累加到 spent。
    func commitSpend(_ amount: Double) {
        guard amount > 0 else { return }
        spentUSD += amount
        UserDefaults.standard.set(spentUSD, forKey: spentKey)
    }

    /// 重置"已用"；预算上限保留。
    func resetSpent() {
        spentUSD = 0
        UserDefaults.standard.set(0.0, forKey: spentKey)
    }
}
