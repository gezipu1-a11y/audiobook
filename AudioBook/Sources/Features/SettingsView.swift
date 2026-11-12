import SwiftUI
import UIKit

/// 设置页
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    let onChanged: () -> Void

    @State private var showClearConfirm = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("导入目录") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppPaths.audiobooks.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(copied ? "已复制" : "复制路径") {
                            UIPasteboard.general.string = AppPaths.audiobooks.path
                            copied = true
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }

                Section("说明") {
                    Text("每本书一个文件夹，文件夹名即书名。章节目录内放 mp3，按文件名自然排序。支持 mp3 / m4a / m4b / aac / wav / aiff / flac。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("进度") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("播放进度保存在 Documents/播放进度.json，可用爱思助手拷出备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(AppPaths.progressFile.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)

                    Button("清空全部进度", role: .destructive) {
                        showClearConfirm = true
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(versionText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("清空全部进度？", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) {
                    ProgressStore.shared.clearAll()
                    onChanged()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("音频文件不会被删除，只清除播放位置。")
            }
        }
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
