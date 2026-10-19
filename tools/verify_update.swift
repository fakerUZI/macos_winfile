import CryptoKit
import Foundation

// Public-key-only validation: never needs access to the release signing private key.
do {
    let args = CommandLine.arguments
    guard args.count == 4, let key = Data(base64Encoded: args[1]),
          let signature = Data(base64Encoded: args[3]) else {
        throw NSError(domain: "WinFile.UpdateSignature", code: 1)
    }
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: payload) else {
        throw NSError(domain: "WinFile.UpdateSignature", code: 2)
    }
} catch {
    fputs("Update signature verification failed: \(error)\n", stderr)
    exit(1)
}
