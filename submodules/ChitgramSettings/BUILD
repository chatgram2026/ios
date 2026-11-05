load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's screens in the Settings tab: the "Chitgram" section and what its rows open.
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
        "//submodules/LocalAuth:LocalAuth",
        "//submodules/PasscodeUI:PasscodeUI",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        "//submodules/BuildConfig:BuildConfig",
    ],
    visibility = [
        "//visibility:public",
    ],
)
