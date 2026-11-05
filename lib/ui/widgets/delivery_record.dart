import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../couriers/courier.dart';
import '../../state/app_state.dart';
import 'common.dart';

/// Our own history with this phone + (on demand) Steadfast's network record.
class DeliveryRecord extends ConsumerStatefulWidget {
  final String phone;
  const DeliveryRecord({super.key, required this.phone});
  @override
  ConsumerState<DeliveryRecord> createState() => _DeliveryRecordState();
}

class _DeliveryRecordState extends ConsumerState<DeliveryRecord> {
  ({int delivered, int returned, int cancelled, int pending})? ours;
  FraudScore? score;
  bool checking = false;
  String? error;
  String? loadedFor;

  @override
  void didUpdateWidget(covariant DeliveryRecord old) {
    super.didUpdateWidget(old);
    if (old.phone != widget.phone) _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = normalizePhone(widget.phone);
    if (!isValidBdMobile(p)) {
      setState(() {
        ours = null;
        score = null;
        loadedFor = null;
      });
      return;
    }
    if (loadedFor == p) return;
    loadedFor = p;
    final biz = ref.read(bizProvider);
    final h = await biz.contacts.orderHistory(p);
    final cached = await biz.orders.cachedFraudScore(p);
    if (!mounted) return;
    setState(() {
      ours = h;
      score = cached;
      error = null;
    });
  }

  Future<void> _check() async {
    setState(() {
      checking = true;
      error = null;
    });
    try {
      final s = await ref.read(bizProvider).orders.fraudScore(widget.phone, force: score != null);
      if (!mounted) return;
      setState(() {
        score = s;
        if (s == null) error = T.configureCourier.s;
      });
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = ours;
    if (h == null) return const SizedBox.shrink();
    final s = score;
    final (riskText, tone) = switch (s?.risk) {
      0 => (T.riskGood.s, Tone.good),
      1 => (T.riskCaution.s, Tone.warn),
      2 => (T.riskBad.s, Tone.bad),
      -1 => (T.riskUnknown.s, Tone.neutral),
      _ => ('', Tone.neutral),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.verified_user_outlined, size: 17, color: C.ink2),
          const Gap(8),
          Expanded(child: Text(T.deliveryRecord.s, style: Txt.strong, overflow: TextOverflow.ellipsis)),
          Flexible(
            child: TextButton.icon(
              onPressed: checking ? null : _check,
              icon: checking
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore_rounded, size: 16),
              label: Text(T.checkSteadfast.s, overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
        Text(
          T.ourHistory.f({'d': number(h.delivered), 'r': number(h.returned), 'c': number(h.cancelled)}),
          style: Txt.small.copyWith(color: h.returned > 0 ? C.outRed : C.ink2),
        ),
        if (s != null) ...[
          const Gap(8),
          Row(children: [
            Pill(riskText, tone: tone),
            const Gap(8),
            Expanded(
              child: Text(
                s.unknown
                    ? '${T.fraudLine.f({'d': '—', 'c': '—', 'r': number(s.totalReports)})} · ${s.volumeBand}'
                    : '${T.fraudLine.f({'d': number(s.deliveryRatio ?? 0), 'c': number(s.cancellationRatio ?? 0), 'r': number(s.totalReports)})} · ${s.volumeBand}',
                style: Txt.tiny,
              ),
            ),
          ]),
          Text('Steadfast · ${friendlyDate(s.checkedAt)}', style: Txt.tiny),
        ],
        if (error != null) ...[
          const Gap(6),
          Text(error!, style: Txt.tiny.copyWith(color: C.outRed)),
        ],
      ]),
    );
  }
}
