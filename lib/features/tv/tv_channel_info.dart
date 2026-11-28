import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/country_names_de.dart';
import '../../core/theme.dart';
import '../../data/models/iptv_channel.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import 'iptv_providers.dart';
import 'tv_providers.dart';
import 'tv_widgets.dart';

/// What OK on a row of the channel list does.
enum TvListOk {
  /// Another channel: switch to it.
  tune,

  /// The channel on air, list at the side: its programme info.
  showInfo,

  /// The channel on air, list with info beside it, but it shows no
  /// picture (stopped, error, stream lost): tune it again.
  retune,

  /// The channel on air, list with info, and it plays: back to the picture.
  close,
}

/// OK on a row: [withInfo] = "Senderliste mit Info rechts", [isCurrent] =
/// the row is the channel on air, [plays] = that channel actually plays
/// (or is still on its way, see [tvChannelPlays]).
TvListOk channelListOk({required bool withInfo, required bool isCurrent, required bool plays}) {
  if (!isCurrent) return TvListOk.tune;
  if (!withInfo) return TvListOk.showInfo;
  return plays ? TvListOk.close : TvListOk.retune;
}

/// The channel on air plays: it has a picture or is being tuned right now
/// - not paused, not failed (an error, the stream lost), not given up.
bool tvChannelPlays({required bool hasPlayer, required bool loading, required bool stopped, required bool failed}) =>
    !stopped && !failed && (hasPlayer || loading);

/// Where the channel list and the info beside it go across [width]: the
/// list in the middle, the info right next to it up to the screen's right
/// edge (no gaps) - the list moves left as far as the info needs. On a
/// narrow screen the info is left out ([infoWidth] 0) and the list takes
/// it all.
({double listLeft, double listWidth, double infoLeft, double infoWidth}) channelListInfoLayout(double width) {
  const minInfo = 300.0;
  final listWidth = (width * 0.4).clamp(380.0, 620.0);
  if (width - minInfo < listWidth) {
    return (listLeft: 0.0, listWidth: width, infoLeft: width, infoWidth: 0.0);
  }
  var listLeft = (width - listWidth) / 2;
  if (width - (listLeft + listWidth) < minInfo) listLeft = width - minInfo - listWidth;
  final infoLeft = listLeft + listWidth;
  return (listLeft: listLeft, listWidth: listWidth, infoLeft: infoLeft, infoWidth: width - infoLeft);
}

/// What an Internet-TV channel is: country, categories, languages - in
/// place of a programme (no EPG for Internet-TV).
String iptvChannelFacts(IptvChannel c) => [
      if (c.country.isNotEmpty) countryName(c.country, c.country),
      if (c.categories.isNotEmpty) c.categories.map((x) => iptvCategoryName(x)).join(', '),
      if (c.languages.isNotEmpty) c.languages.map((x) => iptvLanguageName(x)).join(', '),
    ].join('  ·  ');

/// A programme in full: title, time and length, progress, description -
/// the programme info dialog's and the info beside the channel list.
class TvProgrammeDetails extends StatelessWidget {
  const TvProgrammeDetails({
    super.key,
    required this.event,
    this.scale = 1,
    this.descriptionLines,
    this.barWidth = 400,
    this.timeColour = brandGreen,
  });

  final E2Event event;

  /// The time and length line's colour (white beside the channel list).
  final Color timeColour;

  /// Einstellungen → TV → Schrift der Senderliste (beside the list).
  final double scale;

  /// At most this many lines of description - null: all of it.
  final int? descriptionLines;
  final double? barWidth;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final l = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(e.title,
            maxLines: descriptionLines == null ? null : 2,
            overflow: descriptionLines == null ? null : TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white, fontSize: 24 * scale, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('${hhmm(e.begin)} – ${hhmm(e.end)}  ·  ${l.tvMinutes(e.duration.inMinutes)}',
            style: TextStyle(color: timeColour, fontSize: 16 * scale)),
        const SizedBox(height: 8),
        EventProgress(event: e, width: barWidth),
        const SizedBox(height: 14),
        Text(e.description.isEmpty ? l.tvNoDescription : e.description,
            maxLines: descriptionLines,
            overflow: descriptionLines == null ? null : TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white70, fontSize: 17 * scale, height: 1.4)),
      ],
    );
  }
}

/// What the Internet-TV info says about a channel: the list, its facts,
/// no guide, geo-blocked / not always on, the catalogue it comes from.
class IptvChannelDetails extends StatelessWidget {
  const IptvChannelDetails({super.key, required this.channel, this.scale = 1});

  final IptvChannel channel;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final stream = channel.streams.firstOrNull;
    final facts = iptvChannelFacts(channel);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.iptvListName, style: TextStyle(color: brandGreen, fontSize: 16 * scale)),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(facts, style: TextStyle(color: Colors.white, fontSize: 18 * scale)),
        ],
        const SizedBox(height: 14),
        Text(t.iptvNoGuideSentence, style: TextStyle(color: Colors.white70, fontSize: 16 * scale)),
        if (stream != null && (stream.geoBlocked || stream.notAlways)) ...[
          const SizedBox(height: 8),
          Text(
            [if (stream.geoBlocked) t.iptvGeoBlocked, if (stream.notAlways) t.iptvNotAlways].join('  ·  '),
            style: TextStyle(color: Colors.amber, fontSize: 15 * scale),
          ),
        ],
        const SizedBox(height: 14),
        Text(t.iptvSource, style: TextStyle(color: Colors.white38, fontSize: 13 * scale)),
      ],
    );
  }
}

/// Loads one channel's full EPG (service reference -> programmes).
typedef TvEpgLoader = Future<List<E2Event>> Function(String serviceRef);

/// Beside the channel list ("Senderliste mit Info rechts"): the marked
/// channel - picon, number, name - what's on (time, progress, description)
/// and what comes after. Now and next come from the bouquet's query loaded
/// beforehand (at once, while scrolling); the programmes after that from
/// the channel's EPG, asked only once the marking rests a moment, and only
/// the few needed are kept. An Internet-TV channel: what the Internet-TV
/// info says (no EPG). Never takes the focus.
class TvChannelInfoPanel extends ConsumerStatefulWidget {
  const TvChannelInfoPanel({
    super.key,
    required this.config,
    this.channel,
    this.iptv,
    this.iptvNumber,
    required this.isCurrent,
    required this.currentPlays,
    this.textScale = 1,
    this.loadEpg,
    this.settle = const Duration(milliseconds: 600),
  });

  final Enigma2Config config;

  /// The receiver channel marked - or [iptv].
  final E2Channel? channel;
  final IptvChannel? iptv;

  /// [iptv]'s number in the Internet-TV favorites.
  final int? iptvNumber;

  /// The marked channel is the one on air ...
  final bool isCurrent;

  /// ... and it plays (OK goes back to the picture) - else OK tunes it again.
  final bool currentPlays;

  /// Einstellungen → TV → Schrift der Senderliste.
  final double textScale;

  /// The channel's EPG - the receiver's by default.
  final TvEpgLoader? loadEpg;

  /// How long the marking rests before the EPG is asked.
  final Duration settle;

  @override
  ConsumerState<TvChannelInfoPanel> createState() => TvChannelInfoPanelState();
}

class TvChannelInfoPanelState extends ConsumerState<TvChannelInfoPanel> {
  /// The programmes still to come per channel looked at (a few each, the
  /// last channels only) - while the list is open.
  final _later = <String, List<E2Event>>{};
  static const _keep = 30, _laterCount = 4;
  Timer? _settle;
  String? _loading;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(TvChannelInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel?.ref != widget.channel?.ref) _schedule();
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  void _schedule() {
    _settle?.cancel();
    final c = widget.channel;
    if (c == null || _later.containsKey(c.ref)) return;
    _settle = Timer(widget.settle, () => _load(c.ref));
  }

  Future<void> _load(String serviceRef) async {
    if (_loading == serviceRef) return;
    _loading = serviceRef;
    List<E2Event> events;
    try {
      final loader = widget.loadEpg ?? ref.read(enigma2ServiceProvider)?.channelEpg;
      events = loader == null ? const [] : await loader(serviceRef);
    } catch (_) {
      // Not this time (asked again when marked again) - now and next show
      // anyway.
      if (_loading == serviceRef) _loading = null;
      return;
    }
    if (_loading == serviceRef) _loading = null;
    if (!mounted) return;
    final t = DateTime.now();
    final kept = events.where((e) => e.end.isAfter(t)).take(_laterCount + 1).toList();
    setState(() {
      _later.remove(serviceRef);
      _later[serviceRef] = kept;
      while (_later.length > _keep) {
        _later.remove(_later.keys.first);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final iptv = widget.iptv;
    final channel = widget.channel;
    final s = widget.textScale;
    // Name and number grow half as much as the rest (as in the list).
    final nameScale = 1 + (s - 1) / 2;
    final Widget header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (iptv != null)
          IptvLogo(channel: iptv, width: 120, height: 72)
        else if (channel != null)
          Picon(config: widget.config, channel: channel, width: 120, height: 72),
        const SizedBox(width: 16),
        Expanded(
          child: iptv == null && channel != null
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TvChannelName(
                    '${channel.number} · ${channel.name}',
                    serviceRef: channel.ref,
                    maxLines: 2,
                    style: TextStyle(color: Colors.white, fontSize: 24 * nameScale, fontWeight: FontWeight.bold),
                  ),
                )
              : Text(
                  iptv != null ? (widget.iptvNumber == null ? iptv.name : '${widget.iptvNumber} · ${iptv.name}') : '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontSize: 24 * nameScale, fontWeight: FontWeight.bold),
                ),
        ),
      ],
    );
    final l = context.l10n;
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      // Clipped, never scrolled: a long description just ends.
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        primary: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            if (widget.isCurrent) ...[
              const SizedBox(height: 10),
              _OnAir(plays: widget.currentPlays, text: widget.currentPlays ? l.tvListOnAir : l.tvListRetune),
            ],
            const SizedBox(height: 20),
            if (iptv != null)
              IptvChannelDetails(channel: iptv, scale: s)
            else if (channel != null)
              _programme(context, channel, s),
          ],
        ),
      ),
    );
  }

  Widget _programme(BuildContext context, E2Channel channel, double s) {
    final l = context.l10n;
    final nowNext = ref.watch(tvNowNextProvider);
    final t = DateTime.now();
    final nn = nowNextFor(nowNext.value ?? const {}, channel, t);
    final full = _later[channel.ref];
    // The EPG's entry of the programme on now may tell more.
    var now = nn.now;
    final fullNow = full?.where((e) => e.runsAt(t)).firstOrNull;
    if (fullNow != null && (now == null || fullNow.description.length > now.description.length)) now = fullNow;
    var after = [
      ...?full?.where((e) => e.begin.isAfter(t) || (now != null && !e.begin.isBefore(now.end))),
    ].take(_laterCount).toList();
    if (after.isEmpty && nn.next != null) after = [nn.next!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (now != null)
          TvProgrammeDetails(event: now, scale: s, descriptionLines: 6, barWidth: null, timeColour: Colors.white)
        else
          Text(nowNext.hasValue ? l.tvNoProgramInfo : l.commonLoading,
              style: TextStyle(color: Colors.white54, fontSize: 18 * s)),
        if (after.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(l.tvListLater,
              style: TextStyle(color: Colors.white54, fontSize: 14 * s, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final e in after)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64 * s,
                    child: Text(hhmm(e.begin), style: TextStyle(color: Colors.white, fontSize: 17 * s)),
                  ),
                  Expanded(
                    child: Text(e.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white70, fontSize: 17 * s)),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// "Läuft gerade" / "Kein Bild" - what OK does on the channel on air.
class _OnAir extends StatelessWidget {
  const _OnAir({required this.plays, required this.text});

  final bool plays;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = plays ? brandGreen : Colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(plays ? Icons.play_circle_outline : Icons.replay, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: TextStyle(color: color, fontSize: 14))),
        ],
      ),
    );
  }
}
