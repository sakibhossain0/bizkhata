import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A shop's mark: its own logo (Settings → Business profile) when one is set
/// and the file is on this device, otherwise its business type's icon.
class ShopMark extends StatelessWidget {
  /// The logo file's path, as kept in the `logo_path` setting.
  final String? logo;

  /// The business type's icon (an emoji), shown when there's no logo.
  final String icon;
  final double size;
  final double radius;
  const ShopMark({super.key, this.logo, required this.icon, this.size = 36, this.radius = 10});

  bool get _hasLogo {
    final path = logo;
    return path != null && path.isNotEmpty && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Text(icon, style: TextStyle(fontSize: size / 2));
    if (!_hasLogo) {
      return Container(
        key: const ValueKey('shop-mark-icon'),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: C.marigold.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(radius)),
        child: fallback,
      );
    }
    // On white, whole (not cropped): logos come in every shape.
    return Container(
      key: const ValueKey('shop-mark-logo'),
      width: size,
      height: size,
      padding: EdgeInsets.all(size >= 30 ? 3 : 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius)),
      child: Image.file(
        File(logo!),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Center(child: fallback),
      ),
    );
  }
}
