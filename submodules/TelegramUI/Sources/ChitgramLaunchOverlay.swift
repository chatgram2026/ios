import Foundation
import UIKit
import SwiftSignalKit

/// Chitgram: temporary. Says on screen what a launch that stays white is waiting for, since nothing else on a tester's
/// device can be read: the steps reached so far, and whether the two database queues still answer. A label that stops
/// counting means the main thread itself is stuck. Remove this once the white screen is explained.
final class ChitgramLaunchOverlay {
    private struct Watch {
        let name: String
        let ping: (@escaping () -> Void) -> Void
        var sentAt: Double?
    }

    private static let stepNotification = Notification.Name("ChitgramLaunchStep")
    private static let steps = ["presentation", "shared", "login", "context", "filters", "mainReady", "storiesReady", "tabs", "controller", "selected"]
    private static let showAfter: Double = 5.0
    private static let keepAfterFinish: Double = 3.0
    private static let slowAnswer: Double = 3.0

    private weak var window: UIWindow?
    private let label = UILabel()
    private let startTime = CFAbsoluteTimeGetCurrent()
    private var values: [String: String] = [:]
    private var watches: [Watch] = []
    private var finishedAt: Double?
    private var timer: SwiftSignalKit.Timer?
    private var observer: NSObjectProtocol?

    /// Any thread.
    static func note(_ step: String, _ value: String = "ok") {
        NotificationCenter.default.post(name: self.stepNotification, object: nil, userInfo: ["step": step, "value": value])
    }

    init(window: UIWindow) {
        self.window = window
        self.label.font = UIFont.systemFont(ofSize: 13.0)
        self.label.textColor = .white
        self.label.backgroundColor = UIColor(white: 0.0, alpha: 0.8)
        self.label.numberOfLines = 0
    }

    func start() {
        self.observer = NotificationCenter.default.addObserver(forName: ChitgramLaunchOverlay.stepNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, let step = notification.userInfo?["step"] as? String, let value = notification.userInfo?["value"] as? String else {
                return
            }
            self.values[step] = value
        })
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.tick()
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }

    /// `ping` runs something on the queue being watched and calls its argument when that is done.
    func watch(name: String, ping: @escaping (@escaping () -> Void) -> Void) {
        self.watches.append(Watch(name: name, ping: ping, sentAt: nil))
    }

    /// The first screen is up.
    func finish() {
        if self.finishedAt == nil {
            self.finishedAt = CFAbsoluteTimeGetCurrent()
            self.tick()
        }
    }

    private func answered(index: Int) {
        self.watches[index].sentAt = nil
    }

    private func send(index: Int) {
        self.watches[index].sentAt = CFAbsoluteTimeGetCurrent()
        let ping = self.watches[index].ping
        ping({ [weak self] in
            Queue.mainQueue().async {
                self?.answered(index: index)
            }
        })
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        if let finishedAt = self.finishedAt {
            if now - finishedAt >= ChitgramLaunchOverlay.keepAfterFinish {
                self.timer?.invalidate()
                self.timer = nil
                if let observer = self.observer {
                    NotificationCenter.default.removeObserver(observer)
                    self.observer = nil
                }
                self.label.removeFromSuperview()
            } else {
                self.show(text: "Tekshiruv: \(Int(finishedAt - self.startTime)) s, ochildi")
            }
            return
        }
        for index in self.watches.indices where self.watches[index].sentAt == nil {
            self.send(index: index)
        }
        if now - self.startTime < ChitgramLaunchOverlay.showAfter {
            return
        }
        var lines: [String] = ["Tekshiruv: \(Int(now - self.startTime)) s"]
        for step in ChitgramLaunchOverlay.steps {
            lines.append("\(step): \(self.values[step] ?? "-")")
        }
        for watch in self.watches {
            if let sentAt = watch.sentAt, now - sentAt >= ChitgramLaunchOverlay.slowAnswer {
                lines.append("\(watch.name): \(Int(now - sentAt)) s javob yo'q")
            } else {
                lines.append("\(watch.name): javob bor")
            }
        }
        self.show(text: lines.joined(separator: "\n"))
    }

    private func show(text: String) {
        guard let window = self.window else {
            return
        }
        if self.label.superview !== window {
            window.addSubview(self.label)
        }
        window.bringSubviewToFront(self.label)
        self.label.text = text
        let width = window.bounds.width - 32.0
        let size = self.label.sizeThatFits(CGSize(width: width, height: 1000.0))
        self.label.frame = CGRect(x: 16.0, y: window.safeAreaInsets.top + 8.0, width: width, height: ceil(size.height))
    }
}
