import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            toolsCard
            discoveryCard
            pairingCard
            logCard
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text("MirrorBridge")
                    .font(.title2.weight(.semibold))
                Text("Android 无线镜像控制台")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 9, height: 9)
                Text(model.state.title)
                    .font(.callout.weight(.medium))
            }
        }
    }

    private var toolsCard: some View {
        GroupBox("运行环境") {
            VStack(alignment: .leading, spacing: 7) {
                toolRow(name: "adb", path: model.adbPath)
                toolRow(name: "scrcpy", path: model.scrcpyPath)
                HStack(spacing: 10) {
                    Text(model.toolStatus.message)
                        .font(.caption)
                        .foregroundStyle(model.toolStatus == .ready ? Color.secondary : Color.red)
                    Spacer()
                    Button {
                        model.refreshNow()
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
                Text("首版使用外部 scrcpy 镜像窗口；发布版将把经过验证的工具放进 App Bundle。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var discoveryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("无线调试设备")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.refreshNow()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }

                if model.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("没有发现已配对的设备")
                            .font(.callout)
                        Text("请在手机上打开 Wireless debugging，并确认手机和 Mac 在同一 Wi-Fi。首次使用请先完成下面的配对。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(model.devices) { device in
                        deviceRow(device)
                    }
                }

                HStack {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.connectAndMirror()
                    } label: {
                        Label("连接并镜像", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canMirror)
                    if model.state == .stopUnconfirmed {
                        Button {
                            model.retryStopConfirmation()
                        } label: {
                            Label("检查退出状态", systemImage: "arrow.clockwise")
                        }
                        .disabled(!model.isMirroring)
                    } else {
                        Button {
                            model.stopMirror()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .disabled(!model.isMirroring)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var pairingCard: some View {
        GroupBox("首次配对") {
            VStack(alignment: .leading, spacing: 10) {
                Text("在手机的 Wireless debugging → Pair device with pairing code 页面查看地址和配对码。配对成功后，不需要每次重复配对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("配对地址，例如 192.168.1.20:37001", text: $model.pairingAddress)
                    SecureField("配对码", text: $model.pairingCode)
                        .frame(width: 150)
                    Button("配对") {
                        model.pair()
                    }
                    .disabled(!model.canPair)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var logCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("诊断日志")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.clearLogs()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                }

                ScrollView {
                    Text(model.logText.isEmpty ? "暂无日志" : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 170)
            }
            .padding(.vertical, 4)
        }
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        Button {
            model.selectedEndpoint = device.endpoint
        } label: {
            HStack(spacing: 10) {
                if model.selectedEndpoint == device.endpoint {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .foregroundStyle(.primary)
                    Text("ADB Wireless debugging")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolRow(name: String, path: String?) -> some View {
        HStack {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? .red : .green)
            Text(name)
                .font(.callout.weight(.medium))
            Text(path ?? "未找到")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .checking, .waiting: return .orange
        case .discovered, .connected: return .blue
        case .pairing, .connecting: return .orange
        case .mirroring: return .green
        case .stopping: return .orange
        case .stopUnconfirmed: return .red
        case .error: return .red
        }
    }
}
