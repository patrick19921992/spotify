import 'package:flutter/material.dart';

/// Text für schmale Kacheln: Flutter bricht ein Wort, das nicht in die Zeile passt, mitten im Wort um
/// („Lieblingssong“ / „s“). Hier wird die Schrift stattdessen so weit verkleinert, dass das längste Wort in
/// eine Zeile passt (höchstens auf [minScale]); mehrere Wörter dürfen wie gewohnt umbrechen. Passt es selbst
/// dann nicht, steht der Text in einer Zeile mit „…“ – lieber gekürzt als mitten im Wort getrennt.
class WordSafeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int maxLines;
  final double minScale;

  const WordSafeText(this.text, {super.key, required this.style, this.maxLines = 2, this.minScale = 0.7});

  /// Stellen, an denen Flutter ohnehin umbrechen darf (Leerzeichen, nach Binde- und Schrägstrich).
  static final _breaks = RegExp(r'\s+|(?<=[-/])');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        // Mit der tatsächlich verwendeten Schrift messen (Schriftart kommt aus dem Theme)
        final effective = DefaultTextStyle.of(context).style.merge(style);
        // In echten Pixeln rechnen: Android 14+ vergrößert kleine Schriften stärker als große (nicht linear)
        final scaledSize = scaler.scale(effective.fontSize ?? 14);
        var widest = 0.0;
        if (constraints.maxWidth.isFinite) {
          for (final word in text.split(_breaks)) {
            if (word.isEmpty) continue;
            final painter = TextPainter(
              text: TextSpan(text: word, style: effective.copyWith(fontSize: scaledSize)),
              textScaler: TextScaler.noScaling,
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout();
            if (painter.width > widest) widest = painter.width;
            painter.dispose();
          }
        }
        // 2 px Luft: sonst bricht ein Wort, das rechnerisch genau passt, durch Rundung doch noch um
        final room = constraints.maxWidth - 2;
        if (widest <= room) {
          return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
        }
        final factor = room / widest;
        return Text(
          text,
          maxLines: factor < minScale ? 1 : maxLines,
          overflow: TextOverflow.ellipsis,
          textScaler: TextScaler.noScaling,
          style: style.copyWith(fontSize: scaledSize * factor.clamp(minScale, 1.0)),
        );
      },
    );
  }
}
