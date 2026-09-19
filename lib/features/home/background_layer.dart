import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Full-screen background. Phase 1: dark background, optionally with a
/// dimmed station logo. Phase 3 replaces this with FTP-synced photos.
///
/// Takes the plain logo fields rather than a whole FavoriteChannel so a DAB+
/// station played directly from "Alle DAB+ Sender" (not a saved favorite)
/// can use its own persistent logo here too, not just favorites.
class BackgroundLayer extends StatelessWidget {
  final String? logoLocalPath;
  final String? logoUrl;

  const BackgroundLayer({super.key, this.logoLocalPath, this.logoUrl});

  @override
  Widget build(BuildContext context) {
    final localPath = logoLocalPath;
    final url = logoUrl;

    return Container(
      color: const Color(0xFF05070A),
      child: localPath == null && url == null
          ? null
          : Opacity(
              opacity: 0.18,
              child: localPath != null
                  ? Image.file(File(localPath),
                      fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                  : CachedNetworkImage(
                      imageUrl: url!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
            ),
    );
  }
}
