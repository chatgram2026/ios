import Foundation

/// The demo accounts App Review signs in with (Android `utils/DemoNumber`): when one of their numbers is entered, the
/// login code comes from the owner's server instead of an SMS. The numbers and code addresses are in the signed build's
/// configuration only (Info.plist keys `ChitgramDemo*`), never in the repository; without them this does nothing.
public enum ChitgramDemoLogin {
    /// The server waits up to 25 s for the code; one more try after a miss, at least 5 s later (its rate limit).
    private static let retryDelay: Double = 6.0

    private static func value(_ key: String) -> String {
        return (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func digits(_ text: String) -> String {
        return String(text.filter { $0.isNumber })
    }

    /// The code address for `number`, or nil when it is not a demo number.
    public static func codeUrl(forNumber number: String) -> URL? {
        let entered = self.digits(number)
        if entered.isEmpty {
            return nil
        }
        let first = self.digits(self.value("ChitgramDemoPhone"))
        let second = self.digits(self.value("ChitgramDemoPhone2"))
        var address: String?
        if !first.isEmpty && entered == first {
            address = self.value("ChitgramDemoCodeUrl")
        } else if !second.isEmpty && entered == second {
            let own = self.value("ChitgramDemoCodeUrl2")
            let base = self.value("ChitgramDemoCodeUrl")
            address = !own.isEmpty ? own : (base.isEmpty ? "" : base + "-2")
        }
        guard let address, !address.isEmpty else {
            return nil
        }
        return URL(string: address)
    }

    /// Fetches the login code for a demo number (digits only), retrying once; nil when there is none. Calls back on
    /// the main queue.
    public static func fetchCode(url: URL, retries: Int = 1, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35.0
        URLSession.shared.dataTask(with: request, completionHandler: { data, response, _ in
            var code = ""
            if let response = response as? HTTPURLResponse, response.statusCode == 200, let data, let text = String(data: data, encoding: .utf8), !text.contains("not found") {
                code = self.digits(text)
            }
            DispatchQueue.main.async {
                if !code.isEmpty {
                    completion(code)
                } else if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay, execute: {
                        self.fetchCode(url: url, retries: retries - 1, completion: completion)
                    })
                } else {
                    completion(nil)
                }
            }
        }).resume()
    }
}
