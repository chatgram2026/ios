load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's work in the background of each account: auto answer, and what follows it.
swift_library(
    name = "ChitgramEngine",
    module_name = "ChitgramEngine",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ChitgramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
