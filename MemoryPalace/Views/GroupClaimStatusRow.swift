import SwiftUI
import SwiftData

/// 群聊「没说上话」状态行（V6 刀2.5，PLAN-GROUPCHAT-V6 病灶2 的可见化）。
///
/// 以前某个角色的模型坏了/超时，群里要么冒出一条假装是他说的 ⚠️ 泡，要么**彻底静默消失**
/// ——兔兔只会觉得「咦怎么没人理我」。现在 SpeakClaim 记着「谁欠一句话、为什么没说上」，
/// 这一行把它显示出来，并给一个重试入口。只显示**最近一轮**的失败，不堆历史。
struct GroupClaimStatusRow: View {
    let conversationId: String
    /// 点重试：把这个角色再叫一次（复用 groupRequestReply）
    let onRetry: (String) -> Void

    @Query private var claims: [SpeakClaim]

    init(conversationId: String, onRetry: @escaping (String) -> Void) {
        self.conversationId = conversationId
        self.onRetry = onRetry
        let cid = conversationId
        _claims = Query(
            filter: #Predicate<SpeakClaim> { $0.conversationId == cid && $0.state == "failed" },
            sort: [SortDescriptor(\SpeakClaim.createdAt, order: .reverse)]
        )
    }

    var body: some View {
        // 只显示 3 分钟内的失败——过期的属于历史，不打扰
        let fresh = claims.filter { $0.createdAt > Date().addingTimeInterval(-180) }
        if !fresh.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fresh.prefix(3)) { claim in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 11))
                        Text("\(claim.participantName) 没说上话")
                            .font(.system(size: 12))
                        if let note = claim.failureNote, !note.isEmpty {
                            Text("（\(note)）")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            onRetry(claim.participantId)
                        } label: {
                            Text("再试一次").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.branchIndicator)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.textMuted.opacity(0.08))
            )
        }
    }
}
