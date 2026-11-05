import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef _EventCallbackNative = Void Function(Pointer<Utf8> json);

/// dart:ffi binding of hrdab.dll / libhrdab.so - the Windows/Linux build of
/// the app's own receiver (android/app/src/main/cpp/desktop, see
/// hrdab_desktop.h). It stands in for the "home_radio/dab_rtlsdr" method and
/// event channels of DabRtlSdrPlugin.kt: [invoke] takes the same method
/// names and arguments, [events] carries the same event maps.
///
/// The native side runs everything on its own threads; calls return at once
/// and their results come back as `__reply` events, which [invoke] turns
/// into the Future's value (or a [PlatformException], like the channel).
class HrdabDesktop {
  HrdabDesktop._() {
    try {
      _lib = DynamicLibrary.open(_libraryPath());
      _init = _lib!.lookupFunction<Void Function(Pointer<NativeFunction<_EventCallbackNative>>, Pointer<Utf8>),
          void Function(Pointer<NativeFunction<_EventCallbackNative>>, Pointer<Utf8>)>('hrdab_init');
      _call = _lib!.lookupFunction<Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>),
          void Function(int, Pointer<Utf8>, Pointer<Utf8>)>('hrdab_call');
      _usbDevices = _lib!.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('hrdab_usb_devices');
      _free = _lib!.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('hrdab_free');
      final version = _lib!.lookupFunction<Int32 Function(), int Function()>('hrdab_api_version')();
      if (version != _apiVersion) throw StateError('hrdab API version $version, expected $_apiVersion');
      _callback = NativeCallable<_EventCallbackNative>.listener(_onNativeEvent);
      _ready = _start();
    } catch (e) {
      debugPrint('hrdab: native receiver not available: $e');
      _lib = null;
      _ready = Future.value();
    }
  }

  static HrdabDesktop? _instance;
  static HrdabDesktop get instance => _instance ??= HrdabDesktop._();

  /// App exit: stops playback/scans and closes the stick or the rtl_tcp
  /// connection cleanly (waits up to 3 s). Does nothing when the receiver
  /// was never used - the library isn't even loaded then.
  static void shutdownIfStarted() {
    final hrdab = _instance;
    if (hrdab == null || hrdab._lib == null) return;
    try {
      hrdab._lib!.lookupFunction<Void Function(), void Function()>('hrdab_shutdown')();
    } catch (e) {
      debugPrint('hrdab: shutdown failed: $e');
    }
  }

  static const _apiVersion = 1;

  DynamicLibrary? _lib;
  late final void Function(Pointer<NativeFunction<_EventCallbackNative>>, Pointer<Utf8>) _init;
  late final void Function(int, Pointer<Utf8>, Pointer<Utf8>) _call;
  late final Pointer<Utf8> Function() _usbDevices;
  late final void Function(Pointer<Utf8>) _free;
  NativeCallable<_EventCallbackNative>? _callback;
  late final Future<void> _ready;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 1;

  /// Whether the native library could be loaded.
  bool get available => _lib != null;

  /// Receiver events, shaped like DabRtlSdrPlugin.kt's EventChannel maps.
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Bundle layout: next to the exe on Windows, in lib/ on Linux (the
  /// runner's RPATH does not apply to dlopen from the Dart VM, hence the
  /// absolute path).
  static String _libraryPath() {
    // Tests (flutter_tester is not in the bundle) point here explicitly.
    final override = Platform.environment['HRDAB_LIBRARY'];
    if (override != null && override.isNotEmpty) return override;
    final dir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) return '$dir\\hrdab.dll';
    final bundled = '$dir/lib/libhrdab.so';
    return File(bundled).existsSync() ? bundled : 'libhrdab.so';
  }

  Future<void> _start() async {
    // Same place as Android's filesDir, where the slideshow images go.
    String dataDir;
    try {
      dataDir = (await getApplicationSupportDirectory()).path;
    } catch (_) {
      dataDir = Directory.systemTemp.path; // no path_provider (tests)
    }
    final dirPtr = dataDir.toNativeUtf8();
    try {
      _init(_callback!.nativeFunction, dirPtr);
    } finally {
      malloc.free(dirPtr);
    }
  }

  void _onNativeEvent(Pointer<Utf8> ptr) {
    final String text;
    try {
      final bytes = ptr.cast<Uint8>().asTypedList(ptr.length);
      // DLS/labels come from broadcast data - never fail on a bad byte.
      text = utf8.decode(bytes, allowMalformed: true);
    } finally {
      _free(ptr);
    }
    final Map<String, dynamic> event;
    try {
      event = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('hrdab: bad event JSON: $e');
      return;
    }
    if (event['type'] == '__reply') {
      final completer = _pending.remove(event['id'] as int);
      if (completer == null) return;
      final error = event['error'] as String?;
      if (error == null) {
        completer.complete(event['value']);
      } else if (error == 'not_implemented') {
        completer.completeError(MissingPluginException(event['message'] as String?));
      } else {
        completer.completeError(PlatformException(code: error, message: event['message'] as String?));
      }
      return;
    }
    _events.add(event);
  }

  /// A "home_radio/dab_rtlsdr" method call, like MethodChannel.invokeMethod.
  /// Without the native library every call yields null (bool results then
  /// read as false through the service's `?? false`).
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    await _ready;
    if (_lib == null) return null;
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final methodPtr = method.toNativeUtf8();
    final argsPtr = jsonEncode(arguments ?? const <String, dynamic>{}).toNativeUtf8();
    try {
      _call(id, methodPtr, argsPtr);
    } finally {
      malloc.free(methodPtr);
      malloc.free(argsPtr);
    }
    return await completer.future as T?;
  }

  /// RTL-SDR sticks libusb can see (RtlSdrUsbService.listDevices' maps).
  List<Map<String, dynamic>> usbDevices() {
    if (_lib == null) return const [];
    final ptr = _usbDevices();
    if (ptr == nullptr) return const [];
    try {
      return (jsonDecode(ptr.toDartString()) as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      debugPrint('hrdab: bad device list: $e');
      return const [];
    } finally {
      _free(ptr);
    }
  }
}
