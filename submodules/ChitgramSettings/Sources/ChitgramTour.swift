import Foundation
import UIKit
import Display
import ItemListUI
import ChitgramCore

/// The dimmed layer of the tour: everything dark except the row being explained, a bubble with what it does, the
/// "2 / 19" counter and Skip at the top. A tap anywhere moves on.
final class ChitgramTourOverlay: UIView {
    var onTap: (() -> Void)?
    var onSkip: (() -> Void)?

    private let scrim = CAShapeLayer()
    private let bubble = UIView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let progressLabel = UILabel()
    private let skipButton = UIButton(type: .system)
    private var hole = CGRect()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        self.scrim.fillRule = .evenOdd
        self.scrim.fillColor = UIColor(white: 0.0, alpha: 0.62).cgColor
        self.layer.addSublayer(self.scrim)

        self.bubble.backgroundColor = UIColor(white: 0.12, alpha: 0.96)
        self.bubble.layer.cornerRadius = 14.0
        self.titleLabel.font = UIFont.systemFont(ofSize: 16.0, weight: .bold)
        self.titleLabel.textColor = .white
        self.titleLabel.numberOfLines = 0
        self.bodyLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.bodyLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        self.bodyLabel.numberOfLines = 0
        self.bubble.addSubview(self.titleLabel)
        self.bubble.addSubview(self.bodyLabel)
        self.addSubview(self.bubble)

        self.progressLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
        self.progressLabel.textColor = .white
        self.progressLabel.textAlignment = .center
        self.progressLabel.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        self.progressLabel.layer.cornerRadius = 13.0
        self.progressLabel.clipsToBounds = true
        self.addSubview(self.progressLabel)

        self.skipButton.setTitle(ChitgramStrings.get(340), for: .normal)
        self.skipButton.setTitleColor(.white, for: .normal)
        self.skipButton.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .bold)
        self.skipButton.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        self.skipButton.layer.cornerRadius = 16.0
        self.skipButton.addTarget(self, action: #selector(self.skipPressed), for: .touchUpInside)
        self.addSubview(self.skipButton)

        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(hole: CGRect, title: String, body: String, progress: String) {
        self.hole = hole
        self.titleLabel.text = title
        self.bodyLabel.text = body
        self.progressLabel.text = progress
        self.bubble.alpha = 0.0
        self.setNeedsLayout()
        self.layoutIfNeeded()
        UIView.animate(withDuration: 0.2, animations: {
            self.bubble.alpha = 1.0
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        self.scrim.frame = bounds
        let path = UIBezierPath(rect: bounds)
        if !self.hole.isEmpty {
            path.append(UIBezierPath(roundedRect: self.hole, cornerRadius: 12.0))
        }
        self.scrim.path = path.cgPath

        let top = self.safeAreaInsets.top + 8.0
        let progressWidth = ceil(self.progressLabel.sizeThatFits(CGSize(width: 200.0, height: 26.0)).width) + 26.0
        self.progressLabel.frame = CGRect(x: floor((bounds.width - progressWidth) / 2.0), y: top, width: progressWidth, height: 26.0)
        let skipWidth = ceil(self.skipButton.sizeThatFits(CGSize(width: 200.0, height: 32.0)).width) + 28.0
        self.skipButton.frame = CGRect(x: bounds.width - 12.0 - skipWidth, y: top - 3.0, width: skipWidth, height: 32.0)

        let width = min(bounds.width - 32.0, 420.0)
        let textWidth = width - 32.0
        let titleHeight = ceil(self.titleLabel.sizeThatFits(CGSize(width: textWidth, height: 1000.0)).height)
        let bodyHeight = ceil(self.bodyLabel.sizeThatFits(CGSize(width: textWidth, height: 1000.0)).height)
        let height = 14.0 + titleHeight + 6.0 + bodyHeight + 14.0
        self.titleLabel.frame = CGRect(x: 16.0, y: 14.0, width: textWidth, height: titleHeight)
        self.bodyLabel.frame = CGRect(x: 16.0, y: 14.0 + titleHeight + 6.0, width: textWidth, height: bodyHeight)
        var y = self.hole.maxY + 12.0
        if y + height > bounds.height - self.safeAreaInsets.bottom - 12.0 {
            y = max(top + 40.0, self.hole.minY - 12.0 - height)
        }
        self.bubble.frame = CGRect(x: floor((bounds.width - width) / 2.0), y: y, width: width, height: height)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if self.skipButton.frame.contains(recognizer.location(in: self)) {
            return
        }
        self.onTap?()
    }

    @objc private func skipPressed() {
        self.onSkip?()
    }
}

/// Chitgram's coach-mark tour (Android `FenixTour`): walks through the feature rows one at a time, scrolling to each,
/// darkening the rest and explaining the row. Tap to go on, Skip to stop.
final class ChitgramTour {
    struct Step {
        let tag: ItemListItemTag
        let title: String
        let body: String
    }

    private weak var controller: ItemListController?
    private let steps: [Step]
    private var index = -1
    private var overlay: ChitgramTourOverlay?
    var finished: (() -> Void)?

    init(controller: ItemListController, steps: [Step]) {
        self.controller = controller
        self.steps = steps
    }

    func start() {
        guard !self.steps.isEmpty, let window = self.controller?.view.window else {
            self.finish()
            return
        }
        let overlay = ChitgramTourOverlay(frame: window.bounds)
        overlay.onTap = { [weak self] in
            self?.next()
        }
        overlay.onSkip = { [weak self] in
            self?.finish()
        }
        overlay.alpha = 0.0
        window.addSubview(overlay)
        self.overlay = overlay
        UIView.animate(withDuration: 0.22, animations: {
            overlay.alpha = 1.0
        })
        self.next()
    }

    private func next() {
        self.index += 1
        if self.index >= self.steps.count {
            self.finish()
            return
        }
        self.locate(attempt: 0)
    }

    /// Finds the step's row, scrolling down a page at a time while it is not laid out yet; a row that never turns up
    /// is skipped (Android: the same, for rows shown only on some devices).
    private func locate(attempt: Int) {
        guard let controller = self.controller, self.overlay != nil, self.index < self.steps.count else {
            return
        }
        let step = self.steps[self.index]
        if let node = controller.itemNode(forTag: step.tag) {
            controller.ensureItemNodeVisible(node, animated: true)
            let index = self.index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: { [weak self] in
                guard let self, self.index == index else {
                    return
                }
                self.spotlight(node)
            })
            return
        }
        if attempt >= 12 {
            self.next()
            return
        }
        var lowest: ListViewItemNode?
        controller.forEachItemNode { node in
            if let current = lowest {
                if node.frame.maxY > current.frame.maxY {
                    lowest = node
                }
            } else {
                lowest = node
            }
        }
        if let lowest {
            controller.ensureItemNodeVisible(lowest, animated: false, atTop: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: { [weak self] in
            self?.locate(attempt: attempt + 1)
        })
    }

    private func spotlight(_ node: ListViewItemNode) {
        guard let overlay = self.overlay, self.index < self.steps.count else {
            return
        }
        let step = self.steps[self.index]
        let rect = node.view.convert(node.view.bounds, to: overlay).insetBy(dx: 8.0, dy: 0.0)
        overlay.show(hole: rect, title: step.title, body: step.body, progress: "\(self.index + 1) / \(self.steps.count)")
    }

    func finish() {
        self.index = self.steps.count
        if let overlay = self.overlay {
            self.overlay = nil
            UIView.animate(withDuration: 0.2, animations: {
                overlay.alpha = 0.0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        }
        let finished = self.finished
        self.finished = nil
        finished?()
    }
}
