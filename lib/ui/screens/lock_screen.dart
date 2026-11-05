import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';

final _lockStaffProvider = FutureProvider.autoDispose<List<StaffUser>>((ref) => ref.watch(sessionProvider).biz.staff.active());

/// Remembered across locks (per business) so the counter staff does not pick themselves every time.
final _lastStaffId = <String, int>{};

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});
  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final pin = TextEditingController();
  final focus = FocusNode();
  String? error;
  late int? staffId = _lastStaffId[_bizId];

  String get _bizId {
    final phase = ref.read(appProvider);
    return phase is Locked ? phase.session.info.id : '';
  }
  int fails = 0;
  DateTime? blockedUntil;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    pin.dispose();
    focus.dispose();
    super.dispose();
  }

  int get _waitSeconds {
    final until = blockedUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds + 1;
    return left > 0 ? left : 0;
  }

  Future<void> _unlock() async {
    // Wait for the staff list, so a remembered choice has been checked against it.
    if (_waitSeconds > 0 || !ref.read(_lockStaffProvider).hasValue) return;
    final ok = await ref.read(appProvider.notifier).unlock(pin.text, staffId: staffId);
    if (ok) {
      final id = staffId;
      if (id == null) {
        _lastStaffId.remove(_bizId);
      } else {
        _lastStaffId[_bizId] = id;
      }
      return;
    }
    if (!mounted) return;
    fails++;
    pin.clear();
    if (fails >= 5) {
      // Slow down guessing: 30 seconds after every fifth wrong PIN.
      blockedUntil = DateTime.now().add(const Duration(seconds: 30));
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        if (_waitSeconds == 0) {
          t.cancel();
          fails = 0;
          blockedUntil = null;
          focus.requestFocus();
        }
        setState(() {});
      });
    }
    setState(() => error = T.wrongPin.s);
    focus.requestFocus();
  }

  void _pick(int? id) {
    setState(() {
      staffId = id;
      error = null;
      pin.clear();
    });
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(appProvider);
    final name = phase is Locked ? phase.session.info.name : '';
    final staffAsync = ref.watch(_lockStaffProvider);
    final staff = staffAsync.value ?? const <StaffUser>[];
    // A remembered staff member may have been removed or disabled since (check once the list is in).
    if (staffAsync.hasValue && staffId != null && !staff.any((u) => u.id == staffId)) staffId = null;
    final wait = _waitSeconds;
    return Scaffold(
      backgroundColor: C.brandDeep,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Container(
            width: staff.isEmpty ? 380 : 440,
            padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
            decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(22)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const BrandMark(size: 54),
              const SizedBox(height: 16),
              Text(name, style: Txt.display(22), textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(staff.isEmpty ? T.locked.s : T.whoIsUsing.s, style: Txt.small),
              if (staff.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  _UserChip(label: T.role_owner.s, sub: null, selected: staffId == null, onTap: () => _pick(null)),
                  for (final u in staff)
                    _UserChip(
                      label: u.name,
                      sub: tKey('role', u.role),
                      selected: staffId == u.id,
                      onTap: () => _pick(u.id),
                    ),
                ]),
              ],
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('lock-pin'),
                controller: pin,
                focusNode: focus,
                autofocus: true,
                enabled: wait == 0,
                obscureText: true,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                style: const TextStyle(fontSize: 26, letterSpacing: 12, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: T.enterPin.s,
                  hintStyle: const TextStyle(fontSize: 15, letterSpacing: 0),
                  errorText: wait > 0 ? T.tooManyTries.f({'n': wait}) : error,
                  errorMaxLines: 2,
                ),
                onChanged: (_) => setState(() => error = null),
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: wait > 0 ? null : _unlock,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.lock_open_rounded, size: 19),
                  label: Text(T.unlock.s),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _UserChip extends StatelessWidget {
  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;
  const _UserChip({required this.label, required this.sub, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.brandSoft : C.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? C.brand : C.line, width: selected ? 1.6 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: selected ? C.brand : C.line,
              child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : C.ink2)),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: Txt.strong.copyWith(fontSize: 14)),
              if (sub != null) Text(sub!, style: Txt.small.copyWith(fontSize: 11.5)),
            ]),
          ]),
        ),
      ),
    );
  }
}
