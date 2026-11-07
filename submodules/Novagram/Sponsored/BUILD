load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram: Novagram's closed NovagramAds SDK is gone. NovagramSponsored keeps the API the Telegram-owned hooks call
# (TelegramUI, ChatListUI, GlobalControlPanelsContext) and serves no ads of its own; Telegram's own ads follow the
# "Remove all ads" switch.

# Dependency-light bridge for modules below NovagramSponsored in the graph (GalleryUI, chat bubble
# components). Nothing installs a provider, so it never reports an ad as ours.
swift_library(
    name = "NovagramSponsoredBridge",
    module_name = "NovagramSponsoredBridge",
    srcs = glob([
        "Bridge/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "NovagramSponsored",
    module_name = "NovagramSponsored",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":NovagramSponsoredBridge",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/ContextUI:ContextUI",
        "//submodules/Novagram/Messenger:NovagramMessenger",
    ],
    visibility = [
        "//visibility:public",
    ],
)
