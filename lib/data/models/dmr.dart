import 'dart:convert';

/// One TDMA time slot of a DMR channel, from the receiver's `nbDmr` event
/// (see dmrStatusJson in android/app/src/main/cpp/hrdab/dmr.cpp).
class DmrSlot {
  /// 1 or 2.
  final int slot;

  /// A voice call is going on right now.
  final bool active;

  /// 'group', 'private' (unit to unit) or '' (not yet known).
  final String callType;

  /// Radio ID of the speaker and the talk group / called radio; 0 = not
  /// yet known (joined late, before the embedded link control came).
  final int src;
  final int dst;

  /// Talker alias the radio sends along (call sign, name), '' = none.
  final String alias;
  final bool encrypted;
  final bool emergency;

  /// Bit errors the vocoder FEC corrected per voice frame (this call).
  final double errorRate;

  /// Since the slot's last voice; -1 = nothing heard yet.
  final double secondsAgo;

  const DmrSlot({
    required this.slot,
    required this.active,
    required this.callType,
    required this.src,
    required this.dst,
    required this.alias,
    required this.encrypted,
    required this.emergency,
    required this.errorRate,
    required this.secondsAgo,
  });

  factory DmrSlot.fromJson(Map<String, dynamic> m) => DmrSlot(
    slot: (m['slot'] as num?)?.toInt() ?? 0,
    active: m['active'] as bool? ?? false,
    callType: m['callType'] as String? ?? '',
    src: (m['src'] as num?)?.toInt() ?? 0,
    dst: (m['dst'] as num?)?.toInt() ?? 0,
    alias: m['alias'] as String? ?? '',
    encrypted: m['encrypted'] as bool? ?? false,
    emergency: m['emergency'] as bool? ?? false,
    errorRate: (m['errorRate'] as num?)?.toDouble() ?? 0,
    secondsAgo: (m['secondsAgo'] as num?)?.toDouble() ?? -1,
  );

  bool get heard => secondsAgo >= 0;

  /// In a call, or just was: repeaters fill short gaps of a network call
  /// with idle bursts, which ends it for the decoder - not worth a flicker.
  bool get talking => active || (heard && secondsAgo < 1.5);

  /// "TG 262", "an 2620001", or '' while unknown.
  String get target => switch (callType) {
    'group' => 'TG $dst',
    'private' => 'an $dst',
    _ => '',
  };

  /// "DL1ABC (2620001)", "2620001", or '' while unknown.
  String get speaker {
    if (src == 0) return alias;
    return alias.isEmpty ? '$src' : '$alias ($src)';
  }
}

/// The whole DMR picture of the listened channel.
class DmrStatus {
  /// DMR bursts within the last second.
  final bool sync;

  /// 'repeater', 'radio', 'direct' or ''.
  final String source;

  /// -1 = unknown.
  final int colorCode;

  /// The slot being played (1/2), 0 = none.
  final int audioSlot;

  /// Built with the AMBE+2 voice decoder; without it calls show, but stay silent.
  final bool voiceDecoder;
  final List<DmrSlot> slots;

  const DmrStatus({
    required this.sync,
    required this.source,
    required this.colorCode,
    required this.audioSlot,
    required this.voiceDecoder,
    required this.slots,
  });

  /// Android sends the native JSON as `json`, the desktop the object itself.
  static DmrStatus? fromEvent(Map<String, dynamic> event) {
    try {
      final raw = event['json'];
      final m = raw is String ? (jsonDecode(raw) as Map).cast<String, dynamic>() : event;
      return DmrStatus(
        sync: m['sync'] as bool? ?? false,
        source: m['source'] as String? ?? '',
        colorCode: (m['colorCode'] as num?)?.toInt() ?? -1,
        audioSlot: (m['audioSlot'] as num?)?.toInt() ?? 0,
        voiceDecoder: m['voiceDecoder'] as bool? ?? false,
        slots: [
          for (final s in (m['slots'] as List? ?? const [])) DmrSlot.fromJson((s as Map).cast<String, dynamic>()),
        ],
      );
    } on FormatException {
      return null;
    }
  }

  String get sourceLabel => switch (source) {
    'repeater' => 'Relais',
    'radio' => 'Funkgerät',
    'direct' => 'Direktverbindung',
    _ => '',
  };
}
