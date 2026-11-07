load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram: no closed NovagramServices SDK. The demo numbers and their code addresses come from the build's
# Info.plist (`ChitgramDemoLogin`), never from the repo; see NovagramDemoCodeFetcher.swift.
swift_library(
    name = "NovagramAppleReview",
    module_name = "NovagramAppleReview",
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
