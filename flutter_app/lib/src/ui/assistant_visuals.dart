// Shared visual language for the resident assistant surfaces, used by both the
// Android overlay (its own isolate) and the macOS floating window. Pure widgets
// and constants — no platform calls — so both ends look identical.
import 'package:flutter/material.dart';

/// Brand accent for the bubble — a soft indigo→violet gradient gives the floating
/// chip some depth instead of a flat disc.
const Color kAssistantAccent = Color(0xFF4E63FF);
const List<Color> kAssistantBubbleGradient = [Color(0xFF5B6CFF), Color(0xFF7A4DFF)];

/// The unread badge colour.
const Color kAssistantBadge = Color(0xFFFF3B30);

/// Corner radius and motion shared across the expanded panels.
const double kPanelRadius = 22;
const Duration kAssistantMotion = Duration(milliseconds: 220);
const Curve kAssistantCurve = Curves.easeOutCubic;

/// Soft elevation so a panel lifts off the scrim.
List<BoxShadow> assistantPanelShadow(Brightness brightness) => [
      BoxShadow(
        color: Colors.black.withValues(alpha: brightness == Brightness.dark ? 0.55 : 0.25),
        blurRadius: 32,
        spreadRadius: 2,
        offset: const Offset(0, 12),
      ),
    ];

/// The resident bubble: a gradient disc with a soft shadow and a ringed unread
/// badge. Tap handling is the caller's job (each platform wires its own).
class AssistantBubble extends StatelessWidget {
  const AssistantBubble({
    super.key,
    required this.count,
    this.size = 56,
    this.ringColor = const Color(0xFF101012),
  });

  /// Pending-count shown in the badge; hidden when 0.
  final int count;
  final double size;

  /// Colour of the thin ring separating the badge from the bubble (use the
  /// backdrop the bubble floats on — transparent overlay → near-black).
  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: kAssistantBubbleGradient,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: kAssistantAccent.withValues(alpha: 0.45),
                blurRadius: 18,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(Icons.all_inbox_rounded,
              color: Colors.white, size: size * 0.46),
        ),
        if (count > 0)
          Positioned(
            right: -3,
            top: -3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              decoration: BoxDecoration(
                color: kAssistantBadge,
                shape: BoxShape.rectangle,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ringColor, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
