import SwiftUI

struct FileTransferBanner: View {
    let progress: FileTransferProgress
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let total = progress.totalBytes {
                ProgressView(value: Double(min(progress.completedBytes, total)), total: Double(max(total, 1))).frame(width: 110)
            } else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("operation.progress", "已完成 %d / %d 项：%@", progress.completed, progress.total, progress.currentName))
                    .font(.caption).lineLimit(1)
                Text(progress.totalBytes.map { L("operation.bytes", "%@ / %@", FileItem.formatSize(progress.completedBytes), FileItem.formatSize($0)) }
                     ?? L("operation.calculating", "正在统计文件大小…"))
                    .font(.caption).monospacedDigit()
                Text(L("operation.cancelStreaming", "复制可在传输中取消；移动在当前项目完成后停止，已完成项目会保留。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("button.cancel", "取消"), action: cancel)
        }.padding(10).background(.regularMaterial)
    }
}
