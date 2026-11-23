# @widefix/react-native-audio-mixer

Multitrack audio mixer for React Native. Load several stems (vocals, drums,
bass, click…), play them in sync and change each track's volume and pan in
real time, with live levels and seeking.

Mixing runs in native code on both platforms:

- **iOS:** tracks are decoded with AudioToolbox and mixed through
  [miniaudio](https://miniaud.io).
- **Android:** tracks are converted with ffmpeg-kit and mixed through
  [Oboe](https://github.com/google/oboe), Google's low-latency audio library.

## Installation

```sh
yarn add @widefix/react-native-audio-mixer
# or
npm install @widefix/react-native-audio-mixer
```

Then install the iOS pods:

```sh
cd ios && pod install
```

The library contains native code, so it does not work in Expo Go. In an Expo
app, use a [development build](https://docs.expo.dev/develop/development-builds/introduction/).

Tested with React Native 0.86 (new architecture) on iOS 26 and Android 16.
Android needs API 24 or newer.

## Usage

```tsx
import { useEffect, useState } from 'react';
import AudioMixer, { type TrackId } from '@widefix/react-native-audio-mixer';

const STEMS = [
  'https://example.com/song/vocals.m4a',
  'https://example.com/song/drums.m4a',
  'https://example.com/song/bass.m4a',
];

export function Player() {
  const [tracks, setTracks] = useState<Record<string, TrackId>>({});
  const [progress, setProgress] = useState(0);

  useEffect(() => {
    const subscriptions = [
      // Maps every URL to the track id the other methods take.
      AudioMixer.addListener('DownloadComplete', setTracks),
      AudioMixer.addListener('PlaybackProgress', (e) => setProgress(e.progress)),
    ];
    AudioMixer.load(STEMS);
    return () => {
      subscriptions.forEach((s) => s.remove());
      AudioMixer.reset();
    };
  }, []);

  const vocals = tracks[STEMS[0]];
  // AudioMixer.togglePlay();
  // AudioMixer.setVolume(vocals, 0.5);
  // AudioMixer.setPan(vocals, -1);
  // AudioMixer.seek(0.25);
}
```

Mute and solo are built on `setVolume`: set a track to `0` to mute it, or set
every other track to `0` to solo it. The [example app](example/App.tsx) shows
the full pattern.

## API

### Methods

| Method | Description |
| --- | --- |
| `load(urls: string[])` | Downloads and decodes the given audio files, replacing any loaded tracks. Supports `http(s)` URLs to M4A (AAC or ALAC). |
| `togglePlay()` | Starts playback when paused, pauses it when playing. |
| `setVolume(trackId, volume)` | Track volume, from `0` (silent) to `1` (full). |
| `setPan(trackId, pan)` | Track pan, from `-1` (left) through `0` (center) to `1` (right). |
| `seek(progress)` | Moves playback to a position from `0` (start) to `1` (end). |
| `reset()` | Stops playback, cancels downloads and unloads every track. |
| `addListener(event, listener)` | Subscribes to an event. Returns a subscription with `remove()`. |

Values outside the ranges above are clamped.

### Events

| Event | Payload | When |
| --- | --- | --- |
| `DownloadStart` | `{ status: 'DownloadStart' }` | `load` started. |
| `TrackLoaded` | `{ name: TrackId }` | One track is downloaded and decoded. Use it for a progress indicator. |
| `DownloadComplete` | `Record<url, TrackId>` | Every track is ready to play. |
| `MixerDurationSet` | `number` | Length of the longest track, in seconds. |
| `PlaybackProgress` | `{ progress: number }` | About every 100 ms while playing, from `0` to `1`. |
| `TracksAmplitudes` | `{ amplitudes: Record<TrackId, number> }` | About every 100 ms while playing. The scale differs between iOS and Android. |
| `PlaybackPaused` | `null` | Playback stopped on its own: a phone call, another app taking audio focus. |
| `DownloadErrors` | `{ errMsg: string; reason?: string }` | A track failed to download or decode. The mixer is reset. |
| `AppErrorsX` | `{ errMsg: string }` | Any other native error, such as an unknown track id. |

All event names and payloads are typed, so `addListener` infers the payload
from the event name.

### Playback behavior

- Playback pauses when the app goes to the background and resumes when it
  returns.
- On iOS, an interruption such as a phone call pauses playback and resumes it
  afterwards when the system allows it. Otherwise `PlaybackPaused` is sent.
- On Android, a short audio focus loss pauses and then resumes. A permanent
  loss pauses and sends `PlaybackPaused`.

## Example app

The [example](example) app loads four synthesized stems and has play, seek,
volume, pan, mute, solo and level meters.

```sh
yarn                  # install everything, from the repository root
yarn example stems    # generate and serve the test stems (macOS)
yarn example start    # Metro
yarn example ios      # or: yarn example android
```

## Development

```sh
yarn typecheck   # TypeScript
yarn lint        # ESLint + Prettier
yarn test        # Jest
yarn test:ios    # PCM mixer and M4A decoder tests (macOS)
yarn prepare     # build lib/ with react-native-builder-bob
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## License

MIT
