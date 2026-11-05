import Foundation
import Network
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram: region-gated auto-proxy for censored regions, currently Russia (Android `RegionProxyManager`).
///
/// Where Telegram's datacenters are blocked a fresh user cannot even reach the login servers. So at launch, before
/// login, if the device is in a listed region the app reads a SOCKS5 list from the Android app's Firebase Remote
/// Config, adds it to Telegram's own proxy list and turns the proxy on. The credentials never live in the app or the
/// repository, only in the Remote Config console, so blocked entries are swapped without an update.
///
/// The rules that keep it from fighting the user are Android's:
///  - nothing happens unless the console grants `ru_proxy_active`; a `false` delivered by the server is also the kill
///    switch that turns our proxy off everywhere at once (an absent value or a failed fetch never kills);
///  - a proxy the user set up is never touched, and once the user turns our proxy off it stays off;
///  - a pool found dead (no server reachable) is dropped for an hour, so a bad list cannot trap the user at
///    "Connecting…". Android leaves failover to Telegram's proxy rotation; here the watchdog moves to the first
///    server that answers.
///
/// Where the device is: the time zone, which iOS sets from the network and the location when it is automatic. The
/// language and region settings are deliberately not used (an Uzbek phone in Russian would read as Russian), and iOS
/// no longer tells apps the carrier's country.
public enum ChitgramRegionProxy {
    private static let activeKey = "ru_proxy_active"
    private static let regionsKey = "proxy_regions"
    private static let listKey = "ru_proxy_list"

    private static let autoPreference = "chatgram_region_proxy_auto"
    private static let appliedPreference = "chatgram_region_proxy_applied"
    private static let endpointPreference = "chatgram_region_proxy_endpoint"
    private static let backoffPreference = "chatgram_region_proxy_backoff_until"
    private static let instancePreference = "chatgram_firebase_instance_id"

    private static let watchdogDelay: Double = 30.0
    private static let backoffSeconds: Double = 60 * 60

    /// Time zones by the regions the console can list.
    private static let regionTimeZones: [String: Set<String>] = [
        "ru": [
            "Europe/Moscow", "Europe/Kaliningrad", "Europe/Samara", "Europe/Volgograd", "Europe/Saratov",
            "Europe/Ulyanovsk", "Europe/Astrakhan", "Europe/Kirov", "Asia/Yekaterinburg", "Asia/Omsk",
            "Asia/Novosibirsk", "Asia/Barnaul", "Asia/Tomsk", "Asia/Novokuznetsk", "Asia/Krasnoyarsk",
            "Asia/Irkutsk", "Asia/Chita", "Asia/Yakutsk", "Asia/Khandyga", "Asia/Vladivostok", "Asia/Ust-Nera",
            "Asia/Magadan", "Asia/Sakhalin", "Asia/Srednekolymsk", "Asia/Kamchatka", "Asia/Anadyr"
        ],
        "by": ["Europe/Minsk"],
        "ir": ["Asia/Tehran"],
        "cn": ["Asia/Shanghai", "Asia/Urumqi"],
        "tm": ["Asia/Ashgabat"]
    ]

    private static var running = false

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func info(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Once, early at launch. Cheap; it does nothing when the user has a proxy of their own or opted out.
    public static func maybeAutoConnect(sharedContext: SharedAccountContext) {
        if self.running {
            return
        }
        if self.defaults.object(forKey: self.autoPreference) as? Bool == false {
            return
        }
        guard let projectId = self.info("ChitgramFirebaseProjectId"), let apiKey = self.info("ChitgramFirebaseApiKey"), let appId = self.info("ChitgramFirebaseAppId") else {
            return
        }
        self.running = true
        let accountManager = sharedContext.accountManager
        let _ = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { sharedData in
            let settings = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? ProxySettings.defaultSettings
            let weApplied = self.defaults.bool(forKey: self.appliedPreference)
            // The proxy is the user's own: never touch it.
            if settings.enabled && !weApplied {
                self.running = false
                return
            }
            // Ours, turned off by the user: leave it off.
            if !settings.enabled && weApplied {
                self.running = false
                return
            }
            // A pool found dead recently: run direct for a while.
            if !settings.enabled && Date().timeIntervalSince1970 < self.defaults.double(forKey: self.backoffPreference) {
                self.running = false
                return
            }
            self.fetch(projectId: projectId, apiKey: apiKey, appId: appId, completion: { entries in
                self.decide(sharedContext: sharedContext, entries: entries)
            })
        })
    }

    /// The Remote Config values, or nil when they could not be read.
    private static func fetch(projectId: String, apiKey: String, appId: String, completion: @escaping ([String: String]?) -> Void) {
        guard let url = URL(string: "https://firebaseremoteconfig.googleapis.com/v1/projects/\(projectId)/namespaces/firebase:fetch?key=\(apiKey)") else {
            completion(nil)
            return
        }
        var instanceId = self.defaults.string(forKey: self.instancePreference) ?? ""
        if instanceId.isEmpty {
            instanceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.defaults.set(instanceId, forKey: self.instancePreference)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appId": appId,
            "appInstanceId": instanceId,
            "platformVersion": "ios",
            "timeZone": TimeZone.current.identifier
        ])
        URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
            var result: [String: String]?
            if error == nil, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                var entries: [String: String] = [:]
                for (key, value) in (object["entries"] as? [String: Any]) ?? [:] {
                    if let string = value as? String {
                        entries[key] = string
                    }
                }
                result = entries
            }
            let value = result
            DispatchQueue.main.async {
                completion(value)
            }
        }).resume()
    }

    private static func decide(sharedContext: SharedAccountContext, entries: [String: String]?) {
        guard let entries else {
            // Offline or no answer: nothing changes.
            self.running = false
            return
        }
        if let active = entries[self.activeKey] {
            if active.lowercased() != "true" {
                // Delivered by the server as off: the kill switch.
                self.kill(sharedContext: sharedContext, backoff: false)
                return
            }
        } else {
            self.running = false
            return
        }
        let regions = (entries[self.regionsKey] ?? "ru").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let zone = TimeZone.current.identifier
        let inRegion = (regions.isEmpty ? ["ru"] : regions).contains(where: { self.regionTimeZones[$0]?.contains(zone) ?? false })
        if !inRegion {
            self.kill(sharedContext: sharedContext, backoff: false)
            return
        }
        let servers = self.parse(entries[self.listKey] ?? "")
        if servers.isEmpty {
            self.running = false
            return
        }
        self.apply(sharedContext: sharedContext, servers: servers)
    }

    /// The console's JSON array of {"ip", "port", "user", "pass"} SOCKS5 entries.
    private static func parse(_ json: String) -> [ProxyServerSettings] {
        guard let data = json.data(using: .utf8), let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var result: [ProxyServerSettings] = []
        for item in array {
            let host = (item["ip"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let port = (item["port"] as? NSNumber)?.int32Value ?? Int32((item["port"] as? String) ?? "") ?? 0
            if host.isEmpty || port <= 0 {
                continue
            }
            let user = item["user"] as? String
            let pass = item["pass"] as? String
            result.append(ProxyServerSettings(host: host, port: port, connection: .socks5(username: (user?.isEmpty ?? true) ? nil : user, password: (pass?.isEmpty ?? true) ? nil : pass)))
        }
        return result
    }

    private static func endpoint(_ server: ProxyServerSettings) -> String {
        return "\(server.host):\(server.port)"
    }

    private static func apply(sharedContext: SharedAccountContext, servers: [ProxyServerSettings]) {
        let accountManager = sharedContext.accountManager
        let pick = servers[0]
        let _ = (updateProxySettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            if settings.enabled {
                // Already on (ours, from an earlier launch): keep it, only add new servers.
                for server in servers where !settings.servers.contains(server) {
                    settings.servers.append(server)
                }
                return settings
            }
            for server in servers where !settings.servers.contains(server) {
                settings.servers.append(server)
            }
            settings.activeServer = pick
            settings.enabled = true
            return settings
        })
        |> deliverOnMainQueue).startStandalone(completed: {
            if !self.defaults.bool(forKey: self.appliedPreference) {
                self.defaults.set(true, forKey: self.appliedPreference)
                self.defaults.set(self.endpoint(pick), forKey: self.endpointPreference)
            }
            self.running = false
            DispatchQueue.main.asyncAfter(deadline: .now() + self.watchdogDelay, execute: {
                self.watchdog(sharedContext: sharedContext, pool: servers)
            })
        })
    }

    /// Our proxy, still the active one and not answering: move to the first server of the pool that answers, or drop
    /// the pool for an hour when none does.
    private static func watchdog(sharedContext: SharedAccountContext, pool: [ProxyServerSettings]) {
        let accountManager = sharedContext.accountManager
        let _ = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { sharedData in
            let settings = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? ProxySettings.defaultSettings
            guard settings.enabled, self.defaults.bool(forKey: self.appliedPreference), let active = settings.activeServer, self.endpoint(active) == self.defaults.string(forKey: self.endpointPreference) else {
                return
            }
            self.firstReachable([active] + pool.filter { $0 != active }, completion: { server in
                guard let server else {
                    self.kill(sharedContext: sharedContext, backoff: true)
                    return
                }
                if server == active {
                    return
                }
                let _ = updateProxySettingsInteractively(accountManager: accountManager, { settings in
                    var settings = settings
                    settings.activeServer = server
                    return settings
                }).startStandalone()
                self.defaults.set(self.endpoint(server), forKey: self.endpointPreference)
            })
        })
    }

    private final class ProbeState {
        var finished = false
    }

    private static func probe(_ server: ProxyServerSettings, completion: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)) else {
            completion(false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp)
        let state = ProbeState()
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                if state.finished {
                    return
                }
                state.finished = true
                connection.cancel()
                completion(ok)
            }
        }
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: {
            finish(false)
        })
    }

    private static func firstReachable(_ servers: [ProxyServerSettings], completion: @escaping (ProxyServerSettings?) -> Void) {
        guard let first = servers.first else {
            completion(nil)
            return
        }
        self.probe(first, completion: { ok in
            if ok {
                completion(first)
            } else {
                self.firstReachable(Array(servers.dropFirst().prefix(20)), completion: completion)
            }
        })
    }

    /// Turns our proxy off: on the console's kill switch (it may come back once re-granted), or when the pool is dead
    /// (back off for an hour). Only the exact proxy we applied, never one the user switched to.
    private static func kill(sharedContext: SharedAccountContext, backoff: Bool) {
        let accountManager = sharedContext.accountManager
        let _ = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { sharedData in
            defer {
                self.running = false
            }
            let settings = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? ProxySettings.defaultSettings
            guard settings.enabled, self.defaults.bool(forKey: self.appliedPreference), let active = settings.activeServer, self.endpoint(active) == self.defaults.string(forKey: self.endpointPreference) else {
                return
            }
            let _ = updateProxySettingsInteractively(accountManager: accountManager, { settings in
                var settings = settings
                settings.enabled = false
                return settings
            }).startStandalone()
            // Cleared so a later grant may connect again; a user's own turn-off keeps it set and stays off.
            self.defaults.set(false, forKey: self.appliedPreference)
            self.defaults.removeObject(forKey: self.endpointPreference)
            if backoff {
                self.defaults.set(Date().timeIntervalSince1970 + self.backoffSeconds, forKey: self.backoffPreference)
            }
        })
    }
}
