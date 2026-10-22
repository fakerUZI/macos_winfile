// 安卓传输进度
import Foundation

/// 传输方向
enum AndroidTransferDirection {
    case upload  // 本机 → 设备
    case open  // 下载本机副本后打开或预览
    case stream  // 内存中准备视频播放
    case download  // 设备 → 本机

    var title: String {
        switch self {
        case .upload: return L("android.transfer.uploading", "正在上传到设备")
        case .open: return L("android.open.downloading", "正在下载以打开…")
        case .stream: return L("android.stream.preparing", "正在准备 MTP 流式播放…")
        case .download: return L("android.transfer.downloading", "正在下载到本机")
        }
    }
}

/// 传输进度（供界面显示，避免大文件传输时看起来像卡死）
struct AndroidTransferProgress: Equatable {
    let name: String
    let direction: AndroidTransferDirection
    /// 0…1；nil 表示设备未给出百分比（此时显示不确定进度）
    var fraction: Double?

    var percentText: String {
        guard let fraction else {
            return direction == .stream
                ? L("android.stream.preparing", "正在准备 MTP 流式播放…") : L("android.transfer.working", "传输中…")
        }
        return String(format: "%.0f%%", fraction * 100)
    }
}

extension AndroidEntry {
    /// 转成 FileItem 以便复用现有列表/排序/选择逻辑
    func asFileItem() -> FileItem {
        FileItem(androidEntry: self)
    }
}
