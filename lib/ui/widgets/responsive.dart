import 'dart:io';

import 'package:flutter/material.dart';

/// Breakpoints shared by every screen.
///   phone   < 600   bottom navigation, stacked layouts, list rows as cards
///   compact < 900   one pane at a time (master *or* detail)
///   desktop          sidebar + side-by-side panes
extension Responsive on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  bool get isPhone => screenWidth < 600;
  bool get isCompact => screenWidth < 900;

  /// Page side padding.
  double get gutter => isPhone ? 14 : 28;
}

/// True on phones/tablets (camera scanning, no folders to open, etc.).
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

/// Side-by-side columns on wide screens, stacked on narrow ones.
class SplitView extends StatelessWidget {
  final Widget left;
  final Widget right;
  final int leftFlex;
  final int rightFlex;
  final double gap;
  final double breakpoint;

  /// When stacked, show [right] first (e.g. a summary above a long list).
  final bool rightFirstWhenStacked;
  const SplitView({
    super.key,
    required this.left,
    required this.right,
    this.leftFlex = 3,
    this.rightFlex = 2,
    this.gap = 16,
    this.breakpoint = 900,
    this.rightFirstWhenStacked = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < breakpoint) {
        final first = rightFirstWhenStacked ? right : left;
        final second = rightFirstWhenStacked ? left : right;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [first, SizedBox(height: gap), second]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: leftFlex, child: left),
        SizedBox(width: gap),
        Expanded(flex: rightFlex, child: right),
      ]);
    });
  }
}

/// Drop-in for `Row(crossAxisAlignment: start, children: [Expanded(...), Gap(16), Expanded(...)])`:
/// a row on wide screens, the same children stacked (Expanded unwrapped) on
/// narrow ones. Only use inside scrollables (stacked height is unbounded).
class AdaptiveRow extends StatelessWidget {
  final List<Widget> children;
  final double breakpoint;
  const AdaptiveRow({super.key, required this.children, this.breakpoint = 900});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= breakpoint) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final w in children) w is Flexible ? w.child : w,
      ]);
    });
  }
}

/// A row of form fields that stacks into a column when there isn't room.
class FieldRow extends StatelessWidget {
  final List<Widget> children;
  final List<int>? flex;
  final double gap;
  final double minFieldWidth;
  const FieldRow({super.key, required this.children, this.flex, this.gap = 12, this.minFieldWidth = 170});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final fits = c.maxWidth >= minFieldWidth * children.length + gap * (children.length - 1);
      if (!fits) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(flex: flex?[i] ?? 1, child: children[i]),
        ],
      ]);
    });
  }
}

/// Equal-width tiles: as many per row as fit [minItemWidth].
class AutoGrid extends StatelessWidget {
  final List<Widget> children;
  final double minItemWidth;
  final double gap;
  final int maxColumns;
  const AutoGrid({super.key, required this.children, this.minItemWidth = 200, this.gap = 12, this.maxColumns = 6});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      var cols = ((c.maxWidth + gap) / (minItemWidth + gap)).floor().clamp(1, maxColumns);
      if (cols > children.length) cols = children.length.clamp(1, maxColumns);
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
    });
  }
}
