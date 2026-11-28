import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/country_names_de.dart';
import '../../core/providers.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/models/iptv_channel.dart';
import '../../data/services/enigma2_service.dart';
import '../../data/services/tv_stream_session.dart';
import '../../l10n/l10n.dart';
import '../home/connection_chain.dart' show ConnectionChain, LinkState, LinkView;
import '../settings/settings_screen.dart';
import '../settings/tv_settings_screen.dart';
import '../shared/program_number_dialog.dart';
import 'iptv_browse_screen.dart';
import 'iptv_providers.dart';
import 'tv_channel_move.dart';
import 'tv_epg_screen.dart';
import 'tv_guide_screen.dart';
import 'tv_player.dart';
import 'tv_programme_actions.dart';
import 'tv_providers.dart';
import 'tv_recordings_screen.dart';
import 'tv_reminder_providers.dart';
import 'tv_signal_badge.dart';
import 'tv_timers_screen.dart';
import 'tv_timeshift.dart';
import 'tv_tuning_overlay.dart';
import 'tv_widgets.dart';

/// TV: live TV from the Enigma2 receiver (GigaBlue etc.) and Internet-TV
/// (free streams from the iptv-org catalogue), full screen. One of Home
/// System's parts, opened from the launcher - Back or Home leave it, which
/// stops the picture.
///
/// Two kinds of lists, each with its own numbers: the receiver's bouquets
/// and the Internet-TV favorites ([TvListKind]) - the channel list's chips
/// switch between them, the digits and channel keys work in the one open.
/// Without a receiver TV runs on Internet-TV alone.
///
/// Remote: up/down or OK open the channel list (OK there plays the marked
/// channel, right opens the programme guide at it, left switches the
/// bouquet), the channel keys and ⏪/⏩ switch straight away, digits pick a
/// channel by number, Info the programme guide, the options key a menu,
/// play/pause stops and resumes. All assignable keys: RemoteKeys.
/// With timeshift on (Einstellungen → TV → Aufnahmen & Timeshift) the
/// receiver's channels pause and rewind instead (TvTimeshiftPlayer.handleKey);
/// ⏺ records the programme on air by the receiver.
class TvScreen extends ConsumerStatefulWidget {
  const TvScreen({super.key, this.startServiceRef});

  /// Start with this receiver channel (a reminder) instead of the last one.
  final String? startServiceRef;

  @override
  ConsumerState<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends ConsumerState<TvScreen> {
  final _focus = FocusNode(debugLabel: 'tv');
  TvPlayer? _player;

  /// The receiver's channel on air - or [_iptv], never both.
  E2Channel? _current;

  /// The Internet-TV channel on air.
  IptvChannel? _iptv;

  /// The last channel was started (once both settings were loaded).
  bool _started = false;

  /// TV is opening: the first channel isn't chosen yet (the tuning
  /// animation shows meanwhile).
  bool _opening = true;

  /// A short note in the middle ("no programme guide for Internet-TV").
  String? _note;
  Timer? _noteTimer;
  String? _error;
  bool _loading = false;
  bool _stopped = false;
  int _generation = 0;

  bool _infoVisible = false;

  /// The banner looks ahead: 0 = now and next, 1.. = the programmes after
  /// that on this channel (→ / ← in the picture).
  int _bannerAhead = 0;
  Timer? _infoTimer;
  bool _listVisible = false;

  String _digits = '';
  Timer? _digitTimer;

  /// "Als Nächstes": the programme announced, and which one was already.
  E2Event? _nextUp;
  String? _nextUpShownFor;
  Timer? _nextUpCheck;
  Timer? _nextUpHide;

  late final TvOpenNotifier _open = ref.read(tvOpenProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Timeshift's settings loaded before the first channel starts.
    ref.read(tvTimeshiftProvider);
    ref.read(tvTimeshiftMemoryProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open.set(true);
      _maybeStart();
    });
    _nextUpCheck = Timer.periodic(const Duration(seconds: 15), (_) => _checkNextUp());
  }

  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tuning animation's logo decoded now - not at the first switch.
    if (!_precached) {
      _precached = true;
      unawaited(TvTuningOverlay.precache(context));
    }
  }

  /// A reminder's channel while TV is open: back to the picture (closing
  /// the guide, lists, menus over it) and switch.
  Future<void> _zapTo(String serviceRef) async {
    if (!_receiverReady) return;
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).popUntil((r) => r == route);
    final List<E2Channel> channels;
    try {
      channels = await ref.read(tvChannelsProvider.future);
    } catch (_) {
      return;
    }
    final key = serviceKey(serviceRef);
    final channel = channels.where((c) => serviceKey(c.ref) == key).firstOrNull;
    if (!mounted || channel == null) return;
    if (_listVisible) setState(() => _listVisible = false);
    _focus.requestFocus();
    if (channel.ref != _current?.ref || _iptv != null) await _tune(channel);
  }

  @override
  void dispose() {
    // After the frame: providers can't change while the tree is torn down.
    final open = _open;
    Future.microtask(() => open.set(false));
    _generation++;
    _player?.dispose();
    _session?.close();
    _infoTimer?.cancel();
    _digitTimer?.cancel();
    _nextUpCheck?.cancel();
    _nextUpHide?.cancel();
    _noteTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  Enigma2Config? get _config => ref.read(enigma2ConfigProvider);

  bool get _receiverReady => _config?.configured ?? false;

  /// The list the digits and channel keys work in: the one last chosen -
  /// Internet-TV's if there's no receiver, the receiver's if Internet-TV
  /// is off.
  TvListKind get _listKind {
    final iptv = ref.read(iptvProvider);
    if (iptv == null || !iptv.enabled) return TvListKind.receiver;
    if (!_receiverReady) return TvListKind.iptv;
    return iptv.list;
  }

  List<IptvChannel> get _iptvFavorites => ref.read(iptvProvider)?.favorites ?? const [];

  /// Once the receiver's and Internet-TV's settings are loaded: the fixed
  /// start channel (Einstellungen → TV), else the last list's last channel.
  Future<void> _maybeStart() async {
    if (_started || !mounted) return;
    final config = _config;
    final iptv = ref.read(iptvProvider);
    if (config == null || iptv == null) return; // the listeners in build call again
    _started = true;
    try {
      await _startFirst(config, iptv);
    } finally {
      if (mounted && _opening) setState(() => _opening = false);
    }
  }

  Future<void> _startFirst(Enigma2Config config, IptvState iptv) async {
    final fixed = config.configured ? await ref.read(settingsRepositoryProvider).getTvStartChannel() : null;
    final last = iptv.enabled ? await ref.read(iptvRepositoryProvider).getLastChannel() : null;
    if (!mounted) return;
    final iptvFirst = iptv.enabled &&
        fixed == null &&
        widget.startServiceRef == null &&
        (iptv.favorites.isNotEmpty || last != null) &&
        (!config.configured || iptv.list == TvListKind.iptv);
    if (iptvFirst) {
      // The favorite's own entry if it is one (its streams are kept fresh).
      final channel = iptv.favorites.where((c) => c.id == last?.id).firstOrNull ?? last ?? iptv.favorites.first;
      await _tuneIptv(channel);
    } else if (config.configured) {
      await _startLastChannel();
    }
  }

  Future<void> _startLastChannel() async {
    final config = _config;
    if (config == null || !config.configured) return;
    final List<E2Channel> channels;
    try {
      channels = await ref.read(tvChannelsProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted || channels.isEmpty) return;
    final repo = ref.read(settingsRepositoryProvider);
    // A fixed start channel (Einstellungen → TV), else the last one.
    final fixed = await repo.getTvStartChannel();
    final last = await repo.getTvLastChannel();
    // A reminder's channel first.
    final wanted = widget.startServiceRef == null ? null : serviceKey(widget.startServiceRef!);
    final channel = channels.where((c) => wanted != null && serviceKey(c.ref) == wanted).firstOrNull ??
        channels.where((c) => c.ref == fixed).firstOrNull ??
        channels.where((c) => c.ref == last).firstOrNull ??
        channels.first;
    await _tune(channel);
  }

  /// The connection setup in the banner (App — Receiver — Sender), like
  /// Radio's; null once the picture runs.
  LinkView? _link;

  void _setLink(LinkState receiver, LinkState station, String message) =>
      setState(() => _link = LinkView.tv(receiver: receiver, station: station, message: message));

  /// The stream of the channel on air, through [TvStreamSession].
  TvStreamSession? _session;

  /// Switching channels as fast as the receiver allows - one connection to
  /// it per channel ([TvStreamSession]): the player gets the stream as soon
  /// as the picture comes descrambled. In standby the receiver descrambles
  /// encrypted channels itself and is never switched (it would keep the
  /// tuner); while it's on, it's switched to an encrypted channel (or one on
  /// another band) if Einstellungen → TV allow it.
  Future<void> _tune(E2Channel channel) async {
    final config = _config;
    final service = ref.read(enigma2ServiceProvider);
    if (config == null || service == null) return;
    final t = context.l10n;
    final generation = ++_generation;
    bool stale() => !mounted || generation != _generation;
    final clock = Stopwatch()..start();
    void mark(String what) => debugPrint('TV ${channel.name}: $what nach ${clock.elapsedMilliseconds} ms');
    final oldPlayer = _player, oldSession = _session;
    setState(() {
      _current = channel;
      _iptv = null;
      _player = null;
      _session = null;
      _loading = true;
      _error = null;
      _stopped = false;
      _link = LinkView.tv(receiver: LinkState.active, station: LinkState.pending, message: t.tvLinkConnecting);
    });
    _showInfo();
    _checkNextUp();
    // The old picture goes in the background - it mustn't hold up the new one.
    if (oldPlayer != null) unawaited(oldPlayer.dispose());
    if (oldSession != null) unawaited(oldSession.close());
    unawaited(ref.read(settingsRepositoryProvider).setTvLastChannel(channel.ref));
    unawaited(ref.read(iptvProvider.notifier).setList(TvListKind.receiver));

    final known = ref.read(tvStreamKnowledgeProvider);
    // Standby or on decides whether the receiver may be switched - asked
    // while the stream connects.
    final boxState = service.state();
    final session = await TvStreamSession.open(config.streamUri(channel.ref), config.authHeaders);
    if (stale()) {
      unawaited(session.close());
      return;
    }
    _session = session;
    _watchStreamCuts(session, channel, stale);
    // Timeshift (Einstellungen → TV): fills behind the scenes.
    final player = withTvTimeshift(ref, TvPlayer(session.uri, const {}), session);
    final starting = player.start(timeout: const Duration(seconds: 25));
    Future<void> giveUp(String message, {required bool atReceiver}) async {
      starting.ignore();
      unawaited(player.dispose());
      if (stale()) return;
      _fail(message, atReceiver: atReceiver);
    }

    final box = await boxState;
    if (stale()) return giveUp('', atReceiver: false);
    // In standby the receiver holds no channel - unless it was switched over
    // the network: then it keeps that channel's tuner, and with one satellite
    // cable every other band stays blocked. Let go of it.
    if (box.standby && box.live != null && _refKey(box.live) != _refKey(channel.ref)) {
      mark('Receiver hält ${box.live} - freigeben');
      try {
        await service.release();
      } catch (_) {}
      if (stale()) return giveUp('', atReceiver: false);
      session.reopen();
    }
    // Switching the receiver only while it's on (its own picture changes
    // with it) and Einstellungen → TV allow it - never in standby, it
    // would keep the tuner afterwards.
    final mayZap = !box.standby && ref.read(tvZapEncryptedProvider);
    var switched = false;
    Future<String?> zap(String why) async {
      switched = true;
      _setLink(LinkState.active, LinkState.pending, t.tvLinkZapping(why));
      if (_refKey(box.live) == _refKey(channel.ref)) return null;
      try {
        await service.zap(channel.ref);
        mark('Receiver umgeschaltet');
        return null;
      } catch (e) {
        return '$e';
      }
    }

    // Known to be encrypted: switched right away, while the stream connects.
    if (mayZap && known.isEncrypted(channel.ref)) {
      final problem = await zap(t.tvReasonEncrypted);
      if (stale()) return giveUp('', atReceiver: false);
      if (problem != null) return giveUp(problem, atReceiver: true);
    } else {
      _setLink(LinkState.done, LinkState.active, t.tvLinkLoadingPicture);
    }
    // No stream at all - no tuner free for its band: the receiver to it (it
    // shows another band itself), the session keeps asking meanwhile.
    unawaited(session.refused.then((_) async {
      if (stale() || switched || !mayZap) return;
      await zap(t.tvReasonNoFreeTuner);
      if (!stale()) session.reopen();
    }));

    final verdict = await session.verdict;
    mark('Stream: ${verdict.name}');
    if (stale()) return giveUp('', atReceiver: false);
    if (verdict == StreamScrambling.scrambled) {
      known.markEncrypted(channel.ref);
      if (mayZap && !switched) {
        final problem = await zap(t.tvReasonEncrypted);
        if (stale()) return giveUp('', atReceiver: false);
        if (problem != null) return giveUp(problem, atReceiver: true);
      } else if (!switched) {
        // In standby the receiver's card / CI module is free and descrambles
        // the stream itself, a moment later.
        _setLink(LinkState.active, LinkState.pending, t.tvLinkDescrambling);
      }
      // On this connection, or on a new one if the receiver keeps serving
      // the old one scrambled.
      var clear = await _clearWithin(session, Duration(milliseconds: box.standby ? 6000 : 2500));
      if (!clear && !stale()) {
        mark('neu verbinden');
        session.reopen();
        clear = await _clearWithin(session, const Duration(seconds: 6));
      }
      if (stale()) return giveUp('', atReceiver: false);
      if (!clear) {
        return giveUp(
          !box.standby && !mayZap
              ? t.tvErrorEncryptedReceiverBusy(channel.name)
              : t.tvErrorStillEncrypted(channel.name),
          atReceiver: true,
        );
      }
      mark('entschlüsselt');
    } else if (verdict == StreamScrambling.unknown) {
      return giveUp(
        box.standby || mayZap
            ? t.tvErrorNoTunerCableBusy(channel.name)
            : t.tvErrorNoTunerReceiverBusy(channel.name),
        atReceiver: true,
      );
    }
    _setLink(LinkState.done, LinkState.active, t.tvLinkLoadingPicture);
    try {
      await starting;
      mark('Bild');
      if (stale()) {
        unawaited(player.dispose());
        return;
      }
      setState(() {
        _player = player;
        _loading = false;
      });
      _setLink(LinkState.done, LinkState.done, t.tvLinkPlaying);
      // All green for a moment, then the programme info again.
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (stale()) return;
        setState(() => _link = null);
        _showInfo();
      });
    } catch (e) {
      mark('kein Bild: $e');
      unawaited(player.dispose());
      if (stale()) return;
      _fail(t.tvErrorNoPicture(channel.name), atReceiver: false);
    }
  }

  /// An Internet-TV channel: straight from the internet, no receiver -
  /// its streams in turn (best first) until one shows a picture.
  Future<void> _tuneIptv(IptvChannel channel) async {
    final t = context.l10n;
    final generation = ++_generation;
    bool stale() => !mounted || generation != _generation;
    final oldPlayer = _player, oldSession = _session;
    setState(() {
      _iptv = channel;
      _current = null;
      _player = null;
      _session = null;
      _loading = true;
      _error = null;
      _stopped = false;
      _nextUp = null;
      _link = LinkView.internet(connection: LinkState.active, station: LinkState.pending, message: t.iptvLinkConnecting);
    });
    _showInfo();
    if (oldPlayer != null) unawaited(oldPlayer.dispose());
    if (oldSession != null) unawaited(oldSession.close());
    final notifier = ref.read(iptvProvider.notifier);
    unawaited(notifier.setLastChannel(channel));
    unawaited(notifier.setList(TvListKind.iptv));

    // At most three: a dead server takes its whole timeout.
    final streams = channel.streams.take(3).toList();
    for (final (i, stream) in streams.indexed) {
      if (i > 0) {
        setState(() => _link = LinkView.internet(
              connection: LinkState.retrying,
              station: LinkState.pending,
              message: t.iptvLinkTryingOther(i + 1, streams.length),
            ));
      }
      final Uri uri;
      try {
        uri = Uri.parse(stream.url);
      } catch (_) {
        continue;
      }
      final player = TvPlayer(uri, stream.headers, format: stream.format, broadcast: false);
      try {
        await player.start(timeout: const Duration(seconds: 15));
      } catch (e) {
        debugPrint('Internet-TV ${channel.name} (${stream.url}): $e');
        unawaited(player.dispose());
        if (stale()) return;
        continue;
      }
      if (stale()) {
        unawaited(player.dispose());
        return;
      }
      setState(() {
        _player = player;
        _loading = false;
        _link = LinkView.internet(connection: LinkState.done, station: LinkState.done, message: t.tvLinkPlaying);
      });
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (stale()) return;
        setState(() => _link = null);
        _showInfo();
      });
      return;
    }
    if (stale()) return;
    _fail(t.iptvErrorNoPicture(channel.name), atReceiver: false);
  }

  /// The receiver may end a running stream when a recording needs the
  /// tuner ("Streaming bei Aufnahmen beenden"): a note while it's fetched
  /// anew, the error if it doesn't come back.
  void _watchStreamCuts(TvStreamSession session, E2Channel channel, bool Function() stale) {
    session.interruptions.addListener(() {
      if (!stale()) _showNote(context.l10n.tvRecStreamCut);
    });
    unawaited(session.lost.then((_) {
      if (mounted && !stale()) _fail(context.l10n.tvRecStreamLost(channel.name), atReceiver: true);
    }));
  }

  /// The record key / the menu: the programme on air recorded by the
  /// receiver (or its timer deleted).
  Future<void> _recordCurrent() async {
    final channel = _current;
    if (channel == null || _iptv != null) {
      _showNote(context.l10n.tvRecOnlyReceiver);
      return;
    }
    final now = nowNextFor(ref.read(tvNowNextProvider).value ?? const {}, channel, DateTime.now()).now;
    if (now == null) {
      _showNote(context.l10n.tvNoProgramInfo);
      return;
    }
    await toggleTvRecording(context, ref, channel: channel, event: now);
  }

  Future<void> _openRecordings() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TvRecordingsScreen()));

  static Future<bool> _clearWithin(TvStreamSession session, Duration limit) async {
    try {
      await session.clear.timeout(limit);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _fail(String message, {required bool atReceiver}) {
    _infoTimer?.cancel();
    setState(() {
      _loading = false;
      _error = message;
      _infoVisible = true;
      _link = _iptv != null
          ? LinkView.internet(connection: LinkState.done, station: LinkState.failed, message: message)
          : LinkView.tv(
              receiver: atReceiver ? LinkState.failed : LinkState.done,
              station: atReceiver ? LinkState.pending : LinkState.failed,
              message: message,
            );
    });
  }

  static String _refKey(String? serviceRef) => (serviceRef ?? '').replaceAll(RegExp(r':+$'), '').toUpperCase();

  /// The next / previous channel of the list open (receiver or
  /// Internet-TV).
  Future<void> _step(int direction) async {
    if (_listKind == TvListKind.iptv) {
      final favorites = _iptvFavorites;
      if (favorites.isEmpty) return;
      final i = favorites.indexWhere((c) => c.id == _iptv?.id);
      // Not in the list (played from the catalogue): from its start.
      final next = i < 0 ? (direction > 0 ? 0 : favorites.length - 1) : (i + direction) % favorites.length;
      await _tuneIptv(favorites[next]);
      return;
    }
    final channels = ref.read(tvChannelsProvider).value ?? const [];
    if (channels.isEmpty) return;
    final i = channels.indexWhere((c) => c.ref == _current?.ref);
    await _tune(channels[(i + direction) % channels.length]);
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (_stopped || player == null) {
      final c = _current;
      final iptv = _iptv;
      if (c != null) await _tune(c);
      if (iptv != null) await _tuneIptv(iptv);
      return;
    }
    _generation++;
    final session = _session;
    setState(() {
      _player = null;
      _session = null;
      _stopped = true;
    });
    await player.dispose();
    await session?.close();
  }

  /// The channel's sound tracks to choose from (☰ → Tonspur, the remote's
  /// audio key, A on the keyboard).
  Future<void> _chooseAudio() async {
    final player = _player;
    if (player == null) return;
    final tracks = player.info.value.audio;
    if (tracks.isEmpty) return;
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.l10n.tvAudioTrack),
        children: [
          for (final t in tracks)
            TvRow(
              autofocus: t.selected,
              selected: t.selected,
              onTap: () => Navigator.of(context).pop(t.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Icon(t.selected ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: t.selected ? brandGreen : Colors.white54),
                    const SizedBox(width: 14),
                    Text(t.label, style: const TextStyle(fontSize: 18)),
                    if (t.details != null) ...[
                      const SizedBox(width: 12),
                      Text(t.details!, style: const TextStyle(color: Colors.white54, fontSize: 15)),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (id == null || !mounted || _player != player) return;
    await player.selectAudio(id);
    _showInfo();
  }

  /// The options key: programme guide, the channel's programmes, sound track.
  Future<void> _openOptions() async {
    if (_iptv != null) return _openIptvOptions(_iptv!);
    final hasTracks = (_player?.info.value.audio.length ?? 0) > 1;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(_current?.name ?? 'TV'),
        children: [
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('guide'),
            child: ListTile(leading: const Icon(Icons.view_timeline_outlined), title: Text(context.l10n.tvGuide)),
          ),
          TvRow(
            onTap: () => Navigator.of(context).pop('epg'),
            child: ListTile(
              leading: const Icon(Icons.event_note),
              title: Text(switch (_current?.name) {
                final name? => context.l10n.tvAllProgramsOf(name),
                null => context.l10n.tvAllProgramsOfThisChannel,
              }),
            ),
          ),
          if (hasTracks)
            TvRow(
              onTap: () => Navigator.of(context).pop('audio'),
              child: ListTile(
                leading: const Icon(Icons.audiotrack),
                title: Text(context.l10n.tvAudioTrack),
                subtitle: Text(_player?.info.value.selectedAudio?.label ?? ''),
              ),
            ),
          if (_player case final TvTimeshiftPlayer ts when ts.state.value.shifted)
            TvRow(
              onTap: () => Navigator.of(context).pop('live'),
              child: ListTile(leading: const Icon(Icons.skip_next), title: Text(context.l10n.tvShiftBackToLive)),
            ),
          if (_current != null)
            TvRow(
              onTap: () => Navigator.of(context).pop('record'),
              child: ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: tvRecordRed),
                title: Text(context.l10n.tvRecRecordNow),
              ),
            ),
          TvRow(
            onTap: () => Navigator.of(context).pop('recordings'),
            child: ListTile(leading: const Icon(Icons.video_library_outlined), title: Text(context.l10n.tvRecRecordingsTitle)),
          ),
          TvRow(
            onTap: () => Navigator.of(context).pop('timers'),
            child: ListTile(leading: const Icon(Icons.schedule), title: Text(context.l10n.tvRecTimersTitle)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'guide') await _openGuide(_current);
    if (choice == 'epg') _openEpg();
    if (choice == 'audio') await _chooseAudio();
    if (choice == 'live' && _player is TvTimeshiftPlayer) await (_player! as TvTimeshiftPlayer).goLive();
    if (choice == 'record') await _recordCurrent();
    if (choice == 'recordings') await _openRecordings();
    if (choice == 'timers' && mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TvTimersScreen()));
    }
  }

  /// The options key on an Internet-TV channel: into / out of the
  /// favorites, find channels, sound track.
  Future<void> _openIptvOptions(IptvChannel channel) async {
    final hasTracks = (_player?.info.value.audio.length ?? 0) > 1;
    final favorite = ref.read(iptvProvider)?.isFavorite(channel.id) ?? false;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(channel.name),
        children: [
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('favorite'),
            child: ListTile(
              leading: Icon(favorite ? Icons.star : Icons.star_border),
              title: Text(favorite ? context.l10n.iptvRemoveFavorite : context.l10n.iptvAddFavorite),
            ),
          ),
          TvRow(
            onTap: () => Navigator.of(context).pop('browse'),
            child: ListTile(leading: const Icon(Icons.travel_explore), title: Text(context.l10n.iptvBrowseTitle)),
          ),
          if (hasTracks)
            TvRow(
              onTap: () => Navigator.of(context).pop('audio'),
              child: ListTile(
                leading: const Icon(Icons.audiotrack),
                title: Text(context.l10n.tvAudioTrack),
                subtitle: Text(_player?.info.value.selectedAudio?.label ?? ''),
              ),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'favorite') await _toggleIptvFavorite(channel);
    if (choice == 'browse') await _openBrowse();
    if (choice == 'audio') await _chooseAudio();
  }

  Future<void> _toggleIptvFavorite(IptvChannel channel) async {
    final notifier = ref.read(iptvProvider.notifier);
    final t = context.l10n;
    if (ref.read(iptvProvider)?.isFavorite(channel.id) ?? false) {
      await notifier.removeFavorite(channel.id);
      _showNote(t.iptvRemoved(channel.name));
    } else {
      final number = await notifier.addFavorite(channel);
      _showNote(t.iptvAddedAsNumber(channel.name, number));
    }
    if (mounted) _showInfo();
  }

  /// Internet-TV's catalogue; the channel picked there goes on air.
  Future<void> _openBrowse() async {
    // Internet-TV switched off and chosen anyway (the setup screen): on.
    if (!(ref.read(iptvProvider)?.enabled ?? true)) await ref.read(iptvProvider.notifier).setEnabled(true);
    if (!mounted) return;
    final picked = await Navigator.of(context).push<IptvChannel>(
      MaterialPageRoute(builder: (_) => IptvBrowseScreen(current: _iptv)),
    );
    if (!mounted) return;
    if (_listVisible) {
      setState(() => _listVisible = false);
    }
    if (picked != null && picked.id != _iptv?.id) unawaited(_tuneIptv(picked));
    // From the setup screen the player's Focus is only built now.
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_listVisible) _focus.requestFocus();
    });
  }

  void _showNote(String text) {
    _noteTimer?.cancel();
    setState(() => _note = text);
    _noteTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _note = null);
    });
  }

  /// The programme guide (all channels, time across) - starting on [start];
  /// the channel picked there goes on air.
  Future<void> _openGuide(E2Channel? start) async {
    // Internet-TV has none (iptv-org's streams come without EPG).
    if (!_receiverReady || (start == null && _iptv != null)) {
      _showNote(context.l10n.iptvNoGuide);
      return;
    }
    final picked = await Navigator.of(context).push<E2Channel>(
      MaterialPageRoute(builder: (_) => TvGuideScreen(start: start)),
    );
    if (!mounted || picked == null) return;
    if (_listVisible) {
      setState(() => _listVisible = false);
      _focus.requestFocus();
    }
    if (picked.ref != _current?.ref) unawaited(_tune(picked));
  }

  /// Shortly before the next programme on this channel starts (Einstellungen
  /// → TV → "Als Nächstes"), a note says what's coming - once per
  /// programme, for the set time.
  void _checkNextUp() {
    final settings = ref.read(tvNextUpProvider);
    final channel = _current;
    if (!mounted || !settings.enabled || channel == null) return;
    final epg = ref.read(tvNowNextProvider).value ?? const {};
    final now = DateTime.now();
    final next = nowNextFor(epg, channel, now).next;
    if (next == null) return;
    final key = '${channel.ref}@${next.begin.millisecondsSinceEpoch}';
    final until = next.begin.difference(now);
    if (key == _nextUpShownFor || until.isNegative || until > Duration(minutes: settings.leadMinutes)) return;
    _nextUpShownFor = key;
    _nextUpHide?.cancel();
    setState(() => _nextUp = next);
    _nextUpHide = Timer(Duration(seconds: settings.showSeconds), () {
      if (mounted) setState(() => _nextUp = null);
    });
  }

  void _showInfo({int ahead = 0}) {
    _infoTimer?.cancel();
    setState(() {
      _infoVisible = true;
      _bannerAhead = ahead;
    });
    // Looking ahead takes reading - a little longer.
    _infoTimer = Timer(Duration(seconds: ahead > 0 ? 10 : 6), () {
      if (mounted) {
        setState(() {
          _infoVisible = false;
          _bannerAhead = 0;
        });
      }
    });
  }

  /// A channel by its number - in the list open (the receiver's numbers or
  /// Internet-TV's own).
  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() => _digits = '$_digits$d');
    final iptv = _listKind == TvListKind.iptv;
    final channels = iptv ? const <E2Channel>[] : ref.read(tvChannelsProvider).value ?? const <E2Channel>[];
    final favorites = iptv ? _iptvFavorites : const <IptvChannel>[];
    final number = int.parse(_digits);
    // As soon as no other channel number can start with these digits.
    final done = _digits.length >= (iptv ? favorites.length : channels.length).toString().length;
    void go() {
      setState(() => _digits = '');
      if (iptv) {
        final c = IptvFavorites.byNumber(favorites, number);
        if (c != null) _tuneIptv(c);
        return;
      }
      final c = channels.where((c) => c.number == number).firstOrNull;
      if (c != null) _tune(c);
    }

    done ? go() : _digitTimer = Timer(const Duration(milliseconds: 1500), go);
  }

  void _openEpg() {
    final c = _current;
    if (c == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TvEpgScreen(channel: c)));
  }

  static final _digitKeys = {
    for (var i = 0; i <= 9; i++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): i,
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + i): i,
    },
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // The channel list is open but hasn't got the focus yet: the keys
    // mustn't switch channels behind it (Back/Esc still closes it).
    if (_listVisible) return key == LogicalKeyboardKey.escape ? KeyEventResult.ignored : KeyEventResult.handled;
    // Timeshift: pause, rewind, back to live (see TvTimeshiftPlayer).
    if (_player case final TvTimeshiftPlayer ts when _iptv == null && ts.handleKey(event)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.mediaRecord) {
      if (event is KeyDownEvent) unawaited(_recordCurrent());
      return KeyEventResult.handled;
    }
    // Up/down open the channel list - OK there plays the marked channel.
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) setState(() => _listVisible = true);
      return KeyEventResult.handled;
    }
    // The remote's channel keys (and ⏪/⏩) still switch straight away.
    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // The assignable keys (Einstellungen → Tasten der Fernbedienung).
    switch (ref.read(remoteKeysProvider).actionOf(key)) {
      case RemoteAction.channelList:
        setState(() => _listVisible = true);
        return KeyEventResult.handled;
      case RemoteAction.options:
        _openOptions();
        return KeyEventResult.handled;
      case RemoteAction.guide:
        _openGuide(_current);
        return KeyEventResult.handled;
      case RemoteAction.audio:
        _chooseAudio();
        return KeyEventResult.handled;
      case null:
    }
    // → in the picture: what's on later on this channel, one programme per
    // press; ← back to now. (Internet-TV has no programme - just the banner.)
    if (key == LogicalKeyboardKey.arrowRight) {
      // Straight to the next programme, then one further per press.
      _showInfo(ahead: _iptv == null ? (_infoVisible ? _bannerAhead + 1 : 1) : 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _showInfo(ahead: _bannerAhead > 0 ? _bannerAhead - 1 : 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause || key == LogicalKeyboardKey.mediaPlay || key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    final d = _digitKeys[key];
    if (d != null) {
      _digit(d);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onBack() {
    if (_listVisible) {
      setState(() => _listVisible = false);
      _focus.requestFocus();
    } else if (_infoVisible) {
      _infoTimer?.cancel();
      setState(() => _infoVisible = false);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tvZapRequestProvider, (_, request) {
      if (request != null) unawaited(_zapTo(request.$1));
    });
    // Set up (or changed) while TV is open: start with it.
    ref.listen(enigma2ConfigProvider, (previous, next) {
      if (next == null) return;
      if (!_started) {
        _maybeStart();
        return;
      }
      if (!next.configured) return;
      if (previous?.host != next.host || previous?.webPort != next.webPort || previous?.streamPort != next.streamPort) {
        ref.invalidate(tvBouquetsProvider);
        // Internet-TV on air stays on.
        if (_iptv == null) {
          _current = null;
          _startLastChannel();
        }
      }
    });
    ref.listen(iptvProvider, (previous, next) {
      if (previous == null && next != null) _maybeStart();
    });
    final config = ref.watch(enigma2ConfigProvider);
    final iptv = ref.watch(iptvProvider);
    // Now and next of the whole bouquet loaded from the start and kept
    // fresh - a channel switch shows what's on without waiting for it
    // (listened, not watched: its refreshes needn't rebuild the screen).
    ref.listen(tvNowNextProvider, (_, _) {});
    final player = _player;
    final hasChannel = _current != null || _iptv != null;
    // The start animation over the picture's place while a channel tunes.
    final tuning = player == null && _error == null && !_stopped && (_loading || (!hasChannel && _opening));
    // Neither a receiver nor Internet-TV favorites (nor a channel from the
    // catalogue on air): what TV can be, and the way to set it up.
    final notSetUp = config != null &&
        iptv != null &&
        !config.configured &&
        _iptv == null &&
        (!iptv.enabled || iptv.favorites.isEmpty);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: config == null || iptv == null
            ? const Center(child: CircularProgressIndicator())
            : notSetUp
                ? _NotSetUp(onInternetTv: _openBrowse)
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Focus(
                        focusNode: _focus,
                        autofocus: true,
                        onKeyEvent: _onKey,
                        // The mouse on the PC: click = channel list, right
                        // click = programme / sound track.
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _listVisible = true),
                          onSecondaryTap: _openOptions,
                          child: player != null ? player.view() : const SizedBox.expand(),
                        ),
                      ),
                      TvTuningOverlay(visible: tuning),
                      // Tuning and its errors show in the banner (the
                      // connection setup), the tuning animation above.
                      if ((_stopped || (_error != null && !hasChannel)) && !_listVisible)
                        Center(
                          child: _Message(
                            icon: _stopped ? Icons.pause_circle_outline : Icons.signal_wifi_bad,
                            text: _stopped ? context.l10n.tvPaused : _error!,
                          ),
                        ),
                      if (_note != null)
                        Positioned(
                          top: 40,
                          left: 0,
                          right: 0,
                          child: Center(child: _Message(icon: Icons.info_outline, text: _note!)),
                        ),
                      if (_digits.isNotEmpty)
                        Positioned(
                          top: 32,
                          right: 40,
                          child: Text(_digits,
                              style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 12)])),
                        ),
                      if (player case final TvTimeshiftPlayer ts when !_listVisible)
                        Positioned(top: 32, left: 40, child: TvTimeshiftIndicator(player: ts)),
                      if (_nextUp != null && !_listVisible)
                        Positioned(top: 32, right: 40, child: _NextUpNote(event: _nextUp!)),
                      if ((_infoVisible || _error != null || _link != null) && hasChannel && !_listVisible)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _iptv != null
                              ? _IptvInfoBanner(
                                  channel: _iptv!,
                                  number: iptv.numberOf(_iptv!.id),
                                  link: _stopped ? null : _link,
                                  player: player,
                                )
                              : _InfoBanner(
                                  config: config,
                                  channel: _current!,
                                  link: _stopped ? null : _link,
                                  player: player,
                                  ahead: _bannerAhead,
                                  onAheadLimit: (max) {
                                    if (_bannerAhead > max) setState(() => _bannerAhead = max);
                                  },
                                ),
                        ),
                      if (_listVisible)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: 620,
                          child: _ChannelList(
                            config: config,
                            kind: _listKind,
                            current: _current,
                            iptvCurrent: _iptv,
                            onPick: (c) {
                              setState(() => _listVisible = false);
                              _focus.requestFocus();
                              if (c.ref != _current?.ref) _tune(c);
                            },
                            onPickIptv: (c) {
                              setState(() => _listVisible = false);
                              _focus.requestFocus();
                              if (c.id != _iptv?.id) _tuneIptv(c);
                            },
                            onEpg: _openGuide,
                            onBrowse: _openBrowse,
                            onSettings: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const SettingsScreen(section: SettingsSection.tv)),
                            ),
                            onClose: () {
                              setState(() => _listVisible = false);
                              _focus.requestFocus();
                            },
                            onNote: (text) {
                              if (mounted) _showNote(text);
                            },
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 36),
          const SizedBox(width: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 20)),
          ),
        ],
      ),
    );
  }
}

/// "Als Nächstes": the next programme, a few minutes before it starts.
class _NextUpNote extends StatelessWidget {
  const _NextUpNote({required this.event});

  final E2Event event;

  @override
  Widget build(BuildContext context) {
    final minutes = event.begin.difference(DateTime.now()).inMinutes;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(20, 14, 22, 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(14),
        border: const Border(left: BorderSide(color: brandGreen, width: 5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(minutes <= 0 ? context.l10n.tvNextUpNow : context.l10n.tvNextUpInMinutes(minutes),
              style: const TextStyle(color: brandGreen, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${hhmm(event.begin)}  ${event.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          if (event.shortDescription.trim().isNotEmpty)
            Text(event.shortDescription.trim(),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 15)),
        ],
      ),
    );
  }
}

/// Without a receiver and Internet-TV channels: what TV is and the two ways
/// to set it up - the own Sat receiver or Internet-TV.
class _NotSetUp extends StatelessWidget {
  const _NotSetUp({required this.onInternetTv});

  /// Internet-TV's catalogue - a channel picked there goes on air.
  final VoidCallback onInternetTv;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset('assets/icon/tv_logo.png', width: 140, height: 140),
            ),
            const SizedBox(height: 24),
            const Text('TV', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              context.l10n.tvNotSetUpIntro,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.iptvNotSetUpIntro,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TvSettingsScreen())),
                  icon: const Icon(Icons.settings_input_antenna),
                  label: Text(context.l10n.tvSetUpReceiver),
                ),
                FilledButton.icon(
                  onPressed: onInternetTv,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(context.l10n.iptvSetUp),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What's coming in: picture (resolution, rate, codec), sound track, and
/// whether it's the receiver's original stream or transcoded.
class _StreamFacts extends StatelessWidget {
  const _StreamFacts({required this.info, required this.transcoded});

  final TvPlayerInfo info;

  /// null: not the receiver's stream (Internet-TV).
  final bool? transcoded;

  @override
  Widget build(BuildContext context) {
    final picture = [?info.grade, ?info.resolution, ?info.aspectLabel, ?info.rate, ?info.videoCodec].join(' · ');
    final sound = info.selectedAudio;
    final soundText = sound == null ? null : [sound.label, ?sound.details].join(' · ');
    final more = info.audio.length > 1 ? '  (${context.l10n.tvAudioTrackCount(info.audio.length)})' : '';
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (picture.isNotEmpty) _Chip(icon: Icons.hd_outlined, text: picture),
        if (soundText != null) _Chip(icon: Icons.audiotrack, text: '$soundText$more'),
        if (transcoded case final transcoded?)
          _Chip(
            icon: transcoded ? Icons.compress : Icons.verified_outlined,
            text: transcoded ? context.l10n.tvTranscoded : context.l10n.tvOriginalStream,
            color: transcoded ? Colors.orangeAccent : brandGreen,
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, this.color = Colors.white70});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    );
  }
}

/// Channel, now and next - shown on every channel change, like Radio's
/// "now playing" banner at the bottom.
class _InfoBanner extends ConsumerWidget {
  const _InfoBanner({
    required this.config,
    required this.channel,
    this.link,
    this.player,
    this.ahead = 0,
    this.onAheadLimit,
  });

  /// 0: now and next; 1..: the n-th programme after the one running now.
  final int ahead;

  /// Told how far ahead the programme goes (→ stops at the last one).
  final void Function(int max)? onAheadLimit;

  final Enigma2Config config;
  final E2Channel channel;

  /// While the channel connects: the setup instead of now and next.
  final LinkView? link;

  /// Its picture and sound - resolution, format, sound track.
  final TvPlayer? player;

  /// The keys as assigned (Einstellungen → Tasten der Fernbedienung).
  static String _hint(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(remoteKeysProvider);
    String k(RemoteAction a) => remoteKeyHint(keys, a);
    return context.l10n.tvBannerKeyHint(k(RemoteAction.channelList), k(RemoteAction.guide), k(RemoteAction.options));
  }

  /// "Heute 20:15 – 21:45" / "Morgen 06:00 – 06:30" / "Mo 20:15 – …".
  static String _when(BuildContext context, E2Event e) {
    final today = DateTime.now();
    final day = DateTime(e.begin.year, e.begin.month, e.begin.day);
    final diff = day.difference(DateTime(today.year, today.month, today.day)).inDays;
    final l = context.l10n;
    final d = diff == 0
        ? l.tvToday
        : diff == 1
            ? l.tvTomorrow
            : DateFormat.E(l.localeName).format(e.begin);
    return '$d ${hhmm(e.begin)} – ${hhmm(e.end)}';
  }

  /// A later programme (→): when, title, what it is - and what follows.
  Widget _later(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final all = ref.watch(tvChannelEpgProvider(channel.ref)).value;
    if (all == null) return Text(l.commonLoading, style: const TextStyle(color: Colors.white54, fontSize: 18));
    final t = DateTime.now();
    final later = all.where((e) => e.begin.isAfter(t)).toList()..sort((a, b) => a.begin.compareTo(b.begin));
    if (later.isEmpty) return Text(l.tvNoProgramInfo, style: const TextStyle(color: Colors.white54, fontSize: 18));
    if (ahead > later.length) WidgetsBinding.instance.addPostFrameCallback((_) => onAheadLimit?.call(later.length));
    final i = (ahead - 1).clamp(0, later.length - 1);
    final e = later[i];
    final after = i + 1 < later.length ? later[i + 1] : null;
    final about = e.shortDescription.isNotEmpty ? e.shortDescription : e.longDescription;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_when(context, e)}   ${e.title}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20)),
        if (about.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(about,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 16)),
        ],
        if (after != null) ...[
          const SizedBox(height: 8),
          Text('${l.tvThen} ${hhmm(after.begin)}   ${after.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 17)),
        ],
        const SizedBox(height: 6),
        Text(l.tvBannerLaterHint(i + 1, later.length),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14)),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nowNext = ref.watch(tvNowNextProvider);
    final epg = nowNext.value ?? const {};
    final nn = nowNextFor(epg, channel, DateTime.now());
    final now = nn.now, next = nn.next;
    final lookingAhead = ahead > 0 && link == null;
    final banner = Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: const EdgeInsets.fromLTRB(40, 20, 40, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Picon(config: config, channel: channel, width: 150, height: 90),
          const SizedBox(width: 28),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${channel.number} · ${channel.name}',
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                // What's on comes from the bouquet's now and next, loaded
                // beforehand - shown at once, while the channel still tunes.
                if (lookingAhead) ...[
                  _later(context, ref),
                ] else if (now != null) ...[
                  Text('${hhmm(now.begin)} – ${hhmm(now.end)}   ${now.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20)),
                  const SizedBox(height: 8),
                  EventProgress(event: now, width: 520),
                ] else
                  Text(nowNext.hasValue ? context.l10n.tvNoProgramInfo : context.l10n.commonLoading,
                      style: const TextStyle(color: Colors.white54, fontSize: 18)),
                if (next != null && !lookingAhead) ...[
                  const SizedBox(height: 8),
                  Text('${context.l10n.tvThen} ${hhmm(next.begin)}   ${next.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 17)),
                ],
                // The connection setup below it, in the stream facts' place.
                if (link case final link?) ...[
                  const SizedBox(height: 10),
                  ConnectionChain(view: link),
                ],
                if (player case final player? when link == null && !lookingAhead) ...[
                  const SizedBox(height: 10),
                  ValueListenableBuilder(
                    valueListenable: player.info,
                    builder: (context, info, _) => _StreamFacts(info: info, transcoded: config.streamPort == 8002),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const TvClock(style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(_hint(context, ref),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14)),
            ],
          ),
        ],
      ),
    );
    // The satellite signal small in the bottom right corner - only while
    // the picture runs (asked only while the banner is up).
    return Stack(
      children: [
        banner,
        if (player != null && link == null) Positioned(right: 40, bottom: 6, child: TvSignalBadge(channel: channel)),
      ],
    );
  }
}

/// What an Internet-TV channel is: country, categories, languages - in
/// place of a programme (no EPG for Internet-TV).
String iptvChannelFacts(IptvChannel c) => [
      if (c.country.isNotEmpty) countryName(c.country, c.country),
      if (c.categories.isNotEmpty) c.categories.map(iptvCategoryName).join(', '),
      if (c.languages.isNotEmpty) c.languages.map(iptvLanguageName).join(', '),
    ].join('  ·  ');

/// The Internet-TV channel on air, like [_InfoBanner]: logo, its number in
/// the Internet-TV list, name - and what it is instead of now and next.
class _IptvInfoBanner extends ConsumerWidget {
  const _IptvInfoBanner({required this.channel, this.number, this.link, this.player});

  final IptvChannel channel;

  /// In the Internet-TV favorites - null if played from the catalogue.
  final int? number;
  final LinkView? link;
  final TvPlayer? player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(remoteKeysProvider);
    String k(RemoteAction a) => remoteKeyHint(keys, a);
    final facts = iptvChannelFacts(channel);
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: const EdgeInsets.fromLTRB(40, 20, 40, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IptvLogo(channel: channel, width: 150, height: 90),
          const SizedBox(width: 28),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(number == null ? channel.name : '$number · ${channel.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(context.l10n.iptvListName,
                    style: const TextStyle(color: brandGreen, fontSize: 18, fontWeight: FontWeight.w600)),
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(facts,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 18)),
                ],
                if (link case final link?) ...[
                  const SizedBox(height: 10),
                  ConnectionChain(view: link),
                ],
                if (player case final player? when link == null) ...[
                  const SizedBox(height: 10),
                  ValueListenableBuilder(
                    valueListenable: player.info,
                    builder: (context, info, _) => _StreamFacts(info: info, transcoded: null),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const TvClock(style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(context.l10n.iptvBannerKeyHint(k(RemoteAction.channelList), k(RemoteAction.options)),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The open list's channels on the right, as Radio's station list: picon
/// (or Internet-TV logo), number, name, what's on now. The chips at the
/// top switch between the receiver's bouquets and Internet-TV, OK tunes.
/// Receiver channels: → opens the programme guide, OK held / ☰ their
/// options (move - into the receiver's bouquet). Internet-TV favorites:
/// → / ☰ their options (move, number, remove).
class _ChannelList extends ConsumerStatefulWidget {
  const _ChannelList({
    required this.config,
    required this.kind,
    required this.current,
    required this.iptvCurrent,
    required this.onPick,
    required this.onPickIptv,
    required this.onEpg,
    required this.onBrowse,
    required this.onClose,
    required this.onSettings,
    required this.onNote,
  });

  /// A short note over the picture (the order saved, or why not).
  final ValueChanged<String> onNote;

  /// Left: back to the picture.
  final VoidCallback onClose;

  /// The "TV-Einstellungen" button at the top.
  final VoidCallback onSettings;

  final Enigma2Config config;

  /// The list open when it opens.
  final TvListKind kind;
  final E2Channel? current;
  final IptvChannel? iptvCurrent;
  final ValueChanged<E2Channel> onPick;
  final ValueChanged<IptvChannel> onPickIptv;
  final ValueChanged<E2Channel> onEpg;

  /// "Sender suchen": Internet-TV's catalogue.
  final VoidCallback onBrowse;

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> with TvChannelMoveMixin<_ChannelList> {
  E2Channel? _focused;
  IptvChannel? _focusedIptv;

  /// The tuned channel's row - takes the focus when the list opens (the
  /// player had it, so the rows' autofocus wouldn't).
  final _startNode = FocusNode(debugLabel: 'channel list');

  /// "Sender suchen" - takes the focus while Internet-TV has no channels.
  final _browseNode = FocusNode(debugLabel: 'iptv browse');
  final _scroll = ScrollController();

  late TvListKind _kind = widget.kind;

  /// The Internet-TV row with [_startNode] - by position, so it stays put
  /// while a channel is moved.
  int _iptvStart = 0;

  /// The Internet-TV favorite being moved with ↑/↓ (its id), and where it
  /// was (Back puts it there again).
  String? _moving;
  int _movingFrom = 0;

  @override
  void focusMoveStartRow() => _focusStart();

  @override
  void moveNote(String text) => widget.onNote(text);

  /// The receiver row with [_startNode]: the tuned channel's (the first if
  /// it isn't in the bouquet) - kept by position once a channel was moved.
  int _receiverStartRow(List<E2Channel> list) {
    final fixed = moveStartRow;
    if (fixed != null) return fixed.clamp(0, list.isEmpty ? 0 : list.length - 1);
    final i = list.indexWhere((c) => c.ref == widget.current?.ref);
    return i < 0 ? 0 : i;
  }

  void _receiverOptions(E2Channel c) {
    final list = ref.read(tvChannelsProvider).value ?? const <E2Channel>[];
    final isCurrent = c.ref == widget.current?.ref;
    receiverChannelOptions(
      c,
      isCurrent: isCurrent,
      startRow: _receiverStartRow(list),
      onPlay: () => isCurrent ? _showProgrammeInfo(c) : widget.onPick(c),
      onGuide: () => widget.onEpg(c),
    );
  }

  Future<void> _endReceiverMove() async {
    final moved = await commitChannelMove();
    if (moved != null && mounted) _focused = moved;
  }

  /// Every row is this high - so the list can jump straight to the tuned
  /// channel (only rows on screen are built, one further down has no
  /// widget to take the focus).
  static const _rowExtent = 92.0;

  @override
  void initState() {
    super.initState();
    _iptvStart = _iptvIndexOfCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  @override
  void dispose() {
    _startNode.dispose();
    _browseNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<IptvChannel> get _favorites => ref.read(iptvProvider)?.favorites ?? const [];

  int _iptvIndexOfCurrent() {
    final i = _favorites.indexWhere((c) => c.id == widget.iptvCurrent?.id);
    return i < 0 ? 0 : i;
  }

  void _focusStart([int attempt = 0]) {
    if (!mounted || attempt > 50) return;
    final int i;
    if (_kind == TvListKind.iptv) {
      if (_favorites.isEmpty) {
        if (_browseNode.context != null) {
          _browseNode.requestFocus();
        } else {
          Future.delayed(const Duration(milliseconds: 100), () => _focusStart(attempt + 1));
        }
        return;
      }
      if (!_scroll.hasClients) {
        Future.delayed(const Duration(milliseconds: 100), () => _focusStart(attempt + 1));
        return;
      }
      i = _iptvStart;
    } else {
      final list = ref.read(tvChannelsProvider).value;
      if (list == null || !_scroll.hasClients) {
        // Channels still loading - once they're there.
        Future.delayed(const Duration(milliseconds: 100), () => _focusStart(attempt + 1));
        return;
      }
      // The tuned channel's row in the middle - not in this bouquet: the first.
      i = _receiverStartRow(list);
    }
    final position = _scroll.position;
    final centred = i * _rowExtent - (position.viewportDimension - _rowExtent) / 2;
    _scroll.jumpTo(i <= 0 ? 0.0 : centred.clamp(0.0, position.maxScrollExtent));
    // Its row is built with the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_startNode.context != null) {
        _startNode.requestFocus();
      } else {
        Future.delayed(const Duration(milliseconds: 100), () => _focusStart(attempt + 1));
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Another of the receiver's channel lists (bouquets), from the choice at
  /// the top of the list.
  Future<void> _switchBouquet(String bouquetRef) async {
    final wasReceiver = _kind == TvListKind.receiver;
    setState(() {
      _kind = TvListKind.receiver;
      _moving = null;
      dropChannelMove();
    });
    unawaited(ref.read(iptvProvider.notifier).setList(TvListKind.receiver));
    if (bouquetRef == ref.read(tvCurrentBouquetProvider).value?.ref) {
      if (wasReceiver) {
        _focusStart();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
      }
      return;
    }
    await ref.read(tvBouquetProvider.notifier).set(bouquetRef);
    await ref.read(tvChannelsProvider.future);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  /// The Internet-TV favorites as the list (its own numbers).
  void _showIptv() {
    setState(() {
      _kind = TvListKind.iptv;
      _iptvStart = _iptvIndexOfCurrent();
      dropChannelMove();
    });
    unawaited(ref.read(iptvProvider.notifier).setList(TvListKind.iptv));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  /// What's on [c] now (and next), in full.
  Future<void> _showProgrammeInfo(E2Channel c) async {
    final epg = ref.read(tvNowNextProvider).value ?? const {};
    final nn = nowNextFor(epg, c, DateTime.now());
    await showDialog<void>(
      context: context,
      builder: (context) => _ProgrammeInfo(config: widget.config, channel: c, now: nn.now, next: nn.next),
    );
  }

  /// A favorite's options: play, move, number, remove.
  Future<void> _iptvOptions(IptvChannel c) async {
    final t = context.l10n;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(c.name),
        children: [
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('play'),
            child: ListTile(leading: const Icon(Icons.play_arrow), title: Text(t.iptvPlay)),
          ),
          if (_favorites.length > 1) ...[
            TvRow(
              onTap: () => Navigator.of(context).pop('move'),
              child: ListTile(
                leading: const Icon(Icons.swap_vert),
                title: Text(t.iptvMove),
                subtitle: Text(t.iptvMoveHint),
              ),
            ),
            TvRow(
              onTap: () => Navigator.of(context).pop('number'),
              child: ListTile(leading: const Icon(Icons.pin_outlined), title: Text(t.iptvChangeNumber)),
            ),
          ],
          TvRow(
            onTap: () => Navigator.of(context).pop('remove'),
            child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(t.iptvRemoveFavorite)),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    final notifier = ref.read(iptvProvider.notifier);
    switch (choice) {
      case 'play':
        widget.onPickIptv(c);
      case 'move':
        setState(() {
          _moving = c.id;
          _movingFrom = _favorites.indexWhere((x) => x.id == c.id);
        });
      case 'number':
        final from = _favorites.indexWhere((x) => x.id == c.id);
        if (from < 0) return;
        final number = await showDialog<int>(
          context: context,
          builder: (context) => ProgramNumberDialog(initial: from + 1),
        );
        if (number == null || !mounted) return;
        await notifier.moveFavorite(from, number - 1);
        if (!mounted) return;
        // The list follows it to its new place.
        final to = _favorites.indexWhere((x) => x.id == c.id);
        setState(() => _iptvStart = to < 0 ? 0 : to);
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
      case 'remove':
        final at = _favorites.indexWhere((x) => x.id == c.id);
        await notifier.removeFavorite(c.id);
        if (!mounted) return;
        final rest = _favorites;
        if (rest.isEmpty) {
          _browseNode.requestFocus();
        } else {
          // The row keeps the focus and now shows the next channel (the
          // last row is gone: up one).
          final i = at.clamp(0, rest.length - 1);
          _focusedIptv = rest[i];
          if (at >= rest.length) {
            FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up);
          }
        }
    }
  }

  /// While moving: the favorite one place up or down, the focus with it.
  void _moveBy(int delta) {
    final list = _favorites;
    final from = list.indexWhere((c) => c.id == _moving);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= list.length) return;
    ref.read(iptvProvider.notifier).moveFavorite(from, to);
    FocusManager.instance.primaryFocus?.focusInDirection(delta < 0 ? TraversalDirection.up : TraversalDirection.down);
  }

  void _endMove() {
    final id = _moving;
    setState(() => _moving = null);
    _focusedIptv = _favorites.where((c) => c.id == id).firstOrNull ?? _focusedIptv;
  }

  /// Back while moving: the favorite where it was, the focus on it.
  Future<void> _cancelMove() async {
    final id = _moving;
    final at = _favorites.indexWhere((c) => c.id == id);
    final from = _movingFrom;
    setState(() {
      _moving = null;
      if (from >= 0) _iptvStart = from;
    });
    if (at >= 0 && from >= 0 && at != from) await ref.read(iptvProvider.notifier).moveFavorite(at, from);
    if (!mounted) return;
    _focusedIptv = _favorites.where((c) => c.id == id).firstOrNull ?? _focusedIptv;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final receiverMove = channelMoveKey(event);
    if (receiverMove != null) return receiverMove;
    if (_moving != null) {
      if (event is KeyUpEvent) return KeyEventResult.ignored;
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        _moveBy(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent && (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack)) {
        _cancelMove();
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent && (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) {
        _endMove();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = ref.read(remoteKeysProvider);
    if (_kind == TvListKind.iptv) {
      // Right / ☰: the favorite's options (Internet-TV has no guide).
      if (key == LogicalKeyboardKey.arrowRight ||
          keys.matches(RemoteAction.options, key) ||
          keys.matches(RemoteAction.guide, key)) {
        final c = _focusedIptv;
        if (c != null) _iptvOptions(c);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        widget.onClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Right: the programme guide at the marked channel (no extra key needed).
    if (key == LogicalKeyboardKey.arrowRight) {
      final c = _focused ?? widget.current;
      if (c != null) widget.onEpg(c);
      return KeyEventResult.handled;
    }
    // Left: closes the list again.
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    // ☰: the channel's options (move, ...); the guide key: the guide.
    if (keys.matches(RemoteAction.options, key)) {
      final c = _focused ?? widget.current;
      if (c != null) _receiverOptions(c);
      return KeyEventResult.handled;
    }
    if (keys.matches(RemoteAction.guide, key)) {
      final c = _focused ?? widget.current;
      if (c != null) widget.onEpg(c);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final iptv = ref.watch(iptvProvider);
    final iptvShown = iptv?.enabled ?? false;
    final bouquet = ref.watch(tvCurrentBouquetProvider).value;
    final isIptv = _kind == TvListKind.iptv;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icon/tv_logo.png', width: 36, height: 36),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Home System', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Powered by jaycloud.at', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
                  ],
                ),
                const Spacer(),
                // Like Radio's: the settings top right, next to the clock.
                _BouquetChip(label: context.l10n.tvSettingsButton, icon: Icons.settings, onTap: widget.onSettings),
                const SizedBox(width: 16),
                const TvClock(),
              ],
            ),
            const SizedBox(height: 14),
            // The receiver's channel lists, below them Internet-TV - up from
            // the first channel.
            _BouquetChoice(
              bouquets: widget.config.configured ? ref.watch(tvBouquetsProvider).value ?? const [] : const [],
              current: isIptv ? null : bouquet,
              onPick: (b) => _switchBouquet(b.ref),
              onSettings: widget.onSettings,
              iptv: iptvShown,
              iptvSelected: isIptv,
              onIptv: _showIptv,
              onBrowse: widget.onBrowse,
              browseNode: _browseNode,
            ),
            const SizedBox(height: 8),
            // Plain arrows - Android draws ▶/◀ as coloured emoji.
            Text(
              _moving != null || movingChannel
                  ? context.l10n.tvMoveKeyHint
                  : isIptv
                      ? context.l10n.iptvChannelListKeyHint
                      : context.l10n.tvChannelListKeyHint,
              style: TextStyle(
                  color: _moving != null || movingChannel ? brandGreen : Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
            const SizedBox(height: 10),
            Expanded(child: isIptv ? _iptvRows(iptv?.favorites ?? const []) : _receiverRows()),
          ],
        ),
      ),
    );
  }

  Widget _receiverRows() {
    final channels = ref.watch(tvChannelsProvider);
    final epg = ref.watch(tvNowNextProvider).value ?? const {};
    final now = DateTime.now();
    return channels.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: Colors.white70))),
      data: (list) => list.isEmpty
          ? Center(child: Text(context.l10n.tvNoChannelsInList, style: const TextStyle(color: Colors.white70)))
          : ListView.builder(
              controller: _scroll,
              itemCount: shownChannels(list).length,
              itemExtent: _rowExtent,
              padding: const EdgeInsets.only(bottom: 20),
              itemBuilder: (context, i) {
                final c = shownChannels(list)[i];
                final event = nowNextFor(epg, c, now).now;
                final isCurrent = c.ref == widget.current?.ref;
                final start = i == _receiverStartRow(list);
                final moving = c.ref == movingRef;
                // OK while moving: done; on the channel on air: its
                // programme info; on another: play it.
                void tap() => movingChannel
                    ? _endReceiverMove()
                    : isCurrent
                        ? _showProgrammeInfo(c)
                        : widget.onPick(c);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: TvRow(
                    focusNode: start ? _startNode : null,
                    selected: isCurrent || moving,
                    onFocused: () {
                      if (!movingChannel) _focused = c;
                    },
                    onTap: tap,
                    // OK held: the channel's options (move, ...).
                    onLongPress: movingChannel ? null : () => _receiverOptions(c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text('${c.number}', style: const TextStyle(color: Colors.white54, fontSize: 16)),
                          ),
                          Picon(config: widget.config, channel: c, width: 76, height: 46),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                                if (event != null) ...[
                                  const SizedBox(height: 2),
                                  Text('${hhmm(event.begin)}  ${event.title}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white60, fontSize: 14)),
                                  const SizedBox(height: 5),
                                  EventProgress(event: event, height: 4),
                                ],
                              ],
                            ),
                          ),
                          // ▶ (or a click on it): the programme guide;
                          // while moving ↕.
                          GestureDetector(
                            onTap: movingChannel ? null : () => widget.onEpg(c),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: moving
                                  ? const Icon(Icons.swap_vert, color: brandGreen, size: 28)
                                  : const Icon(Icons.chevron_right, color: Colors.white54, size: 30),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// The Internet-TV favorites, numbered 1, 2, 3, ... in their order.
  Widget _iptvRows(List<IptvChannel> list) {
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(context.l10n.iptvEmptyList,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 17)),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: list.length,
      itemExtent: _rowExtent,
      padding: const EdgeInsets.only(bottom: 20),
      itemBuilder: (context, i) {
        final c = list[i];
        final isCurrent = c.id == widget.iptvCurrent?.id;
        final moving = c.id == _moving;
        final facts = iptvChannelFacts(c);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: TvRow(
            focusNode: i == _iptvStart ? _startNode : null,
            selected: isCurrent || moving,
            onFocused: () {
              if (_moving == null) _focusedIptv = c;
            },
            // OK while moving: done; on the channel on air: its info; on
            // another: play it.
            onTap: () => _moving != null
                ? _endMove()
                : isCurrent
                    ? showDialog<void>(context: context, builder: (_) => _IptvInfo(channel: c, number: i + 1))
                    : widget.onPickIptv(c),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text('${i + 1}', style: const TextStyle(color: Colors.white54, fontSize: 16)),
                  ),
                  IptvLogo(channel: c, width: 76, height: 46),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                        if (facts.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(facts,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60, fontSize: 14)),
                        ],
                      ],
                    ),
                  ),
                  // A click on it: its options; while moving ↕.
                  GestureDetector(
                    onTap: () => _iptvOptions(c),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(moving ? Icons.swap_vert : Icons.more_vert,
                          color: moving ? brandGreen : Colors.white54, size: 28),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The receiver's channel lists (bouquets) and Internet-TV side by side at
/// the top of the channel list - up from the first channel, OK picks one.
class _BouquetChoice extends StatelessWidget {
  const _BouquetChoice({
    required this.bouquets,
    required this.current,
    required this.onPick,
    required this.onSettings,
    this.iptv = false,
    this.iptvSelected = false,
    this.onIptv,
    this.onBrowse,
    this.browseNode,
  });

  final List<E2Bouquet> bouquets;

  /// The bouquet open - null while Internet-TV is.
  final E2Bouquet? current;
  final ValueChanged<E2Bouquet> onPick;

  /// "TV-Einstellungen" - now top right in the header; kept for callers.
  final VoidCallback onSettings;

  /// Internet-TV's chips: its favorites and "Sender suchen".
  final bool iptv;
  final bool iptvSelected;
  final VoidCallback? onIptv;
  final VoidCallback? onBrowse;
  final FocusNode? browseNode;

  /// The receiver's English names in the app's language, without "(TV)".
  static String label(AppLocalizations t, String name) {
    final n = name.replaceAll(RegExp(r'\s*\(TV\)\s*$', caseSensitive: false), '').trim();
    return switch (n.toLowerCase()) {
      'favourites' || 'favorites' => t.tvBouquetFavorites,
      'last scanned' => t.tvBouquetLastScanned,
      _ => n,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // One line per source: the receiver's lists, then Internet-TV.
    Widget row(String title, List<Widget> chips) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 104,
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: chips)),
            ],
          ),
        );
    final receiver = [
      for (final b in bouquets)
        _BouquetChip(
          label: label(l, b.name),
          selected: !iptvSelected && b.ref == current?.ref,
          onTap: () => onPick(b),
        ),
    ];
    // Left/right move between the lists here (the channel rows below use
    // them for info and the programme guide).
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
          FocusScope.of(context).focusInDirection(
            key == LogicalKeyboardKey.arrowLeft ? TraversalDirection.left : TraversalDirection.right,
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (receiver.length >= 2)
            row(l.tvRowReceiver, receiver)
          else if (current != null && !iptv)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(label(l, current!.name),
                  style: const TextStyle(color: brandGreen, fontSize: 18, fontWeight: FontWeight.w600)),
            )
          else if (receiver.length == 1)
            row(l.tvRowReceiver, receiver),
          if (iptv)
            row(l.iptvListName, [
              _BouquetChip(label: l.iptvChipMine, icon: Icons.public, selected: iptvSelected, onTap: onIptv ?? () {}),
              _BouquetChip(
                label: l.iptvChipSearch,
                icon: Icons.travel_explore,
                focusNode: browseNode,
                onTap: onBrowse ?? () {},
              ),
            ]),
        ],
      ),
    );
  }
}

class _BouquetChip extends StatefulWidget {
  const _BouquetChip({required this.label, this.selected = false, this.icon, this.focusNode, required this.onTap});

  final String label;
  final bool selected;
  final IconData? icon;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  @override
  State<_BouquetChip> createState() => _BouquetChipState();
}

class _BouquetChipState extends State<_BouquetChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(18),
      child: Material(
        color: widget.selected ? brandGreen.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(18),
          focusColor: Colors.transparent,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: widget.selected ? Colors.black : Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.selected ? Colors.black : Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// OK on the Internet-TV channel on air in the channel list: what it is
/// and where it comes from. Back or OK close it.
class _IptvInfo extends StatelessWidget {
  const _IptvInfo({required this.channel, this.number});

  final IptvChannel channel;
  final int? number;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final stream = channel.streams.firstOrNull;
    final facts = iptvChannelFacts(channel);
    return AlertDialog(
      backgroundColor: const Color(0xFF0E151A),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Row(
        children: [
          IptvLogo(channel: channel, width: 76, height: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Text(number == null ? channel.name : '$number · ${channel.name}',
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.iptvListName, style: const TextStyle(color: brandGreen, fontSize: 16)),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(facts, style: const TextStyle(color: Colors.white, fontSize: 18)),
            ],
            const SizedBox(height: 14),
            Text(t.iptvNoGuideSentence, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            if (stream != null && (stream.geoBlocked || stream.notAlways)) ...[
              const SizedBox(height: 8),
              Text(
                [if (stream.geoBlocked) t.iptvGeoBlocked, if (stream.notAlways) t.iptvNotAlways].join('  ·  '),
                style: const TextStyle(color: Colors.amber, fontSize: 15),
              ),
            ],
            const SizedBox(height: 14),
            Text(t.iptvSource, style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(t.commonClose)),
      ],
    );
  }
}

/// OK on the channel on air in the channel list: what's on now, in full,
/// and what's next. Back or OK close it.
class _ProgrammeInfo extends StatelessWidget {
  const _ProgrammeInfo({required this.config, required this.channel, required this.now, required this.next});

  final Enigma2Config config;
  final E2Channel channel;
  final E2Event? now;
  final E2Event? next;

  @override
  Widget build(BuildContext context) {
    final e = now;
    return AlertDialog(
      backgroundColor: const Color(0xFF0E151A),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Row(
        children: [
          Picon(config: config, channel: channel, width: 76, height: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Text('${channel.number} · ${channel.name}',
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (e == null)
                Text(context.l10n.tvNoProgramInfoSentence, style: const TextStyle(color: Colors.white70, fontSize: 18))
              else ...[
                Text(e.title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('${hhmm(e.begin)} – ${hhmm(e.end)}  ·  ${context.l10n.tvMinutes(e.duration.inMinutes)}',
                    style: const TextStyle(color: brandGreen, fontSize: 16)),
                const SizedBox(height: 8),
                EventProgress(event: e, width: 400),
                const SizedBox(height: 14),
                Text(e.description.isEmpty ? context.l10n.tvNoDescription : e.description,
                    style: const TextStyle(color: Colors.white70, fontSize: 17, height: 1.4)),
              ],
              if (next != null) ...[
                const SizedBox(height: 18),
                Text('${context.l10n.tvThen} ${hhmm(next!.begin)}  ${next!.title}',
                    style: const TextStyle(color: Colors.white60, fontSize: 16)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(context.l10n.commonClose)),
      ],
    );
  }
}
