import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// [CachedNetworkImage] that keeps retrying a failed load on its own (10s,
/// 20s, 40s, ... capped at 2 minutes) instead of showing its error widget
/// for good - on an autostart right after boot the network often isn't up
/// yet, which used to leave station logos stuck on the placeholder until
/// the station was changed.
class RetryingNetworkImage extends StatefulWidget {
  const RetryingNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    required this.errorWidget,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final WidgetBuilder? placeholder;
  final WidgetBuilder errorWidget;

  @override
  State<RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<RetryingNetworkImage> {
  Timer? _retryTimer;
  int _failedAttempts = 0;
  // Bumped per retry - a new key forces a fresh CachedNetworkImage (and
  // with it a fresh load attempt) rather than reusing the failed one.
  int _attempt = 0;

  @override
  void didUpdateWidget(covariant RetryingNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _failedAttempts = 0;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    final delaySeconds = (10 * (1 << _failedAttempts)).clamp(10, 120);
    _failedAttempts = (_failedAttempts + 1).clamp(0, 4);
    final url = widget.imageUrl;
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!mounted || widget.imageUrl != url) return;
      // Drop the failed entry from Flutter's in-memory image cache so the
      // next attempt really goes back to the network.
      CachedNetworkImageProvider(url).evict();
      setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.placeholder;
    return CachedNetworkImage(
      key: ValueKey('${widget.imageUrl}#$_attempt'),
      imageUrl: widget.imageUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder: placeholder == null ? null : (context, _) => placeholder(context),
      errorWidget: (context, _, _) {
        _scheduleRetry();
        return widget.errorWidget(context);
      },
    );
  }
}
