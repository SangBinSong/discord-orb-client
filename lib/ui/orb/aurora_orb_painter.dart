import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pure-Flutter [CustomPainter] rendering the Aurora Nebula Glass 3D sphere.
///
/// All orbital phases use integer multiples of `2 * pi` so repeating [phase]
/// in `[0.0, 1.0)` loops seamlessly with zero jump. Outer aura and drop shadow
/// stay strictly within `radius + 9.5px` so the 56x56 orb never clips inside
/// the 80x80 collapsed desktop overlay window.
class AuroraOrbPainter extends CustomPainter {
  const AuroraOrbPainter({
    required this.phase,
    required this.isPanelOpen,
    required this.hasUnread,
    required this.openProgress,
    required this.unreadProgress,
  });

  /// Normalized animation phase in `[0.0, 1.0)`.
  final double phase;

  /// Whether the message preview panel is currently expanded.
  final bool isPanelOpen;

  /// Whether unread messages are waiting while collapsed.
  final bool hasUnread;

  /// Smoothly interpolated open state (`0.0` collapsed -> `1.0` open).
  final double openProgress;

  /// Smoothly interpolated unread accent (`0.0` none -> `1.0` unread).
  final double unreadProgress;

  static const Color _coreInner = Color(0xFF312E81);
  static const Color _coreMid = Color(0xFF191942);
  static const Color _coreEdge = Color(0xFF090B1D);

  static const Color _blurple = Color(0xFF5865F2);
  static const Color _orchidLight = Color(0xFFC084FC);
  static const Color _orchidDeep = Color(0xFFA855F7);
  static const Color _electricCyan = Color(0xFF38BDF8);
  static const Color _softRose = Color(0xFFF472B6);
  static const Color _vignetteDark = Color(0xFF070818);
  static const Color _causticBlue = Color(0xFF93C5FD);
  static const Color _fresnelMid = Color(0xFFC7D2FE);
  static const Color _fresnelViolet = Color(0xFFA78BFA);

  @override
  void paint(Canvas canvas, Size size) {
    final double diameter = math.min(size.width, size.height);
    if (diameter <= 0) {
      return;
    }

    final Offset center = Offset(size.width / 2, size.height / 2);
    final double r = diameter / 2;
    final double tau = phase * 2.0 * math.pi;

    // Calm down internal aurora intensity (~0.45) when the panel is open.
    final double auroraIntensity =
        ui.lerpDouble(1.0, 0.45, openProgress.clamp(0.0, 1.0))!;
    final double unreadFactor = unreadProgress.clamp(0.0, 1.0);
    final double breath = 0.5 + 0.5 * math.sin(tau);
    final double unreadPulse = 0.5 + 0.5 * math.sin(2.0 * tau);

    // 1. Soft bottom drop shadow (strictly inside radius + 9.5px margin).
    final Offset shadowCenter = Offset(center.dx, center.dy + math.min(3.0, r * 0.11));
    final double shadowRadius = r + math.min(6.5, r * 0.23);
    final Paint shadowPaint = Paint()
      ..shader = ui.Gradient.radial(
        shadowCenter,
        shadowRadius,
        <Color>[
          Colors.black.withValues(alpha: 0.42),
          Colors.black.withValues(alpha: 0.22),
          Colors.black.withValues(alpha: 0.0),
        ],
        const <double>[0.52, 0.78, 1.0],
      );
    canvas.drawCircle(shadowCenter, shadowRadius, shadowPaint);

    // 2. Floating outer luminous aura (strictly <= r + 9.5px so 80x80 never clips).
    final double auraExtend = math.min(9.5, r * 0.34);
    final double auraRadius = r + auraExtend;
    final Color auraPrimary = Color.lerp(
      Color.lerp(_blurple, _orchidDeep, 0.35 + 0.25 * breath)!,
      _electricCyan,
      unreadFactor * 0.85,
    )!;
    final double baseAuraAlpha = ui.lerpDouble(
      0.24 + 0.08 * breath,
      0.13,
      openProgress.clamp(0.0, 1.0),
    )!;
    final double auraAlpha = ui.lerpDouble(
      baseAuraAlpha,
      0.34 + 0.14 * unreadPulse,
      unreadFactor,
    )!;
    final Paint auraPaint = Paint()
      ..shader = ui.Gradient.radial(
        center,
        auraRadius,
        <Color>[
          auraPrimary.withValues(alpha: auraAlpha),
          auraPrimary.withValues(alpha: auraAlpha * 0.42),
          auraPrimary.withValues(alpha: 0.0),
        ],
        const <double>[0.62, 0.82, 1.0],
      );
    canvas.drawCircle(center, auraRadius, auraPaint);

    // 3. Clipped circular 3D glass sphere interior.
    final Rect sphereRect = Rect.fromCircle(center: center, radius: r);
    final Path spherePath = Path()..addOval(sphereRect);

    canvas.save();
    canvas.clipPath(spherePath);

    // Isolate screen-blended nebula clouds against the deep indigo core inside
    // a dedicated layer so BlendMode.screen never bleeds into transparent window alpha.
    canvas.saveLayer(sphereRect, Paint());

    // 3a. Deep indigo 3D core gradient.
    final Offset coreFocal = center + Offset(-r * 0.26, -r * 0.28);
    final Paint corePaint = Paint()
      ..shader = ui.Gradient.radial(
        coreFocal,
        r * 1.32,
        const <Color>[_coreInner, _coreMid, _coreEdge],
        const <double>[0.0, 0.56, 1.0],
      );
    canvas.drawRect(sphereRect, corePaint);

    // 3b. Four organic drifting aurora nebula blobs with BlendMode.screen.
    _drawAuroraBlob(
      canvas: canvas,
      center: center +
          Offset(
            math.cos(tau) * r * 0.34,
            math.sin(tau) * r * 0.26 - r * 0.08,
          ),
      radius: r * (0.78 + 0.07 * math.sin(2.0 * tau)),
      innerColor: _blurple.withValues(alpha: 0.84 * auroraIntensity),
      midColor: _blurple.withValues(alpha: 0.36 * auroraIntensity),
    );

    _drawAuroraBlob(
      canvas: canvas,
      center: center +
          Offset(
            math.cos(-tau + 1.85) * r * 0.38,
            math.sin(2.0 * tau + 0.65) * r * 0.28,
          ),
      radius: r * (0.72 + 0.07 * math.cos(tau + 0.5)),
      innerColor: _orchidLight.withValues(alpha: 0.74 * auroraIntensity),
      midColor: _orchidDeep.withValues(alpha: 0.34 * auroraIntensity),
    );

    _drawAuroraBlob(
      canvas: canvas,
      center: center +
          Offset(
            math.sin(tau + 0.95) * r * 0.42,
            math.cos(-tau + 1.35) * r * 0.34,
          ),
      radius: r * (0.64 + 0.08 * math.sin(2.0 * tau + 1.4) + 0.08 * unreadFactor),
      innerColor: _electricCyan.withValues(
        alpha: (0.68 + 0.22 * unreadFactor) * auroraIntensity,
      ),
      midColor: _electricCyan.withValues(
        alpha: (0.28 + 0.14 * unreadFactor) * auroraIntensity,
      ),
    );

    _drawAuroraBlob(
      canvas: canvas,
      center: center +
          Offset(
            math.cos(2.0 * tau + 3.6) * r * 0.32,
            math.sin(-tau + 2.4) * r * 0.36,
          ),
      radius: r * (0.58 + 0.06 * math.cos(2.0 * tau)),
      innerColor: _softRose.withValues(alpha: 0.58 * auroraIntensity),
      midColor: _softRose.withValues(alpha: 0.22 * auroraIntensity),
    );

    // 3c. Center dreamy ethereal core glow.
    final Offset dreamyCenter = center +
        Offset(
          math.sin(tau + 0.4) * r * 0.09,
          math.cos(tau + 0.4) * r * 0.09,
        );
    final Color dreamyColor = Color.lerp(
      const Color(0xFFE0E7FF),
      const Color(0xFFBAE6FD),
      unreadFactor * 0.65,
    )!;
    _drawAuroraBlob(
      canvas: canvas,
      center: dreamyCenter,
      radius: r * 0.54,
      innerColor: dreamyColor.withValues(alpha: 0.28 * auroraIntensity),
      midColor: _orchidLight.withValues(alpha: 0.10 * auroraIntensity),
    );

    canvas.restore(); // Composite aurora layer back into clipped sphere.

    // 3d. 3D spherical rim darkening vignette for glass orb depth.
    final Offset vignetteFocal = center + Offset(-r * 0.08, -r * 0.10);
    final Paint vignettePaint = Paint()
      ..shader = ui.Gradient.radial(
        vignetteFocal,
        r * 1.06,
        <Color>[
          Colors.transparent,
          Colors.transparent,
          _vignetteDark.withValues(alpha: 0.42),
          _vignetteDark.withValues(alpha: 0.80),
        ],
        const <double>[0.0, 0.56, 0.85, 1.0],
      );
    canvas.drawRect(sphereRect, vignettePaint);

    // 3e. Bottom internal caustic light bounce.
    final Offset causticCenter = center + Offset(r * 0.08, r * 0.66);
    final Color causticColor = Color.lerp(_causticBlue, _electricCyan, unreadFactor * 0.6)!;
    canvas.save();
    canvas.translate(causticCenter.dx, causticCenter.dy);
    canvas.rotate(-0.18);
    final Rect causticRect = Rect.fromCenter(
      center: Offset.zero,
      width: r * 1.18,
      height: r * 0.54,
    );
    final Paint causticPaint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.radial(
        Offset.zero,
        r * 0.60,
        <Color>[
          causticColor.withValues(
            alpha: (0.40 + 0.18 * unreadFactor) * auroraIntensity,
          ),
          causticColor.withValues(
            alpha: (0.14 + 0.08 * unreadFactor) * auroraIntensity,
          ),
          causticColor.withValues(alpha: 0.0),
        ],
        const <double>[0.0, 0.52, 1.0],
      );
    canvas.drawOval(causticRect, causticPaint);
    canvas.restore();

    // 3f. Rotated top-left glass specular crescent highlight.
    canvas.save();
    canvas.translate(center.dx - r * 0.28, center.dy - r * 0.34);
    canvas.rotate(-0.56);
    final Rect specularRect = Rect.fromCenter(
      center: Offset.zero,
      width: r * 0.86,
      height: r * 0.42,
    );
    final Paint specularPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, -r * 0.22),
        Offset(0, r * 0.22),
        <Color>[
          Colors.white.withValues(alpha: 0.64),
          Colors.white.withValues(alpha: 0.20),
          Colors.white.withValues(alpha: 0.0),
        ],
        const <double>[0.0, 0.52, 1.0],
      );
    canvas.drawOval(specularRect, specularPaint);
    canvas.restore();

    // 3g. Small crisp secondary glints.
    final Offset glint1 = center + Offset(-r * 0.46, -r * 0.14);
    final Paint glint1Paint = Paint()
      ..shader = ui.Gradient.radial(
        glint1,
        r * 0.16,
        <Color>[
          Colors.white.withValues(alpha: 0.52),
          Colors.white.withValues(alpha: 0.0),
        ],
        const <double>[0.0, 1.0],
      );
    canvas.drawCircle(glint1, r * 0.16, glint1Paint);

    final Offset glint2 = center + Offset(r * 0.40, r * 0.36);
    final Paint glint2Paint = Paint()
      ..shader = ui.Gradient.radial(
        glint2,
        r * 0.13,
        <Color>[
          const Color(0xFFE0F2FE).withValues(alpha: 0.26),
          Colors.white.withValues(alpha: 0.0),
        ],
        const <double>[0.0, 1.0],
      );
    canvas.drawCircle(glint2, r * 0.13, glint2Paint);

    canvas.restore(); // Restore sphere clip.

    // 4. Diagonal Fresnel rim stroke (white -> #C7D2FE -> #A78BFA / #38BDF8).
    final Color fresnelAccent = Color.lerp(
      _fresnelViolet,
      _electricCyan,
      unreadFactor,
    )!;
    final double strokeWidth = ui.lerpDouble(1.5, 1.9, unreadFactor)!;
    final Paint fresnelPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = ui.Gradient.linear(
        Offset(center.dx - r, center.dy - r),
        Offset(center.dx + r, center.dy + r),
        <Color>[
          Colors.white.withValues(alpha: 0.78),
          _fresnelMid.withValues(alpha: 0.48),
          fresnelAccent.withValues(alpha: 0.62 + 0.30 * unreadFactor),
        ],
        const <double>[0.0, 0.48, 1.0],
      );
    canvas.drawCircle(center, r - strokeWidth * 0.5, fresnelPaint);

    // 5. Subtle pulsing cyan halo ring when unread messages are pending.
    if (unreadFactor > 0.01) {
      final double ringRadius = r + 1.5 + 1.4 * unreadPulse;
      final Paint unreadRingPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _electricCyan.withValues(
          alpha: unreadFactor * (0.28 + 0.26 * unreadPulse),
        );
      canvas.drawCircle(center, ringRadius, unreadRingPaint);
    }
  }

  void _drawAuroraBlob({
    required Canvas canvas,
    required Offset center,
    required double radius,
    required Color innerColor,
    required Color midColor,
  }) {
    final Paint paint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.radial(
        center,
        radius,
        <Color>[
          innerColor,
          midColor,
          midColor.withValues(alpha: 0.0),
        ],
        const <double>[0.0, 0.52, 1.0],
      );
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant AuroraOrbPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.isPanelOpen != isPanelOpen ||
        oldDelegate.hasUnread != hasUnread ||
        oldDelegate.openProgress != openProgress ||
        oldDelegate.unreadProgress != unreadProgress;
  }
}
