import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import 'responsive.dart';

export 'responsive.dart';

// ---------------------------------------------------------------- feedback

void toast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  final phone = MediaQuery.sizeOf(context).width < 600;
  m.showSnackBar(SnackBar(
    // Fixed width on desktop; phones use the full width above the bottom bar.
    width: phone ? null : 420,
    content: Row(children: [
      Icon(error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
          color: error ? const Color(0xFFFFB4A6) : const Color(0xFF9BE3B9), size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(message)),
    ]),
    duration: Duration(milliseconds: error ? 4500 : 2500),
  ));
}

/// Run an action, show its error as a toast. Returns true on success.
Future<bool> guard(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) toast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e), error: true);
    return false;
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmLabel,
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(message, style: Txt.body.copyWith(color: C.ink2)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: C.outRed) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel ?? T.confirm.s),
        ),
      ],
    ),
  );
  return r ?? false;
}

// ---------------------------------------------------------------- layout

class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.leading});

  @override
  Widget build(BuildContext context) {
    final g = context.gutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(g, context.isPhone ? 14 : 22, g, 14),
      child: LayoutBuilder(builder: (context, c) {
        final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Txt.display(context.isPhone ? 22 : 26), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Txt.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ]);
        // Phones: title on top, actions below across the full width.
        if (c.maxWidth < 600) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              Expanded(child: titleBlock),
            ]),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
            ],
          ]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(child: titleBlock),
            const SizedBox(width: 16),
            // Actions wrap onto a second line instead of overflowing on small windows.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: c.maxWidth * 0.7),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ),
          ],
        );
      }),
    );
  }
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final String? title;
  final Widget? trailing;
  final Color? color;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.title, this.trailing, this.color});

  @override
  Widget build(BuildContext context) {
    // Material (not a decorated Container) so ListTiles/ink inside stay visible.
    return Material(
      color: color ?? C.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
              child: Row(children: [
                Expanded(child: Text(title!, style: Txt.strong.copyWith(fontSize: 15))),
                ?trailing,
              ]),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Tone tone;
  final String? hint;
  final VoidCallback? onTap;
  final bool emphasize;
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = Tone.neutral,
    this.hint,
    this.onTap,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = emphasize ? C.brand : C.card;
    final fg = emphasize ? Colors.white : C.ink;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: emphasize ? C.brand : C.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: emphasize ? Colors.white.withValues(alpha: 0.12) : tone.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: emphasize ? C.marigold : tone.fg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: Txt.label.copyWith(color: emphasize ? Colors.white.withValues(alpha: 0.78) : C.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: Txt.display(26, color: fg)),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint!,
                  style: Txt.tiny.copyWith(color: emphasize ? Colors.white.withValues(alpha: 0.65) : C.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Tone tone;
  final IconData? icon;
  const Pill(this.text, {super.key, this.tone = Tone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(6)),
      // Text.rich (not a Row) so a long pill ellipsizes in tight cells but
      // still sizes to its content where width is unbounded.
      child: Text.rich(
        TextSpan(children: [
          if (icon != null) ...[
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(icon, size: 13, color: tone.fg)),
            const TextSpan(text: ' '),
          ],
          TextSpan(text: text),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: kBody, fontSize: 12, fontWeight: FontWeight.w600, color: tone.fg),
      ),
    );
  }
}

Tone statusTone(String status) => switch (status) {
      'completed' || 'delivered' => Tone.good,
      'partial' => Tone.warn,
      'pending' => Tone.accent,
      'confirmed' => Tone.info,
      'booked' => Tone.brand,
      'returned' || 'cancelled' => Tone.bad,
      _ => Tone.neutral,
    };

class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill(this.status, {super.key});
  @override
  Widget build(BuildContext context) => Pill(tKey('st', status), tone: statusTone(status));
}

class MoneyText extends StatelessWidget {
  final num amount;
  final TextStyle? style;
  final Tone? tone;
  final bool signed;
  const MoneyText(this.amount, {super.key, this.style, this.tone, this.signed = false});

  @override
  Widget build(BuildContext context) {
    final base = style ?? Txt.num;
    return Text(money(amount, signed: signed), style: tone == null ? base : base.copyWith(color: tone!.fg));
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: C.paper2, borderRadius: BorderRadius.circular(18)),
            child: Icon(icon, size: 30, color: C.ink3),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(text, textAlign: TextAlign.center, style: Txt.body.copyWith(color: C.ink2)),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6)));
}

/// Renders a Riverpod AsyncValue with consistent loading and error states.
class AsyncView<V> extends StatelessWidget {
  final AsyncValue<V> value;
  final Widget Function(V data) builder;
  final Widget? loading;
  const AsyncView(this.value, {super.key, required this.builder, this.loading});

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: builder,
      loading: () => loading ?? const Loading(),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(errorText(e), style: Txt.small.copyWith(color: C.outRed)),
        ),
      ),
    );
  }
}

class KeyCap extends StatelessWidget {
  final String label;
  final bool dark;
  const KeyCap(this.label, {super.key, this.dark = false});
  @override
  Widget build(BuildContext context) {
    // Keyboard hints mean nothing on touch screens.
    if (context.isPhone || isMobilePlatform) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.10) : C.paper,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.18) : C.line),
      ),
      child: Text(label,
          style: TextStyle(
              fontFamily: kBody,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: dark ? Colors.white.withValues(alpha: 0.7) : C.ink3)),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final double size;
  final Tone tone;
  const Avatar(this.name, {super.key, this.size = 36, this.tone = Tone.brand});
  @override
  Widget build(BuildContext context) {
    final t = name.trim();
    final initial = t.isEmpty ? '?' : String.fromCharCodes(t.runes.take(1));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Text(initial.toUpperCase(),
          style: TextStyle(fontFamily: kBody, fontWeight: FontWeight.w700, fontSize: size * 0.42, color: tone.fg)),
    );
  }
}

// ---------------------------------------------------------------- inputs

class SearchBox extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;
  final double width;
  const SearchBox({
    super.key,
    this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
    this.width = 280,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
        ),
      ),
    );
  }
}

/// Accepts Latin or Bangla digits and a decimal point.
class NumberInputFormatter extends TextInputFormatter {
  final bool decimal;
  NumberInputFormatter({this.decimal = true});
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = toLatinDigits(newValue.text);
    final ok = decimal ? RegExp(r'^\d*\.?\d{0,3}$') : RegExp(r'^\d*$');
    if (text.isEmpty || ok.hasMatch(text)) {
      return newValue.copyWith(text: text, selection: TextSelection.collapsed(offset: text.length));
    }
    return oldValue;
  }
}

class NumField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? prefix;
  final String? suffix;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final bool decimal;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final String? helper;
  const NumField({
    super.key,
    required this.controller,
    required this.label,
    this.prefix,
    this.suffix,
    this.onChanged,
    this.autofocus = false,
    this.decimal = true,
    this.focusNode,
    this.onSubmitted,
    this.helper,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [NumberInputFormatter(decimal: decimal)],
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: Txt.num.copyWith(fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        suffixText: suffix,
        helperText: helper,
      ),
      onTap: () => controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length),
    );
  }
}

class TextIn extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboard;
  final IconData? icon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool obscure;
  final Widget? suffix;
  const TextIn({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboard,
    this.icon,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.obscure = false,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      maxLines: maxLines,
      minLines: 1,
      keyboardType: keyboard,
      obscureText: obscure,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 19),
        suffixIcon: suffix,
      ),
    );
  }
}

/// Money account picker shown as chips (Cash / bKash / Nagad / Bank…).
class AccountChips extends ConsumerWidget {
  final int? value;
  final ValueChanged<int> onChanged;
  final bool includeCourier;

  /// Extra chips after the accounts, in the same row (e.g. "Due" at the till).
  final List<Widget> trailing;
  const AccountChips(
      {super.key, required this.value, required this.onChanged, this.includeCourier = false, this.trailing = const []});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    return AsyncView(accounts, loading: const SizedBox(height: 36), builder: (list) {
      final shown = list.where((a) => includeCourier || a.kind != 'courier').toList();
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in shown)
          ChoiceChip(
            label: Text(a.name),
            avatar: Icon(accountIcon(a.kind), size: 16, color: value == a.id ? C.brand : C.ink3),
            selected: value == a.id,
            onSelected: (_) => onChanged(a.id),
          ),
        ...trailing,
      ]);
    });
  }
}

final accountsProvider = StreamProvider<List<Account>>((ref) => ref.watch(bizProvider).cash.watchAccounts());

IconData accountIcon(String kind) => switch (kind) {
      'cash' => Icons.payments_outlined,
      'mobile' => Icons.phone_android_rounded,
      'bank' => Icons.account_balance_outlined,
      'card' => Icons.credit_card_rounded,
      'courier' => Icons.local_shipping_outlined,
      _ => Icons.wallet_outlined,
    };

// ---------------------------------------------------------------- date range

enum RangePreset { today, yesterday, last7, last30, thisMonth, lastMonth, thisYear, all, custom }

extension RangePresetX on RangePreset {
  String get label => switch (this) {
        RangePreset.today => T.today.s,
        RangePreset.yesterday => T.yesterday.s,
        RangePreset.last7 => T.last7.s,
        RangePreset.last30 => T.last30.s,
        RangePreset.thisMonth => T.thisMonth.s,
        RangePreset.lastMonth => T.lastMonth.s,
        RangePreset.thisYear => T.thisYear.s,
        RangePreset.all => T.allTime.s,
        RangePreset.custom => T.customRange.s,
      };

  DateRange? get range => switch (this) {
        RangePreset.today => DateRange.today(),
        RangePreset.yesterday => DateRange.yesterday(),
        RangePreset.last7 => DateRange.lastDays(7),
        RangePreset.last30 => DateRange.lastDays(30),
        RangePreset.thisMonth => DateRange.thisMonth(),
        RangePreset.lastMonth => DateRange.lastMonth(),
        RangePreset.thisYear => DateRange.thisYear(),
        RangePreset.all => DateRange.all(),
        RangePreset.custom => null,
      };
}

class RangeSelection {
  final RangePreset preset;
  final DateRange range;
  const RangeSelection(this.preset, this.range);
  factory RangeSelection.of(RangePreset p) => RangeSelection(p, p.range ?? DateRange.today());
  String get label => preset == RangePreset.custom ? '${dateShort(range.from)} – ${dateShort(range.to)}' : preset.label;
}

class RangeButton extends StatelessWidget {
  final RangeSelection value;
  final ValueChanged<RangeSelection> onChanged;
  const RangeButton({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<RangePreset>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: (p) async {
        if (p == RangePreset.custom) {
          final picked = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2015),
            lastDate: DateTime.now().add(const Duration(days: 1)),
            initialDateRange: DateTimeRange(start: value.range.from, end: value.range.to),
          );
          if (picked != null) onChanged(RangeSelection(p, DateRange(dayStart(picked.start), dayEnd(picked.end))));
        } else {
          onChanged(RangeSelection.of(p));
        }
      },
      itemBuilder: (_) => [
        for (final p in RangePreset.values)
          PopupMenuItem(
            value: p,
            child: Row(children: [
              Icon(p == value.preset ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: p == value.preset ? C.brand : C.ink3),
              const SizedBox(width: 10),
              Text(p.label),
            ]),
          ),
      ],
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.calendar_today_rounded, size: 16, color: C.ink2),
          const SizedBox(width: 8),
          Text(value.label, style: Txt.strong),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: C.ink3),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- tables

class Col {
  final String label;
  final int flex;
  final TextAlign align;
  const Col(this.label, {this.flex = 2, this.align = TextAlign.left});
}

class TableHead extends StatelessWidget {
  final List<Col> cols;
  final EdgeInsets padding;
  const TableHead(this.cols, {super.key, this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10)});

  @override
  Widget build(BuildContext context) {
    // Phone rows are self-describing cards, so the column header is dropped.
    if (context.isPhone) return const SizedBox.shrink();
    return Container(
      padding: padding,
      decoration: const BoxDecoration(
        color: C.paper,
        border: Border(bottom: BorderSide(color: C.line)),
      ),
      child: Row(children: [
        for (final c in cols)
          Expanded(
            flex: c.flex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(c.label.toUpperCase(), textAlign: c.align, style: Txt.caps, overflow: TextOverflow.ellipsis),
            ),
          ),
      ]),
    );
  }
}

class TableRowX extends StatefulWidget {
  final List<Col> cols;
  final List<Widget> cells;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsets padding;
  const TableRowX({
    super.key,
    required this.cols,
    required this.cells,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
  });

  @override
  State<TableRowX> createState() => _TableRowXState();
}

class _TableRowXState extends State<TableRowX> {
  bool hover = false;

  /// Phone layout: the first wide column as the title, the last column on the
  /// right, everything in between as a wrapped line underneath.
  Widget _compact(BuildContext context) {
    final cols = widget.cols;
    var titleIdx = cols.indexWhere((c) => c.flex > 1);
    if (titleIdx < 0) titleIdx = 0;
    final lastIdx = cols.length - 1;
    final middle = [
      for (var i = 0; i < cols.length; i++)
        if (i != titleIdx && i != lastIdx) widget.cells[i],
    ];
    return InkWell(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: widget.selected ? C.brandSoft : null,
          border: const Border(bottom: BorderSide(color: C.line2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: widget.cells[titleIdx]),
            if (lastIdx != titleIdx) ...[const SizedBox(width: 10), widget.cells[lastIdx]],
          ]),
          if (middle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: middle),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (context.isPhone) return _compact(context);
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: widget.selected ? C.brandSoft : (hover && widget.onTap != null ? C.paper : Colors.transparent),
            border: const Border(bottom: BorderSide(color: C.line2)),
          ),
          child: Row(children: [
            for (var i = 0; i < widget.cols.length; i++)
              Expanded(
                flex: widget.cols[i].flex,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: switch (widget.cols[i].align) {
                    TextAlign.right || TextAlign.end => Alignment.centerRight,
                    TextAlign.center => Alignment.center,
                    _ => Alignment.centerLeft,
                  },
                  child: widget.cells[i],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Two-line cell: bold title + muted subtitle.
class Cell2 extends StatelessWidget {
  final String title;
  final String? subtitle;
  final TextStyle? style;
  // ignore: use_key_in_widget_constructors
  const Cell2(this.title, [this.subtitle, this.style]);
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: style ?? Txt.strong, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (subtitle != null && subtitle!.isNotEmpty)
        Text(subtitle!, style: Txt.tiny, maxLines: 1, overflow: TextOverflow.ellipsis),
    ]);
  }
}

// ---------------------------------------------------------------- dialogs

/// A consistent desktop dialog with title, body and action row.
class AppDialog extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget> actions;
  final double width;
  final IconData? icon;
  final Tone tone;
  const AppDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.width = 460,
    this.icon,
    this.tone = Tone.brand,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.all(context.isPhone ? 10 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.sizeOf(context).height - 48),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 14, 8),
            child: Row(children: [
              if (icon != null) ...[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 19, color: tone.fg),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(title, style: Txt.display(19))),
              IconButton(
                tooltip: T.close.s,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
              child: child,
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: 10), actions[i]],
              ]),
            ),
        ]),
      ),
    );
  }
}

class Gap extends StatelessWidget {
  final double size;
  const Gap(this.size, {super.key});
  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size);
}

/// Busy-aware primary button.
class BusyButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final Future<void> Function()? onPressed;
  final Color? color;
  final bool large;
  const BusyButton({super.key, required this.label, this.icon, this.onPressed, this.color, this.large = false});

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: widget.color,
      minimumSize: Size(0, widget.large ? 52 : 42),
      textStyle: TextStyle(fontFamily: kBody, fontSize: widget.large ? 16 : 14, fontWeight: FontWeight.w700),
    );
    return FilledButton(
      style: style,
      onPressed: busy || widget.onPressed == null
          ? null
          : () async {
              setState(() => busy = true);
              try {
                await widget.onPressed!();
              } finally {
                if (mounted) setState(() => busy = false);
              }
            },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        else if (widget.icon != null)
          Icon(widget.icon, size: 19),
        if (busy || widget.icon != null) const SizedBox(width: 8),
        Text(widget.label),
      ]),
    );
  }
}
