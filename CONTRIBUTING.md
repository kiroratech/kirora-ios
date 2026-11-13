# Contributing

Thanks for helping. Report bugs through GitHub issues with the SDK version, iOS version,
and what you expected; security issues go to security@kirora.io instead (see
[SECURITY.md](SECURITY.md)).

## Local development

You need Swift 5.9 or later. Xcode isn't required for the tests: the SDK's UIKit parts sit
behind protocols, so the suite runs on macOS.

    ./scripts/test.sh

`scripts/test.sh` runs `swift test`, adding the paths the Command Line Tools need for
swift-testing when Xcode isn't installed. See [AGENTS.md](AGENTS.md) for the full checks
to run before a pull request, and the rules every change follows.

Public behaviour (options, methods, what is sent) is shared by every Kirora SDK and
defined in Kirora's client SDK interface first; open an issue before changing it.
