import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/models/favorite_channel.dart';

/// Full-screen background. Phase 1: dark background, optionally with a
/// dimmed station logo. Phase 3 replaces this with FTP-synced photos.
class BackgroundLayer extends StatelessWidget {
  final FavoriteChannel? currentChannel;

  const BackgroundLayer({super.key, this.currentChannel});

  @override
  Widget build(BuildContext context) {
    final channel = currentChannel;
    final logo = channel?.logoLocalPath ?? channel?.logoUrl;

    return Container(
      color: const Color(0xFF05070A),
      child: logo == null
          ? null
          : Opacity(
              opacity: 0.18,
              child: channel!.logoLocalPath != null
                  ? Image.file(File(channel.logoLocalPath!),
                      fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                  : CachedNetworkImage(
                      imageUrl: channel.logoUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
            ),
    );
  }
}
