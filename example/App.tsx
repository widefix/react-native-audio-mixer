import { useEffect, useMemo, useRef, useState } from 'react';
import {
  PanResponder,
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
  type LayoutChangeEvent,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import AudioMixer, { type TrackId } from '@widefix/react-native-audio-mixer';

// `yarn example stems` serves these from your machine. The Android emulator
// reaches the host at 10.0.2.2.
const HOST = Platform.OS === 'android' ? '10.0.2.2' : 'localhost';
const STEMS = ['bass', 'chords', 'melody', 'click'].map((name) => ({
  name,
  url: `http://${HOST}:8089/${name}.m4a`,
}));

interface Track {
  name: string;
  id: TrackId;
  volume: number;
  pan: number;
  muted: boolean;
  solo: boolean;
}

type Status = 'idle' | 'loading' | 'ready' | 'error';

const formatTime = (seconds: number) => {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

/** Horizontal bar that reports a 0-1 value while tapped or dragged. */
function Bar({
  value,
  onChange,
  color = '#4f46e5',
  centered = false,
}: {
  value: number;
  onChange: (value: number) => void;
  color?: string;
  centered?: boolean;
}) {
  const width = useRef(1);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: (e) =>
          onChangeRef.current(
            Math.min(1, Math.max(0, e.nativeEvent.locationX / width.current))
          ),
        onPanResponderMove: (e) =>
          onChangeRef.current(
            Math.min(1, Math.max(0, e.nativeEvent.locationX / width.current))
          ),
      }),
    []
  );

  const fill = centered
    ? {
        left: `${Math.min(value, 0.5) * 100}%` as const,
        width: `${Math.abs(value - 0.5) * 100}%` as const,
      }
    : { left: 0, width: `${value * 100}%` as const };

  return (
    <View
      style={styles.bar}
      onLayout={(e: LayoutChangeEvent) => {
        width.current = e.nativeEvent.layout.width || 1;
      }}
      {...responder.panHandlers}
    >
      <View
        pointerEvents="none"
        style={[styles.barFill, fill, { backgroundColor: color }]}
      />
      <View
        pointerEvents="none"
        style={[styles.barThumb, { left: `${value * 100}%` }]}
      />
    </View>
  );
}

function Mixer() {
  const [status, setStatus] = useState<Status>('idle');
  const [error, setError] = useState('');
  const [loaded, setLoaded] = useState(0);
  const [tracks, setTracks] = useState<Track[]>([]);
  const [playing, setPlaying] = useState(false);
  const [duration, setDuration] = useState(0);
  const [progress, setProgress] = useState(0);
  const [levels, setLevels] = useState<Record<TrackId, number>>({});

  useEffect(() => {
    const subscriptions = [
      AudioMixer.addListener('TrackLoaded', () => setLoaded((n) => n + 1)),
      AudioMixer.addListener('DownloadComplete', (map) => {
        setTracks(
          STEMS.flatMap(({ name, url }) => {
            const id = map[url];
            return id
              ? [{ name, id, volume: 0.8, pan: 0, muted: false, solo: false }]
              : [];
          })
        );
        setStatus('ready');
      }),
      AudioMixer.addListener('MixerDurationSet', setDuration),
      AudioMixer.addListener('PlaybackProgress', ({ progress: p }) =>
        setProgress(p)
      ),
      AudioMixer.addListener('TracksAmplitudes', ({ amplitudes }) =>
        setLevels(amplitudes)
      ),
      AudioMixer.addListener('PlaybackPaused', () => setPlaying(false)),
      AudioMixer.addListener('DownloadErrors', ({ errMsg }) => {
        setError(errMsg);
        setStatus('error');
      }),
      AudioMixer.addListener('AppErrorsX', ({ errMsg }) => setError(errMsg)),
    ];
    return () => {
      subscriptions.forEach((s) => s.remove());
      AudioMixer.reset();
    };
  }, []);

  // Apply volume, mute and solo every time the mix changes.
  useEffect(() => {
    const soloActive = tracks.some((t) => t.solo);
    tracks.forEach((t) => {
      const audible = !t.muted && (!soloActive || t.solo);
      AudioMixer.setVolume(t.id, audible ? t.volume : 0);
      AudioMixer.setPan(t.id, t.pan);
    });
  }, [tracks]);

  const load = () => {
    setStatus('loading');
    setError('');
    setLoaded(0);
    setTracks([]);
    setPlaying(false);
    setProgress(0);
    AudioMixer.load(STEMS.map((s) => s.url));
  };

  const update = (id: TrackId, change: Partial<Track>) =>
    setTracks((all) => all.map((t) => (t.id === id ? { ...t, ...change } : t)));

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.title}>Audio Mixer</Text>
      <Text style={styles.subtitle}>@widefix/react-native-audio-mixer</Text>

      <Pressable
        style={styles.button}
        onPress={load}
        disabled={status === 'loading'}
      >
        <Text style={styles.buttonText}>
          {status === 'loading'
            ? `Loading ${loaded}/${STEMS.length}…`
            : 'Load stems'}
        </Text>
      </Pressable>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      {status === 'ready' && (
        <>
          <View style={styles.transport}>
            <Pressable
              style={[styles.button, styles.play]}
              onPress={() => {
                AudioMixer.togglePlay();
                setPlaying((p) => !p);
              }}
            >
              <Text style={styles.buttonText}>
                {playing ? 'Pause' : 'Play'}
              </Text>
            </Pressable>
            <Text style={styles.time}>
              {formatTime(progress * duration)} / {formatTime(duration)}
            </Text>
          </View>
          <Bar
            value={progress}
            onChange={(p) => {
              setProgress(p);
              AudioMixer.seek(p);
            }}
          />

          {tracks.map((t) => (
            <View key={t.id} style={styles.track}>
              <View style={styles.trackHeader}>
                <Text style={styles.trackName}>{t.name}</Text>
                <View style={styles.meter}>
                  <View
                    style={[
                      styles.meterFill,
                      {
                        width: `${Math.min(1, (levels[t.id] ?? 0) * 2) * 100}%`,
                      },
                    ]}
                  />
                </View>
                <Pressable
                  style={[styles.toggle, t.muted && styles.toggleMute]}
                  onPress={() => update(t.id, { muted: !t.muted })}
                >
                  <Text style={styles.toggleText}>M</Text>
                </Pressable>
                <Pressable
                  style={[styles.toggle, t.solo && styles.toggleSolo]}
                  onPress={() => update(t.id, { solo: !t.solo })}
                >
                  <Text style={styles.toggleText}>S</Text>
                </Pressable>
              </View>
              <Text style={styles.label}>
                Volume {Math.round(t.volume * 100)}%
              </Text>
              <Bar
                value={t.volume}
                onChange={(v) => update(t.id, { volume: v })}
              />
              <Text style={styles.label}>
                Pan{' '}
                {t.pan === 0
                  ? 'C'
                  : t.pan < 0
                    ? `L${Math.round(-t.pan * 100)}`
                    : `R${Math.round(t.pan * 100)}`}
              </Text>
              <Bar
                centered
                color="#0ea5e9"
                value={(t.pan + 1) / 2}
                onChange={(v) => {
                  const pan = Math.abs(v - 0.5) < 0.04 ? 0 : v * 2 - 1;
                  update(t.id, { pan });
                }}
              />
            </View>
          ))}
        </>
      )}
    </ScrollView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="dark-content" />
      <SafeAreaView style={styles.root}>
        <Mixer />
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#f8fafc' },
  content: { padding: 20, gap: 12 },
  title: { fontSize: 28, fontWeight: '700', color: '#0f172a' },
  subtitle: { fontSize: 13, color: '#64748b', marginBottom: 8 },
  button: {
    backgroundColor: '#4f46e5',
    borderRadius: 10,
    paddingVertical: 12,
    alignItems: 'center',
  },
  buttonText: { color: 'white', fontWeight: '600', fontSize: 16 },
  error: { color: '#dc2626' },
  transport: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    marginTop: 8,
  },
  play: { flex: 1 },
  time: { fontVariant: ['tabular-nums'], color: '#334155', fontSize: 16 },
  bar: {
    height: 28,
    justifyContent: 'center',
    borderRadius: 6,
    backgroundColor: '#e2e8f0',
    overflow: 'hidden',
  },
  barFill: { position: 'absolute', top: 0, bottom: 0 },
  barThumb: {
    position: 'absolute',
    width: 3,
    marginLeft: -1.5,
    top: 0,
    bottom: 0,
    backgroundColor: '#0f172a',
  },
  track: {
    backgroundColor: 'white',
    borderRadius: 12,
    padding: 14,
    gap: 6,
    borderWidth: 1,
    borderColor: '#e2e8f0',
  },
  trackHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  trackName: { fontSize: 17, fontWeight: '600', width: 70, color: '#0f172a' },
  meter: {
    flex: 1,
    height: 6,
    borderRadius: 3,
    backgroundColor: '#e2e8f0',
    overflow: 'hidden',
  },
  meterFill: { height: 6, backgroundColor: '#22c55e' },
  toggle: {
    width: 32,
    height: 32,
    borderRadius: 6,
    backgroundColor: '#cbd5e1',
    alignItems: 'center',
    justifyContent: 'center',
  },
  toggleMute: { backgroundColor: '#f97316' },
  toggleSolo: { backgroundColor: '#eab308' },
  toggleText: { fontWeight: '700', color: '#0f172a' },
  label: { fontSize: 12, color: '#64748b', marginTop: 4 },
});
