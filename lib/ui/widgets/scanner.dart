import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import 'responsive.dart';

/// Opens the phone camera and returns the first barcode/QR value it reads.
/// Desktops use a USB scanner (it types into the search box) instead.
Future<String?> scanBarcode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScannerPage()));

/// Camera button shown only on phones/tablets.
class ScanButton extends StatelessWidget {
  final ValueChanged<String> onCode;
  const ScanButton({super.key, required this.onCode});

  @override
  Widget build(BuildContext context) {
    if (!isMobilePlatform) return const SizedBox.shrink();
    return IconButton(
      tooltip: T.scanBarcode.s,
      icon: const Icon(Icons.photo_camera_outlined, color: C.brand),
      onPressed: () async {
        final code = await scanBarcode(context);
        if (code != null && code.trim().isNotEmpty) onCode(code.trim());
      },
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();
  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool done = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(T.scanBarcode.s),
        actions: [
          IconButton(
            tooltip: 'Torch',
            onPressed: () => controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_outlined),
          ),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(T.cameraError.s, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
          ),
        ),
        // Aiming frame.
        Center(
          child: Container(
            width: 260,
            height: 160,
            decoration: BoxDecoration(
              border: Border.all(color: C.marigold, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 40,
          child: Text(T.scanHint.s, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ]),
    );
  }
}
