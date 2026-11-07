load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's own screens. On the Novagram base (branch chitgram-nova) the Chitgram Premium page and About so far; the
# rest of the old port's screens come over as their features do.
swift_library(
    name = "ChitgramSettings",
    module_name = "ChitgramSettings",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ChitgramCore",
        "//submodules/ChitgramEngine",
        "//submodules/UndoUI:UndoUI",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramUI/Components/EntityKeyboard",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/AppBundle:AppBundle",
        "//submodules/TelegramUI/Components/Premium/PremiumStarComponent",
        "//submodules/ConfettiEffect:ConfettiEffect",
        "//submodules/ShareController:ShareController",
        "//submodules/Novagram/ReviewPromptKit:NovagramReviewPromptCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
