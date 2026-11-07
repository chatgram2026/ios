load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram: no Novagram statistics server and no closed NovagramServices SDK; see NovagramAnalyticsManager.swift.
swift_library(
    name = "NovagramAnalytics",
    module_name = "NovagramAnalytics",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Novagram/ReviewPrompt:NovagramReviewPrompt",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
