load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's base: strings and settings. Foundation only, so TelegramCore and the app extensions may use it.
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
    ],
    visibility = [
        "//visibility:public",
    ],
)
