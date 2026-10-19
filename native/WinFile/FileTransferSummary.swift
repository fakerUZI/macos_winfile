import SwiftUI

struct FileTransferSummary: View {
    let outcome: FileTransferOutcome
    let dismiss: () -> Void
    var openResult: () -> Void = {}
    var retry: () -> Void = {}
    var body: some View {
        HStack(alignment: .top) {
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(outcome.completed, id: \.path) { Text($0.path).textSelection(.enabled) }
                        ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, error in Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("operation.finished", "已完成 %d 项，失败 %d 项%@", outcome.completed.count,
                           outcome.failures.count, outcome.cancelled ? L("operation.cancelledSuffix", "（已取消）") : "")).font(.caption)
                    HStack {
                        if outcome.destination != nil { Button(L("operation.openResult", "打开结果目录"), action: openResult) }
                        if !outcome.retryURLs.isEmpty { Button(L("operation.retry", "重试未完成项（%d）", outcome.retryURLs.count), action: retry) }
                    }.controlSize(.small)
                }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help(L("button.close", "关闭"))
        }.padding(8).background(.regularMaterial)
    }
}
