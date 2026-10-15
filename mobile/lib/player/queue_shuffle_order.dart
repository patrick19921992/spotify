import 'package:just_audio/just_audio.dart';

/// Zufallsreihenfolge der Warteschlange.
///
/// just_audio verteilt neu eingefügte Titel zufällig – auch vor den aktuellen Titel, wo sie bei
/// Zufallswiedergabe nie mehr drankommen. Hier landen sie gezielt: „Als Nächstes spielen“ direkt hinter
/// dem aktuellen Titel, alles andere (Warteschlange, Autoplay) am Ende der Abspielreihenfolge.
class QueueShuffleOrder extends DefaultShuffleOrder {
  QueueShuffleOrder({super.random});

  /// Original-Index des Titels, hinter dem beim nächsten Einfügen eingereiht wird (null = ans Ende).
  int? insertAfter;

  /// Reihenfolge, die nach dem nächsten Einfügen wiederhergestellt wird (beim Neuaufbau der Stream-Links).
  List<int>? restore;

  @override
  void insert(int index, int count) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    final added = List.generate(count, (i) => index + i);
    var position = indices.length;
    final after = insertAfter;
    if (after != null) {
      final found = indices.indexOf(after >= index ? after + count : after);
      if (found >= 0) position = found + 1;
    }
    indices.insertAll(position, added);
    insertAfter = null;

    final saved = restore;
    if (saved != null && saved.length == indices.length && saved.toSet().containsAll(indices)) {
      indices
        ..clear()
        ..addAll(saved);
      restore = null;
    }
  }
}
