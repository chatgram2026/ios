load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's screens opened from a chat: edit history, per-chat tools, …
swift_library(
    name = "ChitgramChat",
    module_name = "ChitgramChat",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ChitgramCore",
        "//submodules/ChitgramSettings",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TextFormat:TextFormat",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
