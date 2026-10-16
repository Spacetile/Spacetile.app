# Spacetile

A window manager that works with your Mac. Spacetile tiles windows on the native Spaces you create in Mission Control, and keeps the drag and resize gestures you already know.

## Install

```bash
brew install --cask spacetile/tap/spacetile
```

Or download the signed, notarized DMG from [spacetile.app](https://spacetile.app/#download). The docs are at [spacetile.app/docs](https://spacetile.app/docs/).

## Source-available

This repository holds the app's source so you can read and audit it. Spacetile is source-available. The [Source licence](LICENSE) lets anyone read the code and build it with `--dev` to audit it or investigate a problem; any other use needs a Licence from [spacetile.app](https://spacetile.app). It forbids redistributing the source or builds anywhere but through GitHub forks, and circumventing the licence check.

Code adapted from WhichSpace keeps its MIT licence, in [`Sources/CSkyLight/LICENSE-WhichSpace`](Sources/CSkyLight/LICENSE-WhichSpace).

## Build for auditing

You need macOS 26 or later, Xcode 26 or later and [ripgrep](https://github.com/BurntSushi/ripgrep) (`brew install ripgrep`).

```bash
swift build
swift test
scripts/bundle.sh --dev
open "build/Spacetile Dev.app"
```

`scripts/bundle.sh` builds the release binary, wraps it in `build/Spacetile.app` and signs it with your first "Apple Development" identity, or ad hoc if you have none. `--dev` makes `build/Spacetile Dev.app` instead, a separate app with its own Accessibility permission, so it can sit beside a downloaded Spacetile; opening one quits the other. Add `--install` to put the build in Applications and open it there, which the Install Command button needs. [Build from source](https://spacetile.app/docs/build/) covers signing, permissions and the `--dev` aids.

## Support

[Open an issue](https://github.com/Spacetile/Spacetile.app/issues/new/choose) to report a bug or ask a question.
