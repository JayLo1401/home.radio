// The browser's ad/tracker blocker, part 2: deciding requests and finding a
// page's cosmetic filters and scriptlets - the reference for (and kept in
// step with) android/.../browser/AdblockEngine.kt, which does the same on
// the device. Used by the tests; the app itself matches natively.
import 'adblock_compiler.dart';

/// The URL's host (lower case, without port), '' if there is none.
String adblockHostOf(String url) {
  final u = url.toLowerCase();
  final scheme = u.indexOf('://');
  if (scheme < 0) return '';
  final start = scheme + 3;
  var end = start;
  while (end < u.length) {
    final c = u.codeUnitAt(end);
    if (c == 0x2f || c == 0x3f || c == 0x23 || c == 0x3a) break; // / ? # :
    end++;
  }
  final host = u.substring(start, end);
  final at = host.lastIndexOf('@');
  return at < 0 ? host : host.substring(at + 1);
}

/// "example.co.uk" for "www.example.co.uk" - without a public suffix list:
/// the last two labels, three under a known second level (co.uk, gv.at).
String registrableDomain(String host) {
  if (host.isEmpty || host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) return host;
  final labels = host.split('.');
  if (labels.length <= 2) return host;
  final tld = labels[labels.length - 1];
  final sld = labels[labels.length - 2];
  final take = tld.length == 2 && _secondLevels.contains(sld) ? 3 : 2;
  return labels.sublist(labels.length - take).join('.');
}

const _secondLevels = {
  'co', 'com', 'net', 'org', 'gov', 'ac', 'edu', 'or', 'gv', 'ne', 'go', 'lg', 'ltd', 'plc', 'sch', 'nic', 'mil',
  'gob', 'nom',
};

/// [host] and its parent domains: a.b.c, b.c, c.
List<String> hostCandidates(String host) {
  final out = <String>[];
  var h = host;
  while (h.isNotEmpty) {
    out.add(h);
    final dot = h.indexOf('.');
    if (dot < 0) break;
    h = h.substring(dot + 1);
  }
  return out;
}

/// uBlock's "entity" names a host can be meant by: `google.*` for
/// www.google.co.uk (one label taken as the public suffix, two under a
/// known second level like co.uk / gv.at).
List<String> entityKeys(String host) {
  final labels = host.split('.');
  final n = labels.length;
  // The public suffix: one label, or two under a known second level.
  final suffix = n >= 3 && labels[n - 1].length == 2 && _secondLevels.contains(labels[n - 2]) ? 2 : 1;
  final out = <String>[];
  for (var i = 0; i < n - 1; i++) {
    for (var s = 1; s <= suffix; s++) {
      if (i > n - 1 - s) continue;
      out.add('${labels.sublist(i, n - s).join('.')}.*');
    }
  }
  return out;
}

/// The keys cosmetic filters and scriptlets are stored under for [host].
List<String> lookupKeys(String host) => [...hostCandidates(host), ...entityKeys(host)];

/// Whether [domain] (`host`, `name.*`) covers [host].
bool domainCovers(String domain, String host) {
  if (host.isEmpty) return false;
  if (domain.endsWith('.*')) return entityKeys(host).contains(domain);
  return host == domain || host.endsWith('.$domain');
}

bool _isSeparator(int c) {
  // Anything but a letter, digit, '_', '-', '.', '%'.
  if (c >= 0x61 && c <= 0x7a) return false;
  if (c >= 0x30 && c <= 0x39) return false;
  if (c >= 0x41 && c <= 0x5a) return false;
  return !(c == 0x5f || c == 0x2d || c == 0x2e || c == 0x25);
}

/// Where [seg] matched at [pos] of [url] ends, -1 if it doesn't. `^` is a
/// separator character or the end of the URL.
int _matchAt(String seg, String url, int pos) {
  var i = pos;
  for (var k = 0; k < seg.length; k++) {
    final c = seg.codeUnitAt(k);
    if (c == 0x5e) {
      // '^'
      if (i == url.length) {
        // The end: only more '^' may follow.
        for (var r = k + 1; r < seg.length; r++) {
          if (seg.codeUnitAt(r) != 0x5e) return -1;
        }
        return i;
      }
      if (!_isSeparator(url.codeUnitAt(i))) return -1;
      i++;
    } else {
      if (i >= url.length || url.codeUnitAt(i) != c) return -1;
      i++;
    }
  }
  return i;
}

bool _rest(List<String> segs, int index, String url, int pos, bool endAnchor) {
  var p = pos;
  for (var j = index; j < segs.length; j++) {
    final seg = segs[j];
    final last = j == segs.length - 1;
    if (last && endAnchor) {
      for (var s = p; s <= url.length; s++) {
        if (_matchAt(seg, url, s) == url.length) return true;
      }
      return false;
    }
    var found = -1;
    for (var s = p; s <= url.length; s++) {
      final e = _matchAt(seg, url, s);
      if (e >= 0) {
        found = e;
        break;
      }
    }
    if (found < 0) return false;
    p = found;
  }
  return !endAnchor || p == url.length;
}

/// Whether the compiled [pattern] (see [NetRule.pattern]) matches the
/// lower-case [url] whose host runs from [hostStart] to [hostEnd].
bool patternMatches(String pattern, String url, int hostStart, int hostEnd) {
  var body = pattern;
  var hostAnchor = false;
  var startAnchor = false;
  var endAnchor = false;
  if (body.startsWith('||')) {
    hostAnchor = true;
    body = body.substring(2);
  } else if (body.startsWith('|')) {
    startAnchor = true;
    body = body.substring(1);
  }
  if (body.endsWith('|')) {
    endAnchor = true;
    body = body.substring(0, body.length - 1);
  }
  final segs = body.split('*');
  if (hostAnchor || startAnchor) {
    final starts = <int>[];
    if (startAnchor) {
      starts.add(0);
    } else {
      for (var p = hostStart; p < hostEnd; p++) {
        if (p == hostStart || url.codeUnitAt(p - 1) == 0x2e) starts.add(p);
      }
    }
    for (final s in starts) {
      if (segs.length == 1 && endAnchor) {
        if (_matchAt(segs[0], url, s) == url.length) return true;
        continue;
      }
      final e = _matchAt(segs[0], url, s);
      if (e < 0) continue;
      if (segs.length == 1) return true;
      if (_rest(segs, 1, url, e, endAnchor)) return true;
    }
    return false;
  }
  return _rest(segs, 0, url, 0, endAnchor);
}

/// The URL's words (runs of a-z, 0-9, %) - what rules are indexed by.
Iterable<String> urlTokens(String url) sync* {
  var start = -1;
  for (var i = 0; i <= url.length; i++) {
    final c = i < url.length ? url.codeUnitAt(i) : 0;
    final word = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x25;
    if (word) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      yield url.substring(start, i);
      start = -1;
    }
  }
}

/// What a page gets from the cosmetic filters.
class CosmeticResult {
  const CosmeticResult({this.selectors = const [], this.generic = false});

  /// Hidden right away: site-specific and the generic ones without a
  /// class/id key.
  final List<String> selectors;

  /// Whether generic class/id selectors apply ([AdblockMatcher.genericFor]).
  final bool generic;
}

/// Decides requests and finds cosmetic filters / scriptlets on
/// [AdblockData].
class AdblockMatcher {
  AdblockMatcher(this.data) {
    for (final r in data.netRules) {
      (r.token.isEmpty ? _noToken : (_byToken[r.token] ??= [])).add(r);
    }
  }

  final AdblockData data;
  final _byToken = <String, List<NetRule>>{};
  final _noToken = <NetRule>[];

  /// The page-level exception letters ([PageFlag]) for [host].
  String pageFlags(String host) {
    final out = StringBuffer();
    for (final h in hostCandidates(host)) {
      out.write(data.pageFlags[h] ?? '');
    }
    return out.toString();
  }

  /// Whether the request for [url] (of [type], see [AdType]) on the page
  /// [pageHost] is blocked. Main-frame navigations are never asked.
  bool shouldBlock(String url, String pageHost, int type) {
    final u = url.toLowerCase();
    final host = adblockHostOf(u);
    if (host.isEmpty) return false;
    if (pageFlags(pageHost).contains(PageFlag.document)) return false;
    final hostStart = u.indexOf(host, u.indexOf('://') + 3);
    final hostEnd = hostStart + host.length;
    final third = pageHost.isEmpty || registrableDomain(host) != registrableDomain(pageHost);
    final candidates = hostCandidates(host);

    var blocked = host != pageHost && candidates.any(data.blockHosts.contains);
    var important = false;
    var allowed = candidates.any(data.allowHosts.contains);

    bool applies(NetRule r) {
      if (r.types & type == 0) return false;
      if (r.party == 1 && third) return false;
      if (r.party == 3 && !third) return false;
      if (r.domains.isNotEmpty) {
        var hasInclude = false;
        var included = false;
        for (final d in r.domains) {
          if (d.startsWith('~')) {
            if (domainCovers(d.substring(1), pageHost)) return false;
          } else {
            hasInclude = true;
            if (domainCovers(d, pageHost)) included = true;
          }
        }
        if (hasInclude && !included) return false;
      }
      return patternMatches(r.pattern, u, hostStart, hostEnd);
    }

    void check(NetRule r) {
      switch (r.kind) {
        case NetKind.important:
          if (!important && applies(r)) important = true;
        case NetKind.block:
          if (!blocked && applies(r)) blocked = true;
        case NetKind.allow:
          if (!allowed && applies(r)) allowed = true;
      }
    }

    final seen = <String>{};
    for (final t in urlTokens(u)) {
      if (!seen.add(t)) continue;
      final rules = _byToken[t];
      if (rules == null) continue;
      rules.forEach(check);
    }
    _noToken.forEach(check);
    if (important) return true;
    return blocked && !allowed;
  }

  Set<String> _exceptions(String host) => {
        for (final k in lookupKeys(host)) ...?data.cssExceptions[k],
      };

  /// The page's cosmetic filters at the start.
  CosmeticResult cosmetic(String host) {
    final flags = pageFlags(host);
    if (flags.contains(PageFlag.document) || flags.contains(PageFlag.elemhide)) return const CosmeticResult();
    final except = _exceptions(host);
    final out = <String>[];
    if (!flags.contains(PageFlag.specifichide)) {
      for (final k in lookupKeys(host)) {
        for (final s in data.specificCss[k] ?? const <String>[]) {
          if (!except.contains(s) && !out.contains(s)) out.add(s);
        }
      }
    }
    final generic = !flags.contains(PageFlag.generichide);
    if (generic) out.addAll(data.genericHigh.where((s) => !except.contains(s)));
    return CosmeticResult(selectors: out, generic: generic);
  }

  /// Generic selectors for classes/ids the page has ('.name', '#name').
  List<String> genericFor(String host, Iterable<String> keys) {
    final except = _exceptions(host);
    return [
      for (final k in keys)
        for (final s in data.genericKeyed[k] ?? const <String>[])
          if (!except.contains(s)) s,
    ];
  }

  /// The scriptlets (JSON arrays) to run on [host].
  List<String> scriptletsFor(String host) {
    final flags = pageFlags(host);
    if (flags.contains(PageFlag.document) ||
        flags.contains(PageFlag.elemhide) ||
        flags.contains(PageFlag.specifichide)) {
      return const [];
    }
    final keys = lookupKeys(host);
    final except = {for (final k in keys) ...?data.scriptletExceptions[k]};
    if (except.contains('')) return const [];
    final out = <String>[];
    for (final k in [...keys, '*']) {
      for (final s in data.scriptlets[k] ?? const <String>[]) {
        if (!except.contains(s) && !out.contains(s)) out.add(s);
      }
    }
    return out;
  }
}
