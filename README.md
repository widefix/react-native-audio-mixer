# React Native Audio Mixer

Play multiple audio tracks at once and keep them in sync on iOS and Android.
Load vocals, drums, bass, or a click track and play them as one mix, with
low-latency controls and a native engine designed to keep memory use low.

- **Synchronized playback.** Start, pause, and seek all tracks together on a shared timeline.
- **Responsive mixing.** Adjust each track's volume and stereo pan during playback. Build mute and solo controls with the same volume API.
- **Live feedback.** Drive a seek bar and per-track level meters with typed playback events.

Mixing runs in native code. iOS decodes audio with AudioToolbox and mixes
with [miniaudio](https://miniaud.io). Android converts audio with ffmpeg-kit
and mixes with [Oboe](https://github.com/google/oboe).

## Installation

```sh
yarn add @widefix/react-native-audio-mixer
# or
npm install @widefix/react-native-audio-mixer
```

On iOS, install the pods:

```sh
cd ios && pod install
```

Rebuild your app after installation. Expo apps require a
[development build](https://docs.expo.dev/develop/development-builds/introduction/).

Tested with React Native 0.86 (new architecture) on iOS 26 and Android 16.
Android needs API 24 or newer.

## Quick start

Use stems exported from the same starting point, with any leading silence
preserved. Replace the example URLs with your own M4A files. The mixer
downloads and decodes the files before playback. `DownloadComplete` tells
you when the mix is ready and gives you the track IDs for volume and pan.

```tsx
import { useEffect, useState } from 'react';
import { Button, Text, View } from 'react-native';
import AudioMixer, { type TrackId } from '@widefix/react-native-audio-mixer';

const VOCALS = 'https://example.com/song/vocals.m4a';
const DRUMS = 'https://example.com/song/drums.m4a';

export function StemPlayer() {
  const [tracks, setTracks] = useState<Record<string, TrackId>>({});
  const [error, setError] = useState('');

  useEffect(() => {
    const ready = AudioMixer.addListener('DownloadComplete', setTracks);
    const failed = AudioMixer.addListener('DownloadErrors', ({ errMsg }) =>
      setError(errMsg)
    );

    AudioMixer.load([VOCALS, DRUMS]);

    return () => {
      ready.remove();
      failed.remove();
      AudioMixer.reset();
    };
  }, []);

  const vocals = tracks[VOCALS];

  if (error) return <Text>{error}</Text>;
  if (!vocals) return <Text>Loading tracks…</Text>;

  return (
    <View>
      <Button title="Play / pause" onPress={() => AudioMixer.togglePlay()} />
      <Button title="Lower vocals" onPress={() => AudioMixer.setVolume(vocals, 0.5)} />
      <Button title="Seek to 25%" onPress={() => AudioMixer.seek(0.25)} />
    </View>
  );
}
```

Set a track's volume to `0` to mute it. To solo a track, set the volume
of every other track to `0`. The [example app](example/App.tsx) shows how
to restore the previous mix when mute or solo is turned off.

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
| `PlaybackPaused` | `null` | Playback paused after an interruption or audio focus loss. |
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

## Credits

Created by [WideFix](https://widefix.com).

## License

[MIT](LICENSE)
