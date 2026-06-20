import 'package:flutter/material.dart';

import 'package:quran_app/quran/quran_menu_palette.dart';

/// شريط علوي موحّد للقوائم الفرعية (RTL): رجوع يمينًا — عنوان في الوسط — إغلاق الكل يسارًا.
class NestedQuranMenuAppBar extends StatelessWidget {
  const NestedQuranMenuAppBar({
    super.key,
    required this.title,
    required this.titleStyle,
    this.onBack,
    required this.onDismissAll,
  });

  final String title;
  final TextStyle titleStyle;
  final VoidCallback? onBack;
  final VoidCallback onDismissAll;

  @override
  Widget build(BuildContext context) {
    final barIcon = QuranMenuPalette.of(context).nestedBarIcon;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: onBack != null
                ? IconButton(
                    tooltip: 'رجوع',
                    icon: Icon(Icons.arrow_back, color: barIcon),
                    onPressed: onBack,
                  )
                : const SizedBox(width: 48, height: 48),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              tooltip: 'إغلاق',
              icon: Icon(Icons.close, color: barIcon),
              onPressed: onDismissAll,
            ),
          ),
        ],
      ),
    );
  }
}
