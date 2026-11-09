# Contributing to PerchDock

Thanks for helping make the Mac's Dock better. Bug reports, ideas, docs fixes and code are all welcome, and you don't need to be a macOS expert to help.

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/slynck/perchdock/issues/new?template=bug_report.yml). Your macOS version and dock position make most bugs much easier to reproduce.
- **Suggest a feature** with the [feature request form](https://github.com/slynck/perchdock/issues/new?template=feature_request.yml).
- **Pick up an issue.** Issues labeled [`good first issue`](https://github.com/slynck/perchdock/labels/good%20first%20issue) are small, self-contained and explain which files to look at. Comment on one to claim it so nobody duplicates your work.
- **Improve the docs.** If something in the README confused you, it'll confuse the next person too.

Expect a reply on issues and pull requests within a day or two.

## Set up

You'll need macOS 15 or later, Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/slynck/perchdock.git
cd perchdock
scripts/build.sh --run
```

`scripts/build.sh` generates `PerchDock.xcodeproj` from `project.yml`, so don't edit the project file in Xcode; change `project.yml` instead. The first run creates a local signing identity so the macOS permissions you grant survive rebuilds.

If PerchDock crashes while you're developing and the built-in Dock stays hidden, run `scripts/restore-native-dock.sh`.

## Run the tests

```bash
xcodebuild -project PerchDock.xcodeproj -scheme PerchDock -derivedDataPath build.noindex test
```

Tests use [Swift Testing](https://developer.apple.com/documentation/testing) and live in `Tests/PerchDockTests/`. Logic that doesn't need a window (geometry, formatting, parsing, settings) should have tests; UI changes should come with a screenshot in the pull request.

## Code style

Follow what's already in the file you're editing:

- Swift 6 with strict concurrency. UI and services run on the main actor.
- Variable names carry a type prefix: `str` for strings, `int` for integers, `flt` for `CGFloat`, `dbl` for `Double`, `bln` for booleans, `obj` for other objects, `arr…` for arrays (for example `arrStrBundleIds`) and `dict` for dictionaries.
- Every type and function has a `///` doc comment that says what it does, with `- Parameters:` and `- Returns:` where they apply.
- Comments explain *why*, not what the next line does.

## Pull requests

1. Fork the repository and create a branch from `main`, for example `fix/flyout-position` or `feat/weather-widget`.
2. Keep each pull request to one change. Small pull requests get reviewed quickly.
3. Make sure it builds and the tests pass. CI runs both on every pull request.
4. Fill in the pull request template, including screenshots or a short screen recording for anything visual.

By contributing, you agree that your contributions are licensed under the [GPL-3.0](LICENSE), the same license as the project.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
