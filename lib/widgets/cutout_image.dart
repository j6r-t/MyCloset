import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// A garment cutout loaded from disk, presented on a `tile` background.
///
/// Never crops the garment (design.md section 8): BoxFit.contain inside the
/// available box. If the file is missing or unreadable (deleted after a
/// restore, partial backup) a quiet icon placeholder shows instead of an
/// error frame.
class CutoutImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  final double iconSize;

  const CutoutImage({
    super.key,
    required this.path,
    this.fit = BoxFit.contain,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Image.file(
      File(path),
      fit: fit,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => Center(
        child: Icon(
          AppIcons.hanger,
          size: iconSize,
          color: c.hairline,
        ),
      ),
    );
  }
}
