// شاشة خيارات المطور — للمعلومات أثناء التطوير.
// يمكن إزالة هذا الملف والمجلد بالكامل عند النشر.
import 'package:flutter/material.dart';
import 'package:quran_app/quran/page_cache.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/quran_reader.dart' show QpcMushafMode;

class DeveloperOptionsScreen extends StatefulWidget {
  const DeveloperOptionsScreen({
    super.key,
    required this.currentMode,
  });

  final QpcMushafMode currentMode;

  @override
  State<DeveloperOptionsScreen> createState() => _DeveloperOptionsScreenState();
}

class _DeveloperOptionsScreenState extends State<DeveloperOptionsScreen> {
  int _persistedCount = 0;
  int _persistedSize = 0;
  int _persistedRawCount = 0;
  int _persistedQpc1Count = 0;

  @override
  void initState() {
    super.initState();
    _loadPersistedStats();
  }

  Future<void> _loadPersistedStats() async {
    final count = await PagePersistentCache.instance.totalPersistedCount;
    final size = await PagePersistentCache.instance.totalSizeBytes;
    final qpc4Raw =
        await PagePersistentCache.instance.getPageCountForMode('qpc4');
    final qpc1Count =
        await PagePersistentCache.instance.getPageCountForMode('qpc1');
    if (mounted) {
      setState(() {
        _persistedCount = count;
        _persistedSize = size;
        _persistedRawCount = qpc4Raw;
        _persistedQpc1Count = qpc1Count;
      });
    }
  }

  static String _modeLabel(QpcMushafMode mode) {
    return switch (mode) {
      QpcMushafMode.qpc1 => 'QPC V1',
      QpcMushafMode.qpc4 => 'QPC V4',
      QpcMushafMode.qpc4Black => 'QPC V4 أسود',
    };
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes بايت';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} ك.ب';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} م.ب';
  }

  @override
  Widget build(BuildContext context) {
    final cache = PageCache.instance;
    final qpc1Count = cache.getPageCountForMode('qpc1');
    final qpc4Count = cache.getPageCountForMode('qpc4');
    final totalEntriesCount = cache.totalCachedPageCount;
    final sizeBytes = cache.estimatedSizeBytes;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('خيار المطور'),
          backgroundColor: const Color(0xFF2E7D32),
          foregroundColor: Colors.white,
        ),
        backgroundColor: const Color(0xFFE8F5E9),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _loadPersistedStats,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _InfoCard(
                  title: 'عدد الصفحات المحملة (الذاكرة)',
                  items: [
                    ('إجمالي الكاش', '$totalEntriesCount'),
                    ('QPC V1', '$qpc1Count / 604'),
                    ('QPC V4', '$qpc4Count / 604'),
                  ],
                ),
                const SizedBox(height: 12),
                _InfoCard(
                  title: 'التخزين الدائم (ROM)',
                  items: [
                    ('إجمالي الملفات', '$_persistedCount'),
                    ('QPC4', '$_persistedRawCount / 604'),
                    ('QPC1', '$_persistedQpc1Count / 604'),
                    ('حجم الملفات', _formatBytes(_persistedSize)),
                  ],
                ),
                const SizedBox(height: 12),
                _InfoCard(
                  title: 'الوضع المستخدم',
                  items: [
                    ('النوع', _modeLabel(widget.currentMode)),
                  ],
                ),
                const SizedBox(height: 12),
                _InfoCard(
                  title: 'حجم الذاكرة',
                  items: [
                    ('التقدير (نص + تخطيط)', _formatBytes(sizeBytes)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.items,
  });

  final String title;
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B5E20),
              ),
            ),
            const SizedBox(height: 12),
            ...items.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        e.$1,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      Text(
                        e.$2,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
