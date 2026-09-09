import NamecardCore
import SwiftUI

// Isolate NFC observations so ACK/progress updates do not rebuild the editor
// and every Library image in MainView.
struct NFCSettingsView: View {
    @Bindable var model: AppModel
    @State private var pattern = 1
    private let patterns = ["チェック柄", "NFC OK", "黒", "白", "長辺方向縞", "短辺方向縞", "グリッド", "斜線", "ターゲット", "TEST 10"]

    var body: some View {
        @Bindable var guide = model.nfc.hapticGuide
        Form {
            Section("書き込み") {
                Toggle("書き換え前のクリーニング", isOn: $model.cleanBeforeWrite)
                Text("白黒画像の書き込み前に白→黒→白で清掃します。起動時はONです。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(HardwareValidation.explanation).font(.footnote)
                Text("4階調のNFC書き込みは利用できません。4階調BINの保存・入出力は可能です。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("振動による位置案内（試作）") {
                Toggle("振動で位置を案内", isOn: $guide.enabled)
                    .disabled(model.nfc.isBusy || !model.nfc.hapticGuide.supported)
                    .accessibilityIdentifier("settings.placementHaptics")
                Text("書き込み中、電源と応答が安定すると短く振動します。はっきりした合図が出たら、その位置を保ってください。表示更新中は振動を止めます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("安定時の振動を試す") { model.nfc.previewPlacementHaptics() }
                    .disabled(model.nfc.isBusy || !model.nfc.hapticGuide.enabled || !model.nfc.hapticGuide.supported)
                    .accessibilityIdentifier("settings.previewHaptics")
                if !model.nfc.hapticGuide.supported {
                    Text("この環境では振動を利用できません。iPhone実機で確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.nfc.recoveryURL != nil {
                Section("未完了のURL設定") {
                    Text("前回の名刺を用意して再開してください。")
                    Button("URL設定を再開") { model.nfc.resumeURL() }.disabled(model.nfc.isBusy)
                }
            }
            Section("本体の確認") {
                Button("STATUS確認") { model.nfc.readStatus() }.disabled(model.nfc.isBusy)
                    .accessibilityIdentifier("settings.status")
                Picker("内蔵パターン", selection: $pattern) {
                    ForEach(1...10, id: \.self) { id in Text("\(id). \(patterns[id - 1])").tag(id) }
                }
                Button("選択パターンを書込") { model.nfc.writePattern(UInt8(pattern)) }
                    .disabled(model.nfc.isBusy || !HardwareValidation.allowsDisplayWrites)
                Button("10パターン連続試験") { model.nfc.writeSequence() }
                    .disabled(model.nfc.isBusy || !HardwareValidation.allowsDisplayWrites)
                if model.nfc.pending { Button("前回の操作を再開") { model.nfc.resume() }.disabled(model.nfc.isBusy) }
            }
            Section("通信ログ") {
                HStack {
                    Button("コピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.nfc.log }
                    Spacer()
                    Button("消去") { model.nfc.clearLog() }
                }
                // Do not re-layout the whole growing log during RF transfers.
                // Copy always reads the complete live log, including while busy.
                if model.nfc.isBusy {
                    Text("通信中のログは記録しています。終了後に表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.nfc.log.isEmpty ? "通信ログはまだありません。" : model.nfc.log)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("プライバシー") {
                Text("画像・URL・ログは端末内で処理します。アカウント登録、広告、解析SDK、外部へのデータ送信はありません。LibraryとURL復旧記録は端末のバックアップ対象になる場合があります。")
                    .font(.footnote)
                Link("プライバシーポリシー全文", destination: URL(string: "https://github.com/soumame/namecard/blob/main/client/ios/docs/PRIVACY.md")!)
                    .accessibilityIdentifier("settings.privacyPolicy")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
    }

}

struct NFCProgressView: View {
    @Bindable var nfc: NFCService
    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 24) {
                    if HardwareValidation.isBetaBuild {
                        Text("ベータ試験版").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: nfc.succeeded ? "checkmark.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 64)).foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    Text(nfc.message).multilineTextAlignment(.center).font(.headline)
                    ProgressView(value: nfc.fraction)
                    Text("iPhoneの上端と名刺のアンテナを重ね、処理が終わるまで固定してください。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let vdd = nfc.lastVDD {
                        VStack(spacing: 4) {
                            Text("最後の応答: 電源 \(vdd)mV・\(nfc.responseMS)ms")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if nfc.hapticGuide.enabled {
                        Label(nfc.hapticGuide.explanation, systemImage: "waveform")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("nfc.placementHint")
                    }
                    if !nfc.isBusy, nfc.pending, !nfc.succeeded {
                        Button("同じ名刺で再スキャン", systemImage: "arrow.clockwise") { nfc.resume() }
                            .adaptiveGlassButtonStyle(prominent: true)
                    }
                    Spacer()
                }
                .padding(24).padding(.top, 24)
            }
            .navigationTitle("NFC書き込み").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !nfc.isBusy { Button("閉じる") { nfc.showsProgress = false } }
            }
            .interactiveDismissDisabled(nfc.isBusy)
        }
    }
}
