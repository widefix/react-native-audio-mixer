import {
  NativeEventEmitter,
  NativeModules,
  Platform,
  type EmitterSubscription,
} from 'react-native';

const LINKING_ERROR =
  `The package '@widefix/react-native-audio-mixer' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

/** Identifier of a loaded track, as reported by `DownloadComplete`. */
export type TrackId = string;

/** Event names and payloads emitted by the native mixer. */
export interface AudioMixerEvents {
  /** Downloading of a new set of tracks has started. */
  DownloadStart: { status: 'DownloadStart' };
  /** A single track was downloaded and decoded. */
  TrackLoaded: { name: TrackId };
  /** All tracks are ready. Maps each source URL to its track id. */
  DownloadComplete: Record<string, TrackId>;
  /** Length of the longest track, in seconds. */
  MixerDurationSet: number;
  /** Playback position as a fraction from 0 to 1, about every 100 ms. */
  PlaybackProgress: { progress: number };
  /** Current amplitude per track, about every 100 ms while playing. */
  TracksAmplitudes: { amplitudes: Record<TrackId, number> };
  /** Playback stopped without being asked to (interruption, focus loss). */
  PlaybackPaused: null;
  /** A download or decode failed. The mixer is reset. */
  DownloadErrors: { errMsg: string; reason?: string };
  /** Any other native error. */
  AppErrorsX: { errMsg: string };
}

export type AudioMixerEvent = keyof AudioMixerEvents;

interface NativeAudioMixer {
  downloadAudioFiles(urls: string[]): void;
  togglePlay(): void;
  setVolume(volume: number, trackId: TrackId): void;
  setPan(pan: number, trackId: TrackId): void;
  setPlaybackPosition(progress: number): void;
  resetApp(): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

const Native: NativeAudioMixer = NativeModules.Armsaudio
  ? NativeModules.Armsaudio
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

let emitter: NativeEventEmitter | undefined;
const getEmitter = () => {
  emitter ??= new NativeEventEmitter(NativeModules.Armsaudio);
  return emitter;
};

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

export const AudioMixer = {
  /**
   * Downloads and decodes the given audio files, replacing any loaded tracks.
   * Listen to `DownloadComplete` to get the track id of each URL.
   */
  load(urls: string[]): void {
    Native.downloadAudioFiles(urls);
  },

  /** Starts playback when paused, pauses it when playing. */
  togglePlay(): void {
    Native.togglePlay();
  },

  /** Sets a track's volume, from 0 (silent) to 1 (full). */
  setVolume(trackId: TrackId, volume: number): void {
    Native.setVolume(clamp(volume, 0, 1), trackId);
  },

  /** Sets a track's pan, from -1 (left) through 0 (center) to 1 (right). */
  setPan(trackId: TrackId, pan: number): void {
    Native.setPan(clamp(pan, -1, 1), trackId);
  },

  /** Moves playback to a position given as a fraction from 0 to 1. */
  seek(progress: number): void {
    Native.setPlaybackPosition(clamp(progress, 0, 1));
  },

  /** Stops playback, cancels downloads and unloads every track. */
  reset(): void {
    Native.resetApp();
  },

  /** Subscribes to a mixer event. Call `remove()` on the result to stop. */
  addListener<E extends AudioMixerEvent>(
    event: E,
    listener: (payload: AudioMixerEvents[E]) => void
  ): EmitterSubscription {
    return getEmitter().addListener(event, listener);
  },
};

/**
 * @deprecated Use `AudioMixer`. Returns the raw native module, kept for apps
 * that still call it directly.
 */
export const newAddon = () => Native;

export default AudioMixer;
