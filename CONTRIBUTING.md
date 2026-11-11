# Contributing

Contributions are welcome, large or small.

## Setup

The repository is a Yarn workspace with two packages:

- the library, in the root directory
- the example app, in `example/`

Use Node 22 (see `.nvmrc`) and Yarn. The repository pins Yarn 3 in
`.yarn/releases`, so the `yarn` you already have picks it up. npm does not
support this workspace setup.

```sh
yarn
```

## Working on the library

The example app uses the library straight from `src/`, `ios/` and `android/`.
JavaScript changes show up with a Metro reload, while native changes need a
rebuild of the app.

```sh
yarn example stems     # test stems on http://localhost:8089 (macOS)
yarn example start     # Metro
yarn example ios
yarn example android
```

To edit native code in an IDE:

- **iOS:** open `example/ios/AudioMixerExample.xcworkspace` in Xcode. The
  library is under `Pods > Development Pods > react-native-audio-mixer`.
- **Android:** open `example/android` in Android Studio. The library is the
  `widefix_react-native-audio-mixer` module.

## Checks

Run these before opening a pull request. CI runs them too.

```sh
yarn typecheck
yarn lint          # yarn lint --fix formats with Prettier
yarn test
yarn test:ios      # macOS only
```

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org), for example
`fix(android): resume playback after a call`. The release changelog is
generated from them.

## Pull requests

- Keep each pull request to one change.
- Test native changes on both platforms with the example app.
- Update the README when you change the public API.
