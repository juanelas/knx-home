// Reusable visual controls used by KNX entity cards.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';

class FanGlyph extends StatelessWidget {
  const FanGlyph({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(27.5),
    painter: _FanGlyphPainter(color),
  );
}

class _FanGlyphPainter extends CustomPainter {
  const _FanGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..color = color;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    for (var blade = 0; blade < 3; blade++) {
      canvas.save();
      canvas.rotate(blade * 2 * math.pi / 3);
      final path = Path()
        ..moveTo(-1.5, -1.5)
        ..cubicTo(-4.5, -4, -4, -8, -1.2, -9)
        ..cubicTo(2, -10, 3.8, -6, 2.2, -3.2)
        ..cubicTo(1.5, -2, 0.5, -1.5, -1.5, -1.5)
        ..close();
      canvas.drawPath(path, paint);
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, 2.2, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FanGlyphPainter old) => old.color != color;
}

class HeatCoolSwitch extends StatelessWidget {
  const HeatCoolSwitch({
    super.key,
    required this.cooling,
    required this.enabled,
    required this.onChanged,
  });

  final bool cooling;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Heating or cooling',
    value: cooling ? 'Cooling' : 'Heating',
    child: Container(
      width: 75,
      height: 35,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xffe9ece7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: line),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: cooling ? Alignment.centerRight : Alignment.centerLeft,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: Container(
              width: 33.75,
              height: 30,
              decoration: BoxDecoration(
                color: cooling ? blue : orange,
                borderRadius: BorderRadius.circular(17.5),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _mode(
                  icon: Icons.local_fire_department,
                  selected: !cooling,
                  onTap: enabled ? () => onChanged(false) : null,
                ),
              ),
              Expanded(
                child: _mode(
                  icon: Icons.ac_unit,
                  selected: cooling,
                  onTap: enabled ? () => onChanged(true) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _mode({
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: Center(
      child: Icon(icon, size: 19, color: selected ? Colors.white : muted),
    ),
  );
}

class _TouchDragSurface extends StatelessWidget {
  const _TouchDragSurface({
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: enabled
        ? {
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (instance) {},
                ),
          }
        : const {},
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled ? (event) => onStart(event.localPosition) : null,
      onPointerMove: enabled ? (event) => onUpdate(event.localPosition) : null,
      onPointerUp: enabled ? (_) => onEnd() : null,
      onPointerCancel: enabled ? (_) => onEnd() : null,
      child: child,
    ),
  );
}

class DialControl extends StatefulWidget {
  const DialControl({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.label,
    required this.format,
    required this.enabled,
    required this.onCommit,
    this.arcValue,
    this.color,
    this.sub,
    this.diameter = 134,
  });
  final double diameter;
  final double value, min, max, step;
  final double? arcValue;
  final Color? color;
  final String label;
  final String Function(double) format;
  final String? sub;
  final bool enabled;
  final ValueChanged<double> onCommit;
  @override
  State<DialControl> createState() => _DialControlState();
}

class _DialControlState extends State<DialControl> {
  late double draft = widget.value;
  bool dragging = false;
  @override
  void didUpdateWidget(covariant DialControl old) {
    super.didUpdateWidget(old);
    if (!dragging) draft = widget.value;
  }

  double _snap(double n) =>
      (widget.min + ((n - widget.min) / widget.step).round() * widget.step)
          .clamp(widget.min, widget.max);
  void _move(Offset p, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final deg =
        (math.atan2(p.dy - c.dy, p.dx - c.dx) * 180 / math.pi + 360) % 360;
    double a = (deg - 135 + 360) % 360;
    if (a > 270) a = a > 315 ? 0 : 270;
    setState(
      () => draft = _snap(widget.min + a / 270 * (widget.max - widget.min)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = ((draft - widget.min) / (widget.max - widget.min)).clamp(
      0.0,
      1.0,
    );
    final af =
        (((widget.arcValue ?? draft) - widget.min) / (widget.max - widget.min))
            .clamp(0.0, 1.0);
    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: _TouchDragSurface(
        enabled: widget.enabled,
        onStart: (position) {
          dragging = true;
          _move(position, Size(widget.diameter, widget.diameter));
        },
        onUpdate: (position) =>
            _move(position, Size(widget.diameter, widget.diameter)),
        onEnd: () {
          dragging = false;
          widget.onCommit(draft);
        },
        child: CustomPaint(
          painter: _DialPainter(
            f,
            af,
            widget.color ?? const Color(0xffaeb8b1),
            widget.format(draft),
            widget.sub,
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.f, this.af, this.color, this.text, this.sub);
  final double f, af;
  final Color color;
  final String text;
  final String? sub;
  @override
  void paint(Canvas c, Size s) {
    final center = Offset(s.width / 2, s.height / 2);
    final radius = math.min(s.width, s.height) / 2 - 13;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..color = const Color(0xffe8ebe6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11
      ..strokeCap = StrokeCap.round;
    c.drawArc(rect, 135 * math.pi / 180, 270 * math.pi / 180, false, base);
    if (af > 0) {
      c.drawArc(
        rect,
        135 * math.pi / 180,
        270 * af * math.pi / 180,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round,
      );
    }
    final a = (135 + 270 * f) * math.pi / 180;
    final point = Offset(
      center.dx + radius * math.cos(a),
      center.dy + radius * math.sin(a),
    );
    c.drawCircle(point, 12.5, Paint()..color = color);
    _draw(c, text, center.translate(0, -10), 32, ink, FontWeight.w500);
    if (sub != null) {
      _draw(c, sub!, center.translate(0, 18), 16, muted, FontWeight.w400);
    }
  }

  void _draw(
    Canvas c,
    String t,
    Offset p,
    double size,
    Color color,
    FontWeight w,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(fontSize: size, color: color, fontWeight: w),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 140);
    tp.paint(c, Offset(p.dx - tp.width / 2, p.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _DialPainter o) =>
      o.f != f ||
      o.af != af ||
      o.color != color ||
      o.text != text ||
      o.sub != sub;
}

class CoverControl extends StatefulWidget {
  const CoverControl({
    super.key,
    required this.value,
    required this.enabled,
    required this.movingDirection,
    required this.movingTarget,
    required this.up,
    required this.down,
    required this.stop,
    required this.setPosition,
  });
  final double value;
  final bool enabled;
  final int movingDirection;
  final double movingTarget;
  final VoidCallback up, down;
  final VoidCallback stop;
  final ValueChanged<double> setPosition;
  @override
  State<CoverControl> createState() => _CoverControlState();
}

class _CoverControlState extends State<CoverControl> {
  static const _blindHeight = 145.0;
  double target = 50;
  bool adjusting = false, init = false, hoveringTargetLine = false;

  @override
  void didUpdateWidget(covariant CoverControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!adjusting) {
      target = widget.movingDirection == 0 ? widget.value : widget.movingTarget;
    }
  }

  double get _markerPosition =>
      widget.movingDirection != 0 || !adjusting ? widget.value : target;

  void _updateTarget(double y) {
    final next = (100 * (1 - y / _blindHeight)).clamp(0.0, 100.0);
    setState(() {
      target = next;
      adjusting = true;
    });
  }

  void _updateHover(double y) {
    final lineY = _blindHeight * (1 - _markerPosition.clamp(0, 100) / 100);
    final overLine = (y - lineY).abs() <= 7;
    if (overLine != hoveringTargetLine) {
      setState(() => hoveringTargetLine = overLine);
    }
  }

  void _commitTarget() {
    final value = target;
    setState(() => adjusting = false);
    widget.setPosition(value);
  }

  @override
  Widget build(BuildContext context) {
    if (!init) {
      target = widget.value;
      init = true;
    }
    final markerPosition = _markerPosition;
    final currentLineY = _blindHeight * (1 - widget.value.clamp(0, 100) / 100);
    final targetLineY =
        _blindHeight *
        (1 -
            (widget.movingDirection != 0 ? widget.movingTarget : markerPosition)
                    .clamp(0, 100) /
                100);
    final darkExtent = widget.movingDirection != 0 || adjusting
        ? math.min(currentLineY, targetLineY)
        : currentLineY;
    final percentageColor = darkExtent > _blindHeight / 2 ? Colors.white : dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 95,
          height: _blindHeight,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CustomPaint(
                    painter: _BlindPositionPainter(
                      widget.value,
                      target: widget.movingDirection != 0
                          ? widget.movingTarget
                          : markerPosition,
                      moving: widget.movingDirection != 0 || adjusting,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: MouseRegion(
                  cursor: hoveringTargetLine
                      ? SystemMouseCursors.resizeUpDown
                      : SystemMouseCursors.basic,
                  onHover: (event) => _updateHover(event.localPosition.dy),
                  onExit: (_) => setState(() => hoveringTargetLine = false),
                  child: _TouchDragSurface(
                    enabled: widget.enabled,
                    onStart: (position) => _updateTarget(position.dy),
                    onUpdate: (position) => _updateTarget(position.dy),
                    onEnd: _commitTarget,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BlindTargetPainter(markerPosition),
                  ),
                ),
              ),
              IgnorePointer(
                child: Center(
                  child: Text(
                    '${(adjusting ? target : widget.value).round()}%',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      color: percentageColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed:
                  widget.enabled &&
                      (widget.value < 100 || widget.movingDirection == 1)
                  ? (widget.movingDirection == 1 ? widget.stop : widget.up)
                  : null,
              icon: Icon(
                Icons.keyboard_arrow_up,
                size: 30,
                color: widget.movingDirection == 1 ? blue : null,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed:
                  widget.enabled &&
                      (widget.value > 0 || widget.movingDirection == -1)
                  ? (widget.movingDirection == -1 ? widget.stop : widget.down)
                  : null,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: 30,
                color: widget.movingDirection == -1 ? blue : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BlindPositionPainter extends CustomPainter {
  const _BlindPositionPainter(
    this.position, {
    required this.target,
    required this.moving,
  });

  final double position;
  final double target;
  final bool moving;

  @override
  void paint(Canvas canvas, Size size) {
    final lineY = size.height * (1 - position.clamp(0, 100) / 100);
    final targetY = size.height * (1 - target.clamp(0, 100) / 100);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (moving && targetY != lineY) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          math.min(lineY, targetY),
          size.width,
          (lineY - targetY).abs(),
        ),
        Paint()..color = const Color(0xffd5dbd6),
      );
    }
    final darkExtent = moving ? math.min(lineY, targetY) : lineY;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, darkExtent),
      Paint()..color = const Color(0xff9ca9a0),
    );
    canvas.drawLine(
      Offset(0, lineY),
      Offset(size.width, lineY),
      Paint()
        ..color = const Color(0xff66736a)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _BlindPositionPainter old) =>
      old.position != position || old.target != target || old.moving != moving;
}

class _BlindTargetPainter extends CustomPainter {
  const _BlindTargetPainter(this.position);

  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * (1 - position.clamp(0, 100) / 100);
    final lineHeight = 2.0;
    final top = (y - lineHeight / 2).clamp(0.0, size.height - lineHeight);
    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, lineHeight),
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _BlindTargetPainter old) =>
      old.position != position;
}
