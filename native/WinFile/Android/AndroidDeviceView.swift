// 安卓设备页：显示该设备的存储位置
import AppKit
import SwiftUI

struct AndroidDeviceView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject private var registry = AndroidDeviceRegistry.shared
    @ObservedObject var model: BrowserModel
    let serial: String

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 14)]

    private var storages: [AndroidDeviceRegistry.AndroidStorage] { registry.roots(for: serial) }
    private var device: AndroidDevice? { registry.device(serial: serial) }
    private var isLoading: Bool { device?.isReady == true && registry.isRefreshing && storages.isEmpty }
    private var errorText: String? {
        guard device?.isReady == true else { return BrowserModel.androidConnectionMessage(device) }
        return storages.isEmpty && !isLoading ? L("android.storage.unavailable", "无法读取存储位置，请解锁手机并选择 USB「文件传输」。") : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            await registry.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "candybarphone")
                    .foregroundStyle(Color.accentColor)
                Text(device?.displayName ?? L("view.androidDevice", "安卓设备"))
                    .font(.title3).fontWeight(.semibold)
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let device {
                Text(L("android.mtp.detail", "序列号 %@ · MTP", device.serial))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("android.storage.loading", "正在读取设备存储…")).foregroundStyle(.secondary)
            }
        } else if let errorText {
            VStack(alignment: .leading, spacing: 8) {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button(L("android.retry", "重试")) {
                    Task { await registry.refresh() }
                }
            }
        } else if storages.isEmpty {
            Text(L("android.storage.empty", "未发现可访问的存储位置。"))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("android.storage.title", "存储位置"))
                    .font(.headline)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(storages) { storage in
                        StorageCard(storage: storage) {
                            model.selectFolder(AndroidURL.make(serial: serial, path: storage.path))
                        }
                    }
                }
            }
        }
    }
}

/// 存储位置卡片
struct StorageCard: View {
    @ObservedObject private var localization = Localization.shared
    let storage: AndroidDeviceRegistry.AndroidStorage
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: storage.isRemovable ? "sdcard.fill" : "internaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(storage.label).fontWeight(.medium)
                    Text(
                        L(
                            "android.mtp.space", "可用 %@ / 共 %@",
                            ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.free), countStyle: .file),
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: storage.capacity), countStyle: .file))
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        Color(
                            nsColor: hovering
                                ? .selectedContentBackgroundColor.withAlphaComponent(0.12)
                                : .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 传输进度条（上传/下载大文件时显示，避免界面看起来卡死）
struct AndroidTransferBanner: View {
    @ObservedObject private var localization = Localization.shared
    let progress: AndroidTransferProgress
    var cancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.direction.title).fontWeight(.medium)
                Text(progress.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(progress.percentText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let cancel { Button(L("button.cancel", "取消"), action: cancel) }
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .padding(12)
    }
}
