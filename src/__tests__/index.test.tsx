import { NativeModules } from 'react-native';

const native = {
  downloadAudioFiles: jest.fn(),
  togglePlay: jest.fn(),
  setVolume: jest.fn(),
  setPan: jest.fn(),
  setPlaybackPosition: jest.fn(),
  resetApp: jest.fn(),
  addListener: jest.fn(),
  removeListeners: jest.fn(),
};

const loadMixer = () => {
  let mixer!: typeof import('../index');
  jest.isolateModules(() => {
    mixer = require('../index');
  });
  return mixer;
};

describe('AudioMixer', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    NativeModules.RNAudioMixer = native;
  });

  afterEach(() => {
    delete NativeModules.RNAudioMixer;
  });

  it('loads tracks from URLs', () => {
    const { AudioMixer } = loadMixer();
    AudioMixer.load(['https://example.com/a.m4a', 'https://example.com/b.m4a']);
    expect(native.downloadAudioFiles).toHaveBeenCalledWith([
      'https://example.com/a.m4a',
      'https://example.com/b.m4a',
    ]);
  });

  it('passes the track id after the value, as the native module expects', () => {
    const { AudioMixer } = loadMixer();
    AudioMixer.setVolume('track0.m4a', 0.5);
    AudioMixer.setPan('track0.m4a', -0.25);
    expect(native.setVolume).toHaveBeenCalledWith(0.5, 'track0.m4a');
    expect(native.setPan).toHaveBeenCalledWith(-0.25, 'track0.m4a');
  });

  it('clamps volume, pan and seek position', () => {
    const { AudioMixer } = loadMixer();
    AudioMixer.setVolume('t', 3);
    AudioMixer.setVolume('t', -1);
    AudioMixer.setPan('t', 2);
    AudioMixer.setPan('t', -2);
    AudioMixer.seek(1.5);
    AudioMixer.seek(-0.5);
    expect(native.setVolume.mock.calls).toEqual([
      [1, 't'],
      [0, 't'],
    ]);
    expect(native.setPan.mock.calls).toEqual([
      [1, 't'],
      [-1, 't'],
    ]);
    expect(native.setPlaybackPosition.mock.calls).toEqual([[1], [0]]);
  });

  it('maps togglePlay and reset to the native methods', () => {
    const { AudioMixer } = loadMixer();
    AudioMixer.togglePlay();
    AudioMixer.reset();
    expect(native.togglePlay).toHaveBeenCalledTimes(1);
    expect(native.resetApp).toHaveBeenCalledTimes(1);
  });

  it('delivers native events to listeners until removed', () => {
    const { AudioMixer } = loadMixer();
    const { DeviceEventEmitter } = require('react-native');
    const listener = jest.fn();
    const subscription = AudioMixer.addListener('PlaybackProgress', listener);

    DeviceEventEmitter.emit('PlaybackProgress', { progress: 0.25 });
    subscription.remove();
    DeviceEventEmitter.emit('PlaybackProgress', { progress: 0.5 });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith({ progress: 0.25 });
  });

  it('keeps newAddon returning the raw native module', () => {
    const { newAddon } = loadMixer();
    expect(newAddon()).toBe(native);
  });

  it('throws a linking error when the native module is missing', () => {
    delete NativeModules.RNAudioMixer;
    const { AudioMixer } = loadMixer();
    expect(() => AudioMixer.togglePlay()).toThrow(/doesn't seem to be linked/);
  });
});
