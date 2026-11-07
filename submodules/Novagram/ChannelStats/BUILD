load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram: Novagram's closed NovagramInsights SDK (its hidden admin statistics screen) is gone. The module keeps
# the entry the Settings hooks call; the row never appears.
swift_library(
    name = "NovagramChannelStats",
    module_name = "NovagramChannelStats",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AccountContext:AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
