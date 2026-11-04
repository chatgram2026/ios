load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's base: strings and settings. No UI framework, so TelegramCore and the app extensions may use it.
swift_library(
    name = "ChitgramCore",
    module_name = "ChitgramCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
