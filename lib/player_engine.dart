// Peachz — Player Engine (Singleton) [v0]
// ----------------------------------
// One global audio engine for the entire app. Designed for FlutterFlow:
// - Use Custom Actions to call the public methods (play/pause/seek/etc).
// - Use a small "bridge" widget (PeachzPlayerBridge) to listen to `snapshot$`
//   and pipe values into FFAppState (state, positionMs, durationMs, trackId, needPurchase, error).
//
// Gating model implemented here (client-side flow, server is source of truth):
// - Per user × per track: 3 free *qualified* listens (≥30s) → free.
// - 4th qualified listen and beyond: deduct 1 credit at the 30s checkpoint.
// - Owned tracks: infinite plays, no counting/charging.
// - We never guess offline: if the 30s checkpoint can't be posted, we pause.
//
// API contract (adjust endpoints/fields to your backend):
// - GET  /allowance?trackId=... → { owned, free_listens_remaining, will_charge_if_qualified, insufficient_credits, session_id }
// - POST /playable { trackId, quality } → { url, mime, expiresAt }
// - POST /listen_checkpoint { track_id, session_id, position_ms } → { qualified, charged, free_listens_remaining, owned } (idempotent)
//
// IMPORTANT: Keep URLs short-lived and enable Range requests server-side.
//
import 'dart:async';
import 'package:just_audio/just_audio.dart';

enum EngineState {
  idle,
  loading,
  buffering,
  playing,
  paused,
  ended,
  error,
}


/// TrackItem: Mirror of PzTrackItemStruct but without FlutterFlow dependencies
class TrackItem {
  final String? _aacUrl;
  final String? _aiffUrl;
  final String? _albumId;
  final String? _artistId;
  final double? _bpm;
  final String? _mainGenre;
  final String? _wavUrl;
  final String? _trackName;
  final String? _trackId;
  final String? _waveformJsonUrl;

  const TrackItem({
    String? aacUrl,
    String? aiffUrl,
    String? albumId,
    String? artistId,
    double? bpm,
    String? mainGenre,
    String? wavUrl,
    String? trackName,
    String? trackId,
    String? waveformJsonUrl,
  }) : _aacUrl = aacUrl,
       _aiffUrl = aiffUrl,
       _albumId = albumId,
       _artistId = artistId,
       _bpm = bpm,
       _mainGenre = mainGenre,
       _wavUrl = wavUrl,
       _trackName = trackName,
       _trackId = trackId,
       _waveformJsonUrl = waveformJsonUrl;

  // Direct nullable field access
  String? get aacUrl => _aacUrl;
  String? get aiffUrl => _aiffUrl;
  String? get albumId => _albumId;
  String? get artistId => _artistId;
  double? get bpm => _bpm;
  String? get mainGenre => _mainGenre;
  String? get wavUrl => _wavUrl;
  String? get trackName => _trackName;
  String? get trackId => _trackId;
  String? get waveformJsonUrl => _waveformJsonUrl;

  static TrackItem fromMap(Map<String, dynamic> data) => TrackItem(
    aacUrl: data['aac_url'] as String?,
    aiffUrl: data['aiff_url'] as String?,
    albumId: data['album_id'] as String?,
    artistId: data['artist_id'] as String?,
    bpm: data['bpm']?.toDouble(),
    mainGenre: data['main_genre'] as String?,
    wavUrl: data['wav_url'] as String?,
    trackName: data['track_name'] as String?,
    trackId: data['track_id'] as String?,
    waveformJsonUrl: data['waveform_json_url'] as String?,
  );
}

class PlaylistSnapshot {
  final bool isEmpty;
  final bool hasNext;
  final bool hasPrev;

  const PlaylistSnapshot({
    required this.isEmpty,
    required this.hasNext,
    required this.hasPrev,
  });

  static PlaylistSnapshot initial() {
    return const PlaylistSnapshot(
      isEmpty: true,
      hasNext: false,
      hasPrev: false,
    );
  }

  PlaylistSnapshot copyWith({
    bool? isEmpty,
    bool? hasNext,
    bool? hasPrev,
  }) {
    return PlaylistSnapshot(
      isEmpty: isEmpty ?? this.isEmpty,
      hasNext: hasNext ?? this.hasNext,
      hasPrev: hasPrev ?? this.hasPrev,
    );
  }
}

/// The PlayerEngine Singleton.
/// Access via: `final engine = PlayerEngine.I;`
class PlayerEngine {
  PlayerEngine._internal() {
    _playlist = AudioPlaylist(_player);
  }

  static final PlayerEngine I = PlayerEngine._internal();

  final _player = AudioPlayer();
  late final AudioPlaylist _playlist;
  EngineSnapshot _snap = EngineSnapshot.initial();
  EngineSnapshot get currentSnapshot => _snap;
  TrackItem? get currentTrack => _playlist.current;

  /// Timer that drives snapshot emissions
  Timer? _snapshotTicker;

  final _snapshotController = StreamController<EngineSnapshot>.broadcast();

  /// Public stream for widgets to subscribe to engine state updates.
  Stream<EngineSnapshot> get snapshotStream => _snapshotController.stream;

  final _playlistController =
      StreamController<Playlist<TrackItem>>.broadcast();
  Stream<Playlist<TrackItem>> get playlistStream =>
      _playlistController.stream;

  final _currentTrack = StreamController<TrackItem>.broadcast();
  Stream<TrackItem> get currentTrackStream => _currentTrack.stream;

  final _playlistSnapController =
      StreamController<PlaylistSnapshot>.broadcast();
  Stream<PlaylistSnapshot> get playlistSnapStream =>
      _playlistSnapController.stream;

  AudioPlayer get player => _player;

  void configure() {
    print('PlayerEngine: configure()');
    // Player event hooks to improve state accuracy.
    _player.playbackEventStream.listen((_) {
      _updateAndEmitSnap(_snap.copyWith(
        state: mapPlayerState(_player.playerState),
        position: _player.position,
        duration: _player.duration ?? _snap.duration,
      ));
    }, onError: (e, st) {
      _updateAndEmitSnap(
          _snap.copyWith(state: EngineState.error, errorCode: 'decode'));
    });

    // Start periodic snapshot ticker (position updates).
    _startTicker();
  }

  Future<void> play() async {
    if (_player.playing) return;

    // Debug: Log what's currently loaded
    final currentTrack = _playlist.current;
    print(
        'PLAY: About to play track: ${currentTrack?.trackName ?? 'Unknown'} (${currentTrack?.wavUrl ?? 'No URL'})');

    // Start playing without waiting for completion
    _player.play(); // Don't await - just start playback
    _updateAndEmitSnap(_updateState());
  }

  Future<void> pause() async {
    if (!_player.playing) return;
    await _player.pause();
    _updateAndEmitSnap(_updateState());
  }

  Future<void> stop() async {
    if (!_player.playing) return;
    await _player.stop();
    _updateAndEmitSnap(_updateState());
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _updateAndEmitSnap(_updateState());
  }

  // Playlist functions

  /// creates a playlist from a list of tracks, overriding previous contents
  Future<void> initPlaylistFrom(List<TrackItem> tracks) async {
    _playlist.initFromList(tracks);
    await _updatePlayerWithCurrentTrack();
    _player.play();
    _updateAndEmitSnap(_updateState());
    _emitPlaylistSnap();
    _emitPlaylist();
    _emitCurrentTrack(_playlist.current);
  }

  /// creates a playlist from a list of tracks and sets the specified track as current
Future<void> initPlaylistFromWithTrack(List<TrackItem> tracks, TrackItem selectedTrack) async {
  _playlist.initFromList(tracks);
  
  // Find the index of the selected track
  final selectedIndex = tracks.indexWhere((track) => track.trackId == selectedTrack.trackId);
  
  if (selectedIndex != -1) {
    // Set the playlist index to the selected track
    _playlist.setIndex(selectedIndex);
  } else {
    // If track not found, fall back to first track (index 0)
    print('Warning: Selected track ${selectedTrack.trackName} not found in playlist, defaulting to first track');
    _playlist.setIndex(0);
  }
  
  await _updatePlayerWithCurrentTrack();
  _player.play();
  _updateAndEmitSnap(_updateState());
  _emitPlaylistSnap();
  _emitPlaylist();
  _emitCurrentTrack(_playlist.current);
}

  Future<void> nextTrack() async {
    print("PlayerEngine: nextTrack()");
    _playlist.next();
    await _updatePlayerWithCurrentTrack();
    _player.play();
    _updateAndEmitSnap(_updateState());
    _emitPlaylistSnap();
    _emitPlaylist();
    _emitCurrentTrack(_playlist.current);
  }

  Future<void> previousTrack() async {
    print("PlayerEngine: previousTrack()");
    _playlist.previous();
    await _updatePlayerWithCurrentTrack();
    _player.play();
    // await seek(Duration.zero);
    _updateAndEmitSnap(_updateState());
    _emitPlaylistSnap();
    _emitPlaylist();
    _emitCurrentTrack(_playlist.current);
  }

  Future<void> addToPlaylist(TrackItem item) async {
    _playlist.addToEnd(item);
    if (_playlist.length == 1) {
      await _updatePlayerWithCurrentTrack();
    }
    _updateAndEmitSnap(_updateState());
    _emitPlaylistSnap();
    _emitPlaylist();
    _emitCurrentTrack(_playlist.current);
  }

  // Utils
  Future<void> _updatePlayerWithCurrentTrack() async {
    await _player.stop();
    final track = _playlist.current;
    final wavUrl = track?.wavUrl ?? '';
    if (track != null && wavUrl.isNotEmpty) {
      print("setting audio source: ${track.trackName ?? 'Unknown'}");
      print("PlayerEngine: setAudioSource($wavUrl) url not empty");
      final uri = AudioSource.uri(Uri.parse(wavUrl));
      try {
        Duration? duration = await _player.setAudioSource(uri);
        await _player.load();
        // Success! The function completed without throwing an exception
        // duration will be non-null if the audio source was loaded successfully
        // duration will be null if preload was false or duration is unavailable
        print(
            'SET AUDIO SOURCE OK: Successfully set audio source ${track.trackName ?? 'Unknown'}. Duration: $duration; url: $wavUrl');

        // Small delay to ensure the audio source is fully processed
        // await Future.delayed(const Duration(milliseconds: 100));
      } on PlayerException catch (e) {
        // Handle audio loading errors
        print(
            'SET AUDIO SOURCE ERROR: Failed to load audio source: ${e.message}');
      } on PlayerInterruptedException catch (e) {
        // Handle interruption errors
        print(
            'SET AUDIO SOURCE ERROR: Audio source loading was interrupted: ${e.message}');
      } catch (e) {
        // Handle any other unexpected errors
        print('SET AUDIO SOURCE ERROR: Unexpected error: $e');
      }
      print(
          "PlayerEngine: setAudioSource($wavUrl) url set successfully");
    } else {
      print(
          "PlayerEngine: setAudioSource() - EMPTY TRACK URL FOR ${track?.trackName ?? 'Unknown'}");
    }
  }

  EngineSnapshot _updateState() {
    return _snap.copyWith(
      state: mapPlayerState(_player.playerState),
      position: _player.position,
      duration: _player.duration ?? _snap.duration,
    );
  }

  void _updateAndEmitSnap(EngineSnapshot snap) {
    // UPDATES and then emits current snapshot
    _snap = snap;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snap);
      // debugPrintSnapshot();
    } else {
      print("PlayerEngine: emit snapshot - controller is closed");
      // TODO error handling
    }
  }

  void _emitPlaylistSnap() {
    var isEmpty = _playlist.isEmpty;
    var hasNext = _playlist.hasNext();
    var hasPrev = _playlist.hasPrev();
    final snap = PlaylistSnapshot(
      isEmpty: isEmpty,
      hasNext: hasNext,
      hasPrev: hasPrev,
    );
    // UPDATES and then emits current playlist snapshot
    if (!_playlistSnapController.isClosed) {
      _playlistSnapController.add(snap);
      print(
          "PlayerEngine: emit playlist snapshot: isEmpty=${snap.isEmpty}, hasNext=${snap.hasNext}, hasPrev=${snap.hasPrev}");
    } else {
      print("PlayerEngine: emit playlist snapshot - controller is closed");
      // TODO error handling
    }
  }

  void _emitPlaylist() {
    print("PlayerEngine: emitPlaylist()");
    if (!_playlistController.isClosed) {
      _playlistController.add(_playlist);
      print("Playlist current track: $currentTrack");
      print("Playlist items: ${_playlist.items}");
    } else {
      print("PlayerEngine: emitPlaylist() - controller is closed");
      // TODO error handling
    }
  }

  void _emitCurrentTrack(TrackItem? track) {
    if (track != null) {
      print("PlayerEngine: emitCurrentTrack(): $track");
      _currentTrack.add(track);
    } else {
      print("error: PlayerEngine: emitCurrentTrack(): track is null");
    }
  }

  void debugPrintSnapshot() {
    print("PlayerEngine: emit():");
    print("  state: ${_snap.state}");
    print("  position: ${_snap.position}");
    print("  duration: ${_snap.duration}");
    print("  errorCode: ${_snap.errorCode}");
  }

  void _startTicker() {
    _snapshotTicker?.cancel();
    _snapshotTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final pos = _player.position;
      final dur = _player.duration ?? Duration.zero;
      final state = mapPlayerState(_player.playerState);
      _updateAndEmitSnap(_snap.copyWith(
        position: pos,
        duration: dur,
        state: state,
      ));
    });
  }

  void dispose() async {
    _snapshotTicker?.cancel();
    await _player.dispose();
    await _snapshotController.close();
  }
}

EngineState mapPlayerState(PlayerState s) {
  if (s.processingState == ProcessingState.loading ||
      s.processingState == ProcessingState.buffering) {
    return EngineState.buffering;
  }
  switch (s.processingState) {
    case ProcessingState.idle:
      return EngineState.idle;
    case ProcessingState.ready:
      return s.playing ? EngineState.playing : EngineState.paused;
    case ProcessingState.completed:
      return EngineState.ended;
    default:
      return EngineState.error;
  }
}

/// ---------------------------------------------------------------------------
/// Snapshot emitted ~4–8 times/second for the bridge widget → FFAppState.
/// ---------------------------------------------------------------------------
class EngineSnapshot {
  final EngineState state;
  final Duration position;
  final Duration duration;
  final String?
      errorCode; // e.g., "network", "403", "timeout", "decode", "insufficient_credits"

  const EngineSnapshot({
    required this.state,
    required this.position,
    required this.duration,
    required this.errorCode,
  });

  EngineSnapshot copyWith({
    EngineState? state,
    String? trackId,
    Duration? position,
    Duration? duration,
    String? errorCode,
  }) {
    return EngineSnapshot(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      errorCode: errorCode ?? this.errorCode,
    );
  }

  static EngineSnapshot initial() => const EngineSnapshot(
        state: EngineState.idle,
        position: Duration.zero,
        duration: Duration.zero,
        errorCode: null,
      );

  Map<String, dynamic> toMap() => {
        'state': state.name,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'errorCode': errorCode,
      };
}

class Playlist<T> {
  final List<T> _items = [];
  int _index = 0;

  List<T> get items => List.unmodifiable(_items);
  int get index => _index;
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;
  T? get current =>
      _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  void clear() {
    _items.clear();
    _index = 0;
  }

  void initFromList(List<T> items) {
    _items.clear();
    _items.addAll(items);
    _index = 0;
  }

  void add(T item) {
    _items.add(item);
    if (_items.length == 1) _index = 0;
  }

  void insertNext(T item) {
    if (_items.isEmpty) {
      _items.add(item);
      _index = 0;
    } else {
      _items.insert((_index + 1).clamp(0, _items.length), item);
    }
  }

  void addToEnd(T item) {
    _items.add(item);
    if (_items.length == 1) _index = 0;
  }

  void setIndex(int idx) {
    if (_items.isEmpty) {
      _index = 0;
    } else {
      _index = idx.clamp(0, _items.length - 1);
    }
  }

  void next() {
    if (_items.isEmpty) return;
    if (_index < _items.length - 1) {
      setIndex(_index + 1);
    }
  }

  void previous() {
    if (_items.isEmpty) return;
    if (_index > 0) {
      setIndex(_index - 1);
    }
  }

  bool hasNext() {
    return _index < _items.length - 1;
  }

  bool hasPrev() {
    return _index > 0;
  }
}

/// AudioPlaylist: Inherits from Playlist and updates JustAudio player on current track change
class AudioPlaylist extends Playlist<TrackItem> {
  final AudioPlayer player;

  AudioPlaylist(this.player);

  Future<void> _updatePlayerWithCurrentTrack() async {
    // final track = current;
    // if (track != null && track.wavUrl.isNotEmpty) {
    //   await player.setAudioSource(AudioSource.uri(Uri.parse(track.wavUrl)));
    // } else {
    //   print("EMPTY TRACK URL FOR ${track?.trackName}");
    // }
  }

  @override
  void setIndex(int idx) {
    super.setIndex(idx);
    _updatePlayerWithCurrentTrack();
  }

  @override
  void next() {
    final oldIndex = index;
    super.next();
    if (oldIndex != index) {
      _updatePlayerWithCurrentTrack();
    }
  }

  @override
  void previous() {
    final oldIndex = index;
    super.previous();
    if (oldIndex != index) {
      _updatePlayerWithCurrentTrack();
    }
  }

  @override
  void initFromList(List<TrackItem> items) {
    super.initFromList(items);
    _updatePlayerWithCurrentTrack();
  }

  @override
  void add(TrackItem item) {
    final wasEmpty = isEmpty;
    super.add(item);
    if (wasEmpty) {
      _updatePlayerWithCurrentTrack();
    }
  }

  @override
  void insertNext(TrackItem item) {
    final wasEmpty = isEmpty;
    super.insertNext(item);
    if (wasEmpty || index == length - 1) {
      _updatePlayerWithCurrentTrack();
    }
  }

  @override
  void clear() {
    super.clear();
    unawaited(player.stop());
  }

  @override
  void addToEnd(TrackItem item) {
    super.addToEnd(item);
    _updatePlayerWithCurrentTrack();
  }
}
