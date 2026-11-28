import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../launcher_service.dart';

/// A Windows app's id as a launcher tile stores it (in place of an Android
/// package): [windowsAppPrefix] + the app's AppID in the Start menu's "All
/// apps" (shell:AppsFolder) - desktop programs, Store apps, Steam games and
/// web apps alike - or, when PowerShell can't list them, [windowsShortcutPrefix]
/// + the path of the Start menu shortcut (.lnk/.url) itself. Android package
/// names never contain a colon, so the two can't be mixed up.
const windowsAppPrefix = 'win:';
const windowsShortcutPrefix = 'lnk:';

bool isWindowsAppId(String id) => id.startsWith(windowsAppPrefix) || id.startsWith(windowsShortcutPrefix);

/// Whether an app tile's [package] can be started on this platform: Android
/// packages on Android, Windows apps on Windows, nothing elsewhere.
bool appIdBelongsHere(String package, {required bool android, required bool windows}) {
  if (package.isEmpty) return false;
  if (android) return !isWindowsAppId(package);
  if (windows) return isWindowsAppId(package);
  return false;
}

/// Start menu entries that aren't apps: uninstallers, help, readmes,
/// licences, websites (German and English names).
final _notAnAppName = RegExp(
  r'unins|deinstall|\bentfernen\b|read ?me|lies ?mich|\bhelp\b|\bhilfe\b|handbuch|manual|anleitung|'
  r'documentation|dokumentation|\bfaqs?\b|licen[cs]e|lizenz|\beula\b|release notes|changelog|'
  r"what'?s new|revision history|web ?site|webseite|homepage|on the web|im web|privacy",
  caseSensitive: false,
);

/// Targets that are documents, not programs.
const _documentExtensions = {
  '.chm', '.hlp', '.txt', '.pdf', '.rtf', '.htm', '.html', '.md', '.url', '.doc', '.docx', '.xps', '.log', '.nfo', //
  '.ini',
};

final _webUrl = RegExp(r'^(https?|ftp|mailto|file):', caseSensitive: false);

/// Whether a Start menu entry called [name] with AppID/target [target] is an
/// app worth a tile - not an uninstaller, help file, readme or website, and
/// not Home System itself.
bool isWindowsAppEntry(String name, String target) {
  final label = name.trim();
  if (label.isEmpty || target.trim().isEmpty) return false;
  if (_notAnAppName.hasMatch(label)) return false;
  final t = target.trim();
  if (_webUrl.hasMatch(t)) return false;
  // steam://rungameid/... and the like are apps; only paths have extensions.
  if (!t.contains('://')) {
    final ext = p.windows.extension(t).toLowerCase();
    if (_documentExtensions.contains(ext)) return false;
    if (p.windows.basename(t).toLowerCase() == 'home_system.exe') return false;
  }
  if (label.toLowerCase() == 'home system') return false;
  return true;
}

/// The apps in Get-StartApps' JSON (`[{"n": name, "id": AppID}, ...]`, a
/// single object for one app) - filtered ([isWindowsAppEntry]), each AppID
/// once, sorted by name.
List<InstalledApp> parseStartApps(String json) {
  Object? decoded;
  try {
    decoded = jsonDecode(json.trim().isEmpty ? '[]' : json.trim());
  } catch (_) {
    return const [];
  }
  final list = decoded is List ? decoded : (decoded is Map ? [decoded] : const []);
  final apps = <InstalledApp>[];
  final seen = <String>{};
  for (final e in list.whereType<Map<Object?, Object?>>()) {
    final name = e['n'] ?? e['Name'];
    final id = e['id'] ?? e['AppID'];
    if (name is! String || id is! String) continue;
    if (!isWindowsAppEntry(name, id) || !seen.add(id.toLowerCase())) continue;
    apps.add(InstalledApp(package: '$windowsAppPrefix$id', label: name.trim(), tv: false));
  }
  return sortWindowsApps(apps);
}

List<InstalledApp> sortWindowsApps(List<InstalledApp> apps) =>
    apps..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

/// The URL= line of an Internet shortcut (.url), null if there's none.
String? internetShortcutUrl(String content) {
  for (final line in const LineSplitter().convert(content)) {
    final l = line.trim();
    if (l.toLowerCase().startsWith('url=')) return l.substring(4).trim();
  }
  return null;
}

/// File name of an app's cached icon - a stable hash of its id (FNV-1a, 64 bit).
String windowsAppIconFileName(String id) {
  // 64-bit ints wrap around on the VM - exactly FNV's arithmetic.
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(id)) {
    hash ^= unit;
    hash *= 0x100000001b3;
  }
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${half(hash >> 32)}${half(hash)}.png';
}

/// A PowerShell string literal ('...', quotes doubled).
String powerShellQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// The argument of `powershell -EncodedCommand`: base64 of UTF-16LE.
String powerShellEncode(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

/// The Windows side of the launcher's apps: what's in the Start menu, its
/// icons (cached as PNG files) and starting it. Everything runs in the
/// background (PowerShell, without a window) and answers "nothing" on
/// errors - it never throws.
class WindowsApps {
  List<InstalledApp>? _apps;
  DateTime? _listedAt;

  /// The list came from the Start menu's AppsFolder - an AppID missing from
  /// it is really gone.
  bool _complete = false;
  Future<List<InstalledApp>>? _listing;

  static String get _systemRoot => Platform.environment['SystemRoot'] ?? r'C:\Windows';

  static String get _powerShell {
    final path = p.join(_systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    return File(path).existsSync() ? path : 'powershell.exe';
  }

  static String get _explorer {
    final path = p.join(_systemRoot, 'explorer.exe');
    return File(path).existsSync() ? path : 'explorer.exe';
  }

  /// The installed apps, read again (one listing at a time; the last
  /// result stays for [launch]).
  Future<List<InstalledApp>> list() => _listing ??= _list().whenComplete(() => _listing = null);

  /// Reads the list in the background if there's none yet - so the first
  /// tile started doesn't wait for it. A few seconds after the start, so it
  /// doesn't slow the start down (a tile started before waits for it).
  void warmUp() {
    if (_warmUp != null || _apps != null) return;
    _warmUp = Timer(const Duration(seconds: 5), () {
      if (_apps == null) unawaited(list());
    });
  }

  Timer? _warmUp;

  Future<List<InstalledApp>> _list() async {
    try {
      final fromShell = await _startApps();
      if (fromShell != null) {
        _apps = fromShell;
        _complete = true;
      } else {
        _apps = await startMenuShortcuts();
        _complete = false;
      }
      _listedAt = DateTime.now();
      return _apps!;
    } catch (e) {
      debugPrint('Windows apps: $e');
      return _apps ?? const [];
    }
  }

  Future<Directory> _workDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'app_icons'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Runs [script] in a hidden PowerShell; true if it ended by itself with 0.
  static Future<bool> _runPowerShell(String script, Duration timeout) async {
    Process? process;
    try {
      process = await Process.start(_powerShell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        powerShellEncode(script),
      ]);
      unawaited(process.stdout.drain<void>().catchError((_) {}));
      unawaited(process.stderr.drain<void>().catchError((_) {}));
      return await process.exitCode.timeout(timeout) == 0;
    } on TimeoutException {
      process?.kill();
      return false;
    } catch (e) {
      debugPrint('Windows apps: PowerShell: $e');
      return false;
    }
  }

  /// "All apps" of the Start menu: Get-StartApps (localised names, Store
  /// apps too), else the AppsFolder through the shell. Null if PowerShell
  /// doesn't work here.
  Future<List<InstalledApp>?> _startApps() async {
    final out = File(p.join((await _workDir()).path, 'apps_${DateTime.now().microsecondsSinceEpoch}.json'));
    final script = '''
\$ErrorActionPreference = 'Stop'
try {
  \$apps = @(Get-StartApps | ForEach-Object { [pscustomobject]@{ n = \$_.Name; id = \$_.AppID } })
} catch {
  \$apps = @((New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | ForEach-Object { [pscustomobject]@{ n = \$_.Name; id = \$_.Path } })
}
[IO.File]::WriteAllText(${powerShellQuote(out.path)}, (ConvertTo-Json -InputObject \$apps -Compress), (New-Object Text.UTF8Encoding \$false))
''';
    try {
      if (!await _runPowerShell(script, const Duration(seconds: 30))) return null;
      if (!await out.exists()) return null;
      return parseStartApps(await out.readAsString());
    } catch (e) {
      debugPrint('Windows apps: start apps: $e');
      return null;
    } finally {
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
    }
  }

  static List<Directory> get _startMenuDirs => [
        for (final base in [Platform.environment['APPDATA'], Platform.environment['ProgramData']])
          if (base != null && base.isNotEmpty) Directory(p.join(base, 'Microsoft', 'Windows', 'Start Menu', 'Programs')),
      ];

  /// Without PowerShell: the shortcuts in both Start menu folders (the
  /// user's and everyone's) - .lnk, and .url ones that start a program
  /// (steam://...), not websites. Named as the file is.
  @visibleForTesting
  Future<List<InstalledApp>> startMenuShortcuts() async {
    final apps = <InstalledApp>[];
    final labels = <String>{};
    for (final dir in _startMenuDirs) {
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false).handleError((_) {})) {
          if (entity is! File) continue;
          final ext = p.extension(entity.path).toLowerCase();
          if (ext != '.lnk' && ext != '.url') continue;
          // Autostart entries aren't apps of their own.
          if (p.split(p.relative(entity.path, from: dir.path)).first.toLowerCase() == 'startup') continue;
          final label = p.basenameWithoutExtension(entity.path);
          var target = entity.path;
          if (ext == '.url') {
            try {
              // An INI file, often ANSI - the URL itself is ASCII.
              target = internetShortcutUrl(await entity.readAsString(encoding: latin1)) ?? '';
            } catch (_) {
              continue;
            }
          }
          // A .lnk's own target is unknown here - only its name counts.
          if (!isWindowsAppEntry(label, ext == '.lnk' ? label : target)) continue;
          if (!labels.add(label.toLowerCase())) continue;
          apps.add(InstalledApp(package: '$windowsShortcutPrefix${entity.path}', label: label, tv: false));
        }
      } catch (e) {
        debugPrint('Windows apps: ${dir.path}: $e');
      }
    }
    return sortWindowsApps(apps);
  }

  /// What explorer.exe opens for [id], null if the app isn't (any more) there.
  Future<String?> _target(String id) async {
    if (id.startsWith(windowsShortcutPrefix)) {
      final path = id.substring(windowsShortcutPrefix.length);
      try {
        return path.isNotEmpty && await File(path).exists() ? path : null;
      } catch (_) {
        return null;
      }
    }
    if (!id.startsWith(windowsAppPrefix)) return null;
    final appId = id.substring(windowsAppPrefix.length);
    if (appId.isEmpty) return null;
    bool known() => _apps?.any((a) => a.package == id) ?? false;
    if (_apps == null) {
      await list();
    } else if (!known() && DateTime.now().difference(_listedAt ?? DateTime(2000)) > const Duration(seconds: 30)) {
      // Installed since the last look?
      await list();
    } else if (DateTime.now().difference(_listedAt ?? DateTime(2000)) > const Duration(minutes: 10)) {
      unawaited(list());
    }
    // Without the full list (no PowerShell) explorer.exe gets it anyway.
    if (_complete && !known()) return null;
    return 'shell:AppsFolder\\$appId';
  }

  /// Starts the app on its own (it doesn't end with Home System). False if
  /// it isn't installed (any more) or couldn't be started.
  Future<bool> launch(String id) async {
    try {
      final target = await _target(id);
      if (target == null) return false;
      await Process.start(_explorer, [target], mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      debugPrint('Windows apps: start $id: $e');
      return false;
    }
  }

  // --- Icons -----------------------------------------------------------

  final _waiting = <String, ({String source, String png, Completer<AppImage?> done})>{};
  final _failed = <String>{};
  Timer? _batchTimer;
  bool _extracting = false;

  static String? _iconSource(String id) {
    if (id.startsWith(windowsShortcutPrefix)) return id.substring(windowsShortcutPrefix.length);
    if (id.startsWith(windowsAppPrefix)) return 'shell:AppsFolder\\${id.substring(windowsAppPrefix.length)}';
    return null;
  }

  /// The app's icon: from the cache, else extracted with the next batch.
  /// Null if Windows has none for it.
  Future<AppImage?> icon(String id) async {
    try {
      final source = _iconSource(id);
      if (source == null || _failed.contains(id)) return null;
      final png = File(p.join((await _workDir()).path, windowsAppIconFileName(id)));
      if (await png.exists() && !await _outdated(id, png)) {
        return AppImage(await png.readAsBytes(), banner: false);
      }
      final waiting = _waiting[id];
      if (waiting != null) return waiting.done.future;
      final done = Completer<AppImage?>();
      _waiting[id] = (source: source, png: png.path, done: done);
      _scheduleBatch();
      return done.future;
    } catch (e) {
      debugPrint('Windows apps: icon $id: $e');
      return null;
    }
  }

  /// A shortcut changed after its icon was saved (app updated), or the icon
  /// is a month old.
  Future<bool> _outdated(String id, File png) async {
    try {
      final saved = await png.lastModified();
      if (DateTime.now().difference(saved) > const Duration(days: 30)) return true;
      if (id.startsWith(windowsShortcutPrefix)) {
        final link = File(id.substring(windowsShortcutPrefix.length));
        if (await link.exists() && (await link.lastModified()).isAfter(saved)) return true;
      }
    } catch (_) {}
    return false;
  }

  void _scheduleBatch() {
    if (_extracting) return;
    _batchTimer?.cancel();
    // The tiles on screen ask within a frame or two - one PowerShell for all.
    _batchTimer = Timer(const Duration(milliseconds: 120), () => unawaited(_extractBatch()));
  }

  Future<void> _extractBatch() async {
    if (_extracting || _waiting.isEmpty) return;
    _extracting = true;
    final batch = Map.of(_waiting);
    File? jobs;
    try {
      final dir = await _workDir();
      jobs = File(p.join(dir.path, 'jobs_${DateTime.now().microsecondsSinceEpoch}.txt'));
      await jobs.writeAsString(
        [for (final job in batch.values) '${job.source}\t${job.png}'].join('\n'),
        encoding: utf8,
      );
      await _runPowerShell(_iconScript(jobs.path), Duration(seconds: 20 + batch.length));
    } catch (e) {
      debugPrint('Windows apps: icons: $e');
    } finally {
      try {
        if (jobs != null && await jobs.exists()) await jobs.delete();
      } catch (_) {}
    }
    for (final MapEntry(key: id, value: job) in batch.entries) {
      _waiting.remove(id);
      AppImage? image;
      try {
        final png = File(job.png);
        if (await png.exists()) image = AppImage(await png.readAsBytes(), banner: false);
      } catch (_) {}
      if (image == null) _failed.add(id);
      job.done.complete(image);
    }
    _extracting = false;
    if (_waiting.isNotEmpty) _scheduleBatch();
  }

  /// Saves every job's icon (`source<TAB>png` per line) as a PNG: the
  /// shell's own picture of the item (as Explorer shows it, up to 256 px,
  /// a small icon cut out of its empty canvas), else the icon of the
  /// shortcut's file.
  static String _iconScript(String jobsPath) => '''
\$ErrorActionPreference = 'Stop'
\$shell = \$true
try {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
$_iconCSharp
'@
} catch { \$shell = \$false }
Add-Type -AssemblyName System.Drawing
foreach (\$line in [IO.File]::ReadAllLines(${powerShellQuote(jobsPath)}, [Text.Encoding]::UTF8)) {
  \$parts = \$line.Split("`t")
  if (\$parts.Length -lt 2) { continue }
  try {
    if (\$shell) { [HsAppIcon]::Save(\$parts[0], \$parts[1], 256); continue }
  } catch {}
  try {
    if (Test-Path -LiteralPath \$parts[0]) {
      \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon(\$parts[0])
      \$bmp = \$icon.ToBitmap()
      \$bmp.Save(\$parts[1], [System.Drawing.Imaging.ImageFormat]::Png)
      \$bmp.Dispose(); \$icon.Dispose()
    }
  } catch {}
}
''';
}

/// IShellItemImageFactory (icon only) -> PNG with alpha.
const _iconCSharp = r'''
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class HsAppIcon {
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
  [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; }
  [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType; public int bmWidth; public int bmHeight; public int bmWidthBytes; public ushort bmPlanes; public ushort bmBitsPixel; public IntPtr bmBits; }
  [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount; public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter; public int biClrUsed; public int biClrImportant; }
  [StructLayout(LayoutKind.Sequential)] struct DIBSECTION { public BITMAP dsBm; public BITMAPINFOHEADER dsBmih; public int b0; public int b1; public int b2; public IntPtr dshSection; public int dsOffset; }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
  [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, out DIBSECTION ds);

  public static void Save(string source, string target, int size) {
    IShellItemImageFactory factory;
    SHCreateItemFromParsingName(source, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory);
    IntPtr hbm;
    // SIIGBF_BIGGERSIZEOK | SIIGBF_ICONONLY
    int hr = factory.GetImage(new SIZE { cx = size, cy = size }, 0x1 | 0x4, out hbm);
    Marshal.ReleaseComObject(factory);
    if (hr != 0) Marshal.ThrowExceptionForHR(hr);
    try {
      using (Bitmap bmp = ToBitmap(hbm))
      using (Bitmap trimmed = Trim(bmp)) trimmed.Save(target, ImageFormat.Png);
    } finally {
      DeleteObject(hbm);
    }
  }

  // A small icon comes centred on a big transparent canvas (with a faint
  // frame): cut it out, square, so the tile shows the icon, not a dot.
  static Bitmap Trim(Bitmap bmp) {
    int w = bmp.Width, h = bmp.Height, left = w, top = h, right = -1, bottom = -1;
    BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try {
      int[] row = new int[w];
      for (int y = 0; y < h; y++) {
        Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, w);
        for (int x = 0; x < w; x++) {
          if (((row[x] >> 24) & 0xFF) < 128) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
    } finally {
      bmp.UnlockBits(data);
    }
    if (right < 0) return new Bitmap(bmp);
    int side = Math.Max(right - left + 1, bottom - top + 1);
    side = Math.Min(Math.Min(w, h), side + side / 8);
    if (side * 4 > w * 3) return new Bitmap(bmp);
    int cx = (left + right + 1) / 2, cy = (top + bottom + 1) / 2;
    int sx = Math.Max(0, Math.Min(w - side, cx - side / 2)), sy = Math.Max(0, Math.Min(h - side, cy - side / 2));
    return bmp.Clone(new Rectangle(sx, sy, side, side), PixelFormat.Format32bppArgb);
  }

  static Bitmap ToBitmap(IntPtr hbm) {
    DIBSECTION ds;
    if (GetObject(hbm, Marshal.SizeOf(typeof(DIBSECTION)), out ds) != 0 && ds.dsBm.bmBitsPixel == 32 && ds.dsBm.bmBits != IntPtr.Zero) {
      int w = ds.dsBm.bmWidth, h = ds.dsBm.bmHeight, stride = ds.dsBm.bmWidthBytes;
      using (Bitmap view = new Bitmap(w, h, stride, PixelFormat.Format32bppPArgb, ds.dsBm.bmBits)) {
        Bitmap copy = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(copy)) g.DrawImage(view, 0, 0, w, h);
        if (ds.dsBmih.biHeight > 0) copy.RotateFlip(RotateFlipType.RotateNoneFlipY);
        return copy;
      }
    }
    return Image.FromHbitmap(hbm);
  }
}
''';
