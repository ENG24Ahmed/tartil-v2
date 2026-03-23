import 'package:flutter/material.dart';

/// يوفر callback للضغط المطول على آية — إن وُجد يُستدعى بدل القائمة الافتراضية.
class AyahLongPressScope extends InheritedWidget {
  const AyahLongPressScope({
    super.key,
    required this.onAyahLongPress,
    required super.child,
  });

  final void Function(
    BuildContext context,
    int sura,
    int ayah,
    String ayahText,
    VoidCallback onClearSelection,
  ) onAyahLongPress;

  static AyahLongPressScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AyahLongPressScope>();
  }

  @override
  bool updateShouldNotify(AyahLongPressScope old) =>
      onAyahLongPress != old.onAyahLongPress;
}
