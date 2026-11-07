# SPDX-License-Identifier: GPL-2.0-or-later
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# The rating prompt rules, the shared state in the `pro_messager` suite, the call to the system prompt, the
# write-review link and the Settings row texts. Foundation, StoreKit and UIKit/AppKit only: no Telegram module may be
# added here.
swift_library(
    name = "NovagramReviewPromptCore",
    module_name = "NovagramReviewPromptCore",
    srcs = glob([
        "Sources/NovagramReviewPromptCore/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)
