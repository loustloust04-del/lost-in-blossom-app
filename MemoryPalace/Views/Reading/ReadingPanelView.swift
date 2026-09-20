import SwiftUI

/// page2 tool「读书」——书架独立成一等公民（粟粟 2026-07-06 点的，
/// 之前寄居在文件库工具的顶部 toggle 里）。
/// 视觉学 VocabPanelView 同款卡片观感：22pt 圆角 + 上下留白。
struct ReadingPanelView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        BookshelfView(profileId: profileId)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.mainBg)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 10)
            .padding(.bottom, 10)
    }
}
