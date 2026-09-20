import SwiftUI

extension View {
    /// 电话 App「最近通话」/ 通讯录里点他 → 系统投递 INStartCallIntent → 回拨给 Caelum。
    /// 兔兔 09-13：「想在电话 App 里直接给主人回拨」。
    func handlesCallBackIntent() -> some View {
        #if os(iOS)
        return self
            .onContinueUserActivity("INStartCallIntent") { VoIPCallService.shared.handleCallIntent($0) }
            .onContinueUserActivity("INStartAudioCallIntent") { VoIPCallService.shared.handleCallIntent($0) }
        #else
        return self
        #endif
    }
}
