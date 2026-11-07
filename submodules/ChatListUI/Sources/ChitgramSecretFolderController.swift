import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import ContextUI
import ChitgramCore

/// The id that marks the secret folder's own list, the one list that shows the chats all the others hide.
let chitgramSecretFolderFilterId: Int32 = Int32.max - 100

private func chitgramSecretFolderFilter(id: Int32, chats: Set<Int64>) -> ChatListFilter {
    var includePeers = ChatListFilterIncludePeers()
    includePeers.setPeers(chats.sorted().map { EnginePeer.Id($0) })
    return .filter(
        id: id,
        title: ChatFolderTitle(text: "", entities: [], enableAnimations: false),
        emoticon: nil,
        data: ChatListFilterData(
            isShared: false,
            hasSharedLinks: false,
            categories: [],
            excludeMuted: false,
            excludeRead: false,
            excludeArchived: false,
            includePeers: includePeers,
            excludePeers: [],
            color: nil
        )
    )
}

/// The secret folder (Android: folder 100 in `DialogsActivity`): a real chat list of the chats moved into it, opened
/// after its passcode, with the searching duck while it is empty.
final class ChitgramSecretFolderController: ViewController {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var chatsDisposable: Disposable?

    private var currentChats: Set<Int64>?
    private var filterGeneration: Int32 = 0

    private var listNode: ChatListNode?
    private var emptyAnimationNode: AnimatedStickerNode?
    private var emptyTitleNode: ImmediateTextNode?
    private var validLayout: ContainerViewLayout?

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = ChitgramStrings.get(213)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.chatsDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.chatList.backgroundColor

        let presentationData = self.presentationData
        let listNode = ChatListNode(
            context: self.context,
            location: .chatList(groupId: .root),
            chatListFilter: chitgramSecretFolderFilter(id: chitgramSecretFolderFilterId, chats: ChitgramLock.secretChats()),
            previewing: false,
            fillPreloadItems: false,
            mode: .chatList(appendContacts: false),
            theme: presentationData.theme,
            fontSize: presentationData.listsFontSize,
            strings: presentationData.strings,
            dateTimeFormat: presentationData.dateTimeFormat,
            nameSortOrder: presentationData.nameSortOrder,
            nameDisplayOrder: presentationData.nameDisplayOrder,
            animationCache: self.context.animationCache,
            animationRenderer: self.context.animationRenderer,
            disableAnimations: true,
            isInlineMode: false,
            autoSetReady: true,
            isMainTab: false
        )
        listNode.peerSelected = { [weak self] peer, _, _, _, _ in
            guard let self, let navigationController = self.navigationController as? NavigationController else {
                return
            }
            self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer)))
        }
        // Android keeps "Remove from secret chat" in the selection menu; here it is the long press on the chat.
        listNode.activateChatPreview = { [weak self] item, _, _, gesture, _ in
            gesture?.cancel()
            guard let self, case let .peer(peerData) = item.content, let peer = peerData.peer.peer else {
                return
            }
            self.openMenu(peerId: peer.id)
        }
        self.displayNode.addSubnode(listNode)
        self.listNode = listNode

        self.displayNodeDidLoad()

        self.chatsDisposable = (ChitgramPreferences.shared.changes
        |> map { _ -> Set<Int64> in
            return ChitgramLock.secretChats()
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak self] chats in
            self?.updateChats(chats)
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.listNode?.clearHighlightAnimated(true)
    }

    private func updateChats(_ chats: Set<Int64>) {
        if let currentChats = self.currentChats, currentChats != chats {
            self.filterGeneration += 1
            // `updateFilter` only takes a filter whose id differs, and the list reads its rule from the filter.
            self.listNode?.updateFilter(chitgramSecretFolderFilter(id: chitgramSecretFolderFilterId - (self.filterGeneration % 2), chats: chats))
        }
        self.currentChats = chats
        if let layout = self.validLayout {
            self.updateEmptyState(layout: layout)
        }
    }

    private func openMenu(peerId: EnginePeer.Id) {
        let presentationData = self.presentationData
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: ChitgramStrings.get(216), color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    ChitgramLock.setSecret(peerId.toInt64(), false)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    private func updateEmptyState(layout: ContainerViewLayout) {
        guard self.currentChats?.isEmpty == true else {
            self.emptyAnimationNode?.removeFromSupernode()
            self.emptyAnimationNode = nil
            self.emptyTitleNode?.removeFromSupernode()
            self.emptyTitleNode = nil
            return
        }

        let animationNode: AnimatedStickerNode
        if let current = self.emptyAnimationNode {
            animationNode = current
        } else {
            animationNode = DefaultAnimatedStickerNodeImpl(lottieSettings: self.context.lottieRenderingSettings)
            animationNode.setup(source: AnimatedStickerNodeLocalFileSource(name: "ChatListNoResults"), width: 248, height: 248, playbackMode: .loop, mode: .direct(cachePathPrefix: nil))
            animationNode.visibility = true
            self.displayNode.addSubnode(animationNode)
            self.emptyAnimationNode = animationNode
        }

        let titleNode: ImmediateTextNode
        if let current = self.emptyTitleNode {
            titleNode = current
        } else {
            titleNode = ImmediateTextNode()
            titleNode.maximumNumberOfLines = 0
            titleNode.textAlignment = .center
            titleNode.attributedText = NSAttributedString(string: ChitgramStrings.get(372), font: Font.semibold(17.0), textColor: self.presentationData.theme.list.itemPrimaryTextColor)
            self.displayNode.addSubnode(titleNode)
            self.emptyTitleNode = titleNode
        }

        let sideInset: CGFloat = max(layout.safeInsets.left, layout.safeInsets.right) + 32.0
        let animationSize = CGSize(width: 120.0, height: 120.0)
        let titleSize = titleNode.updateLayout(CGSize(width: max(1.0, layout.size.width - sideInset * 2.0), height: .greatestFiniteMagnitude))
        let spacing: CGFloat = 16.0
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottomInset = layout.insets(options: [.input]).bottom
        let availableHeight = max(0.0, layout.size.height - navigationHeight - bottomInset)
        let contentHeight = animationSize.height + spacing + titleSize.height
        let originY = navigationHeight + floor((availableHeight - contentHeight) / 2.0)

        animationNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - animationSize.width) / 2.0), y: originY), size: animationSize)
        animationNode.updateLayout(size: animationSize)
        titleNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - titleSize.width) / 2.0), y: originY + animationSize.height + spacing), size: titleSize)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.validLayout = layout

        if let listNode = self.listNode {
            let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
            var insets = layout.insets(options: [.input])
            insets.top = navigationHeight
            insets.left = layout.safeInsets.left
            insets.right = layout.safeInsets.right

            let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve)
            transition.updateFrame(node: listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
            listNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets, visibleTopInset: navigationHeight, originalTopInset: navigationHeight, storiesInset: 0.0, inlineNavigationLocation: nil, inlineNavigationTransitionFraction: 0.0)
        }

        self.updateEmptyState(layout: layout)
    }
}
