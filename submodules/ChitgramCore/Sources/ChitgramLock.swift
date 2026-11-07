import Foundation
import Security
import CommonCrypto

/// Chitgram's chat locks and secret folder (Android `utils/Password` and `ui/secret_chat/SecretPassword`).
///
/// - Chat lock: a locked chat asks for Face ID / Touch ID or a passcode before it opens. A chat is locked either with
///   the one common passcode (cheap to add more chats) or with a passcode of its own.
/// - Secret folder: chats moved into it disappear from the chat list and show only after its own passcode.
///
/// Everything stays on this device, as on Android. Passcodes are kept only as salted PBKDF2-SHA256 hashes. Chats are
/// `EnginePeer.Id.toInt64()` values.
public enum ChitgramLock {
    public struct Credential: Codable, Equatable {
        public var passwordHash: String
        public var salt: String
        /// Android `type`: 0 PIN, 1 password. Kept for the shape of the record.
        public var type: Int
        public var fingerPrint: Bool
        /// How many digits a PIN has, so its screen fits it; nil for a password and for a PIN set before this was kept.
        public var digits: Int?
    }

    private static let commonPasswordKey = "chat_lock_password"
    private static let commonIdsKey = "chat_lock_ids"
    private static let individualKey = "chat_lock_individual"
    private static let secretPasswordKey = "secret_password"
    private static let secretIdsKey = "secret_dialog_ids"
    private static let rounds: UInt32 = 20000

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func notifyChanged() {
        ChitgramPreferences.shared.notifyChanged()
    }

    // MARK: Hashing

    private static func derive(_ passcode: String, salt: Data) -> Data {
        let password = Array(passcode.utf8).map { Int8(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count, saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), self.rounds, &derived, derived.count)
        if status != Int32(kCCSuccess) {
            return Data()
        }
        return Data(derived)
    }

    public static func makeCredential(passcode: String, numeric: Bool) -> Credential {
        var salt = Data(count: 16)
        let count = salt.count
        let status = salt.withUnsafeMutableBytes { bytes -> Int32 in
            guard let base = bytes.baseAddress else {
                return -1
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status != errSecSuccess {
            salt = Data(UUID().uuidString.utf8)
        }
        return Credential(passwordHash: self.derive(passcode, salt: salt).base64EncodedString(), salt: salt.base64EncodedString(), type: numeric ? 0 : 1, fingerPrint: true, digits: numeric ? passcode.count : nil)
    }

    public static func verify(_ passcode: String, credential: Credential) -> Bool {
        guard let salt = Data(base64Encoded: credential.salt), let expected = Data(base64Encoded: credential.passwordHash), !expected.isEmpty else {
            return false
        }
        let actual = self.derive(passcode, salt: salt)
        // Constant-time comparison.
        guard actual.count == expected.count else {
            return false
        }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(actual, expected) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    private static func credential(forKey key: String) -> Credential? {
        guard let data = self.defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    private static func setCredential(_ credential: Credential?, forKey key: String) {
        if let credential, let data = try? JSONEncoder().encode(credential) {
            self.defaults.set(data, forKey: key)
        } else {
            self.defaults.removeObject(forKey: key)
        }
        self.notifyChanged()
    }

    private static func ids(forKey key: String) -> Set<Int64> {
        let values = self.defaults.array(forKey: key) as? [NSNumber] ?? []
        return Set(values.map { $0.int64Value })
    }

    private static func setIds(_ ids: Set<Int64>, forKey key: String) {
        self.defaults.set(ids.sorted().map { NSNumber(value: $0) }, forKey: key)
        self.notifyChanged()
    }

    // MARK: Chat lock

    public static func hasCommonPassword() -> Bool {
        return self.credential(forKey: self.commonPasswordKey) != nil
    }

    public static func setCommonPassword(_ passcode: String, numeric: Bool) {
        self.setCredential(self.makeCredential(passcode: passcode, numeric: numeric), forKey: self.commonPasswordKey)
    }

    public static func checkCommonPassword(_ passcode: String) -> Bool {
        guard let credential = self.credential(forKey: self.commonPasswordKey) else {
            return false
        }
        return self.verify(passcode, credential: credential)
    }

    private static func individual() -> [Int64: Credential] {
        guard let data = self.defaults.data(forKey: self.individualKey), let value = try? JSONDecoder().decode([String: Credential].self, from: data) else {
            return [:]
        }
        var result: [Int64: Credential] = [:]
        for (key, credential) in value {
            if let id = Int64(key) {
                result[id] = credential
            }
        }
        return result
    }

    private static func setIndividual(_ value: [Int64: Credential]) {
        var stored: [String: Credential] = [:]
        for (id, credential) in value {
            stored["\(id)"] = credential
        }
        if let data = try? JSONEncoder().encode(stored) {
            self.defaults.set(data, forKey: self.individualKey)
        }
        self.notifyChanged()
    }

    public static func isLocked(_ chat: Int64) -> Bool {
        return self.ids(forKey: self.commonIdsKey).contains(chat) || self.individual()[chat] != nil
    }

    public static func isIndividual(_ chat: Int64) -> Bool {
        return self.individual()[chat] != nil
    }

    public static func addCommonLock(_ chat: Int64) {
        var ids = self.ids(forKey: self.commonIdsKey)
        ids.insert(chat)
        self.setIds(ids, forKey: self.commonIdsKey)
    }

    public static func addIndividualLock(_ chat: Int64, passcode: String, numeric: Bool) {
        // An individual lock owns the chat: drop a stale common membership.
        var ids = self.ids(forKey: self.commonIdsKey)
        if ids.remove(chat) != nil {
            self.setIds(ids, forKey: self.commonIdsKey)
        }
        var individual = self.individual()
        individual[chat] = self.makeCredential(passcode: passcode, numeric: numeric)
        self.setIndividual(individual)
    }

    public static func unlock(_ chat: Int64) {
        var ids = self.ids(forKey: self.commonIdsKey)
        if ids.remove(chat) != nil {
            self.setIds(ids, forKey: self.commonIdsKey)
        }
        var individual = self.individual()
        if individual.removeValue(forKey: chat) != nil {
            self.setIndividual(individual)
        }
    }

    /// The chat's own passcode when it has one, otherwise the common one.
    public static func check(_ chat: Int64, passcode: String) -> Bool {
        if let credential = self.individual()[chat] {
            return self.verify(passcode, credential: credential)
        }
        return self.checkCommonPassword(passcode)
    }

    /// How to ask for a chat's passcode: its digits, nil for free text.
    public static func passcodeDigits(forChat chat: Int64) -> Int? {
        if let credential = self.individual()[chat] {
            return credential.digits
        }
        return self.commonPasscodeDigits()
    }

    public static func commonPasscodeDigits() -> Int? {
        return self.credential(forKey: self.commonPasswordKey)?.digits
    }

    // MARK: Secret folder

    public static func secretPasscodeDigits() -> Int? {
        return self.credential(forKey: self.secretPasswordKey)?.digits
    }

    /// For the notification extension, whose store is not pointed at the app group.
    public static func secretChats(appGroupName: String) -> Set<Int64> {
        let values = UserDefaults(suiteName: appGroupName)?.array(forKey: self.secretIdsKey) as? [NSNumber] ?? []
        return Set(values.map { $0.int64Value })
    }

    public static func hasSecretPassword() -> Bool {
        return self.credential(forKey: self.secretPasswordKey) != nil
    }

    public static func setSecretPassword(_ passcode: String, numeric: Bool) {
        self.setCredential(self.makeCredential(passcode: passcode, numeric: numeric), forKey: self.secretPasswordKey)
    }

    public static func checkSecretPassword(_ passcode: String) -> Bool {
        guard let credential = self.credential(forKey: self.secretPasswordKey) else {
            return false
        }
        return self.verify(passcode, credential: credential)
    }

    /// Turns the folder off: the passcode goes and every hidden chat is back in the chat list.
    public static func removeSecretPassword() {
        self.defaults.removeObject(forKey: self.secretPasswordKey)
        self.setIds([], forKey: self.secretIdsKey)
    }

    public static func secretChats() -> Set<Int64> {
        return self.ids(forKey: self.secretIdsKey)
    }

    public static func isSecret(_ chat: Int64) -> Bool {
        return self.secretChats().contains(chat)
    }

    public static func setSecret(_ chat: Int64, _ value: Bool) {
        var ids = self.secretChats()
        if value {
            ids.insert(chat)
        } else {
            ids.remove(chat)
        }
        self.setIds(ids, forKey: self.secretIdsKey)
    }
}
