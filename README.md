# Spacetile

A window manager that works with your Mac. Spacetile tiles windows on the native Spaces you create in Mission Control, and keeps the drag and resize gestures you already know.

Get it and read the docs at [spacetile.app](https://spacetile.app/docs/).

## Source-available

This repository holds the app's source so you can read and audit it. Spacetile is source-available, not open source. The source licence sets out what you may do with it; it will sit at the root of this repository.

## Build for auditing

You need macOS 26 or later, Xcode 26 or later and [ripgrep](https://github.com/BurntSushi/ripgrep) (`brew install ripgrep`).

```bash
swift build
swift test
scripts/bundle.sh --dev
open build/Spacetile.app
```

`scripts/bundle.sh` builds the release binary, wraps it in `build/Spacetile.app` and signs it with your first "Apple Development" identity, or ad hoc if you have none. [Setup](https://spacetile.app/docs/setup/) covers permissions and the `--dev` aids.

## Support

[Open an issue](https://github.com/Spacetile/Spacetile.app/issues/new/choose) to report a bug or ask a question.

## Pull requests

Pull requests aren't accepted yet. Any opened will be closed.
