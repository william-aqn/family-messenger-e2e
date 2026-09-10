// Invitation scanner (artboard A17).
//
// A full-screen camera preview with a 248 frame, a torch toggle in the app bar
// and the permission-refused footer. It reads the QR an invitation carries
// (`https://<server>/#/join?code=<code>`) and hands the parsed value back to
// the caller; a code it cannot parse is ignored and scanning continues.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/invite_link.dart';
import '../i18n/strings.dart';
import '../theme.dart';

/// Whether this build can scan at all.
///
/// `mobile_scanner` ships Android, iOS, macOS and web implementations only, so
/// the Windows and Linux builds must not offer the scanner: there the entry
/// points stay hidden and the invite code is typed by hand.
bool get scannerSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Opens the scanner. Resolves to the invitation that was read, or to null
/// when the screen was closed without one.
Future<InviteLink?> scanInvite(BuildContext context) {
  return Navigator.of(context).push<InviteLink>(
    MaterialPageRoute<InviteLink>(builder: (BuildContext context) => const ScanScreen()),
  );
}

/// The scanner screen itself (A17). Pops with an [InviteLink] on success.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// Only QR codes, and never the same code twice in a row: the camera reads
  /// the same symbol many times a second.
  final MobileScannerController controller = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// Set once the screen is on its way out, so a second reading of the same
  /// code cannot pop the route twice.
  bool done = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// A reading: the first barcode that parses as an invitation wins, anything
  /// else is ignored and the camera keeps looking.
  void onDetect(BarcodeCapture capture) {
    if (done) return;
    for (final Barcode barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final InviteLink? link = parseInviteLink(raw);
      if (link == null) continue;
      done = true;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(link);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FmColors fm = FmColors.of(context);

    return Scaffold(
      backgroundColor: fm.chrome,
      appBar: AppBar(
        backgroundColor: fm.chrome,
        title: Text(t('scan_invite')),
        actions: <Widget>[_torchButton(theme)],
      ),
      body: ValueListenableBuilder<MobileScannerState>(
        valueListenable: controller,
        builder: (BuildContext context, MobileScannerState state, Widget? child) {
          final MobileScannerErrorCode? code = state.error?.errorCode;
          return Column(
            children: <Widget>[
              Expanded(child: child!),
              if (code != null) _errorFooter(theme, code),
            ],
          );
        },
        // The preview is built once: rebuilding it on every camera state change
        // would restart the platform view.
        child: MobileScanner(
          controller: controller,
          onDetect: onDetect,
          placeholderBuilder: (BuildContext context) => _cameraPlaceholder(theme),
          errorBuilder: (BuildContext context, MobileScannerException error) => _cameraPlaceholder(theme),
          overlayBuilder: (BuildContext context, BoxConstraints constraints) => _overlay(theme),
        ),
      ),
    );
  }

  /// The torch toggle: lit while the flashlight is on, dimmed while the camera
  /// has no flashlight to offer.
  Widget _torchButton(ThemeData theme) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (BuildContext context, MobileScannerState state, Widget? child) {
        final bool available = state.torchState != TorchState.unavailable;
        final bool on = state.torchState == TorchState.on;
        return IconButton(
          onPressed: available ? () => controller.toggleTorch() : null,
          color: on ? theme.colorScheme.primary : theme.colorScheme.onSurface,
          disabledColor: theme.colorScheme.outline,
          icon: const Icon(LucideIcons.zap),
        );
      },
    );
  }

  /// What stands in for the camera image while it comes up, and after it has
  /// failed: the artboard's dark plate with a faint mark.
  Widget _cameraPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(LucideIcons.qrCode, size: 72, color: theme.colorScheme.surfaceContainerHigh),
    );
  }

  /// Over the preview: the 248 frame with its four corners and the scan line,
  /// and the hint pinned to the bottom.
  Widget _overlay(ThemeData theme) {
    return Stack(
      children: <Widget>[
        Center(
          child: CustomPaint(
            size: const Size(248, 248),
            painter: _FramePainter(theme.colorScheme.primary),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          // The preview runs to the bottom edge of the screen, so the hint has
          // to clear the system navigation itself.
          bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
          child: Text(
            t('scan_hint'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ),
      ],
    );
  }

  /// Permission refused (or the camera is otherwise unusable): the alarm
  /// banner and the way out to typing the code by hand.
  Widget _errorFooter(ThemeData theme, MobileScannerErrorCode code) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 28 + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (code == MobileScannerErrorCode.permissionDenied) ...<Widget>[
            _alertBanner(theme, t('camera_permission_denied')),
            const SizedBox(height: 16),
          ],
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.primary),
              child: Text(t('enter_code_manually')),
            ),
          ),
        ],
      ),
    );
  }

  /// Alarm banner: the danger wash with a 2px rail on the left.
  Widget _alertBanner(ThemeData theme, String message) {
    final ColorScheme scheme = theme.colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(width: 2, color: scheme.error),
            Expanded(
              child: Container(
                color: scheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(LucideIcons.alertTriangle, size: 20, color: scheme.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The aiming frame: four 40x40 corners of a 3px accent rule, rounded by 4 on
/// the outside, and a 2px scan line at half opacity across the middle.
///
/// A painter rather than four bordered boxes because a [Border] may only carry
/// a radius when all four of its sides are drawn.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.color);

  final Color color;

  static const double _stroke = 3;
  static const double _arm = 40;
  static const double _radius = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;

    // The rule is drawn inside the frame, as a CSS border is: its centre line
    // sits half a stroke in, and the outer radius shrinks by as much.
    const double inset = _stroke / 2;
    const double radius = _radius - inset;
    final Path corner = Path()
      ..moveTo(inset, _arm)
      ..lineTo(inset, inset + radius)
      ..arcToPoint(const Offset(inset + radius, inset), radius: const Radius.circular(radius))
      ..lineTo(_arm, inset);

    // Top-left, then its three mirror images.
    for (final (double sx, double sy) in const <(double, double)>[(1, 1), (-1, 1), (1, -1), (-1, -1)]) {
      canvas.save();
      canvas.translate(sx < 0 ? size.width : 0, sy < 0 ? size.height : 0);
      canvas.scale(sx, sy);
      canvas.drawPath(corner, paint);
      canvas.restore();
    }

    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()
        ..color = color.withValues(alpha: .5)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.color != color;
}
