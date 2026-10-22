import Foundation
import CryptoKit

/// Identity and storage information supplied exclusively by the MTP session.
struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    var model: String
    var state: String  // device / locked / unavailable
    var transportID: String
    var storages: [MTPStorage] = []
    var id: String { serial }
    var displayName: String { model.isEmpty ? serial : model }
    var isReady: Bool { state == "device" }
    var needsFileTransfer: Bool { !isReady }
    var hasTemporaryIdentity: Bool { !isReady && serial == transportID }
    var diagnosticID: String {
        SHA256.hash(data: Data(serial.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    var diagnosticSummary: String {
        "id=\(diagnosticID) usb=\(transportID) state=\(state) storages=\(storages.map { String($0.id) }.joined(separator: ","))"
    }
}
