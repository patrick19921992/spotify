import 'package:flutter/material.dart';

/// Text für schmale Kacheln: Flutter bricht ein Wort, das nicht in die Zeile passt, mitten im Wort um
/// („Lieblingssong“ / „s“). Hier wird die Schrift stattdessen so weit verkleinert, dass das längste Wort in
/// eine Zeile passt (höchstens auf [minScale]); mehrere Wörter dürfen wie gewohnt umbrechen.
class WordSafeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int maxLines;
  final double minScale;

  const WordSafeText(this.text, {super.key, required this.style, this.maxLines = 2, this.minScale = 0.7});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        // Mit der tatsächlich verwendeten Schrift messen (Schriftart kommt aus dem Theme)
        final effective = DefaultTextStyle.of(context).style.merge(style);
        var factor = 1.0;
        if (constraints.maxWidth.isFinite) {
          var widest = 0.0;
          for (final word in text.split(RegExp(r'\s+'))) {
            if (word.isEmpty) continue;
            final painter = TextPainter(
              text: TextSpan(text: word, style: effective),
              textScaler: scaler,
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout();
            if (painter.width > widest) widest = painter.width;
            painter.dispose();
          }
          // 2 px Luft: sonst bricht ein Wort, das rechnerisch genau passt, durch Rundung doch noch um
          final room = constraints.maxWidth - 2;
          if (widest > room) factor = (room / widest).clamp(minScale, 1.0);
        }
        final size = effective.fontSize ?? 14;
        return Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: factor < 1 ? style.copyWith(fontSize: size * factor) : style,
        );
      },
    );
  }
}
