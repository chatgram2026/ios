# SPDX-License-Identifier: GPL-2.0-or-later
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# The recorder, mixer, compositor, storage, settings keys and notice policy. Foundation, AVFoundation, Core Image,
# Core Video, Metal and Accelerate only: no Telegram module may be added here.
swift_library(
    name = "NovagramCallRecordingCore",
    module_name = "NovagramCallRecordingCore",
    srcs = glob([
        "Sources/NovagramCallRecordingCore/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# The SwiftUI recordings list. Depends on the core only; the app injects theme, strings and actions.
swift_library(
    name = "NovagramCallRecordingUI",
    module_name = "NovagramCallRecordingUI",
    srcs = glob([
        "Sources/NovagramCallRecordingUI/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":NovagramCallRecordingCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
