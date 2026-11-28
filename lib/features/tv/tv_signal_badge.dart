import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/enigma2_service.dart';
import 'tv_progress_bar.dart' show programmeProgressColor;
import 'tv_providers.dart';

/// The satellite signal of the channel on air, small in the info bar's
/// bottom right corner: quality (SNR in dB and %), level (AGC), bit errors.
///
/// Asked every few seconds while it is shown (the info bar is up) and not
/// at all otherwise - read only (OpenWebif's /api/signal). The receiver
/// measures only the tuner of the channel it shows itself: in standby it
/// tells nothing, and while it's on it may be another tuner than the
/// stream's - then nothing is shown rather than another tuner's values.
class TvSignalBadge extends ConsumerStatefulWidget {
  const TvSignalBadge({super.key, required this.channel});

  final E2Channel channel;

  @override
  ConsumerState<TvSignalBadge> createState() => _TvSignalBadgeState();
}

class _TvSignalBadgeState extends ConsumerState<TvSignalBadge> {
  static const _every = Duration(seconds: 3);

  /// The stream's tuner per channel (serviceKey) - it doesn't change while
  /// the stream runs, so /api/about is asked once in a while only.
  static final _tuners = <String, ({int? tuner, DateTime at})>{};

  Timer? _timer;
  E2Signal? _signal;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(_every, (_) => _poll());
  }

  @override
  void didUpdateWidget(TvSignalBadge old) {
    super.didUpdateWidget(old);
    if (old.channel.ref != widget.channel.ref) {
      _signal = null;
      _poll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final service = ref.read(enigma2ServiceProvider);
    if (_busy || service == null) return;
    _busy = true;
    final channel = widget.channel;
    E2Signal? shown;
    try {
      final signal = await service.signal();
      if (signal != null && await _streamTuner(service, channel) == signal.tuner) shown = signal;
    } catch (_) {
      // Unreachable for a moment: nothing shown rather than old values.
    } finally {
      _busy = false;
    }
    if (!mounted || channel.ref != widget.channel.ref || shown == _signal) return;
    setState(() => _signal = shown);
  }

  static Future<int?> _streamTuner(Enigma2Service service, E2Channel channel) async {
    final key = serviceKey(channel.ref);
    final known = _tuners[key];
    if (known != null && DateTime.now().difference(known.at) < const Duration(minutes: 2)) return known.tuner;
    int? tuner;
    try {
      tuner = await service.streamTuner(channel.ref);
    } catch (_) {}
    _tuners[key] = (tuner: tuner, at: DateTime.now());
    return tuner;
  }

  @override
  Widget build(BuildContext context) {
    final s = _signal;
    if (s == null) return const SizedBox.shrink();
    // Green for a good signal, red for a weak one - the programme bar's scale.
    final color = s.snrPercent == null ? Colors.white54 : programmeProgressColor(1 - s.snrPercent! / 100);
    const style = TextStyle(color: Colors.white54, fontSize: 13);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.satellite_alt, size: 15, color: color),
        const SizedBox(width: 6),
        if (s.quality.isNotEmpty) Text('SNR ${s.quality}', style: style.copyWith(color: Colors.white70)),
        if (s.agcPercent != null) Text('   AGC ${s.agcPercent} %', style: style),
        if (s.ber != null) Text('   BER ${s.ber}', style: style),
      ],
    );
  }
}
