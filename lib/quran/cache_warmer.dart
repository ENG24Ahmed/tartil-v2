import 'package:shared_preferences/shared_preferences.dart';
import 'package:quran_app/quran/page_persistent_cache.dart';
import 'package:quran_app/quran/qpc_v1_loader.dart';
import 'package:quran_app/quran/renderers/qpc_v4_renderer.dart';

/// مفتاح SharedPreferences: هل اكتمل التسخين المسبق لـ QPC1؟
const String _kWarmV1Done = 'cache_warm_v1_done_v1';

/// مفتاح SharedPreferences: هل اكتمل التسخين المسبق لـ QPC4؟
const String _kWarmV4Done = 'cache_warm_v4_done_v1';

/// عدد الصفحات الكلي في المصحف.
const int _kTotalPages = 604;

/// عدد الصفحات التي تُعالَج في كل دفعة قبل إعطاء الأولوية للـ UI.
const int _kBatchSize = 5;

/// يُسخّن كاش ROM للمصحف كاملاً في الخلفية — مرة واحدة فقط عند أول تثبيت.
///
/// الآلية:
/// - يتحقق من SharedPreferences: إن اكتمل التسخين سابقاً يتوقف فوراً.
/// - يعالج الصفحات دفعةً دفعةً ([_kBatchSize]) مع توقف قصير بين كل دفعة
///   حتى لا يُثقّل الـ UI thread.
/// - عند الاكتمال يحفظ العلامة في SharedPreferences.
class CacheWarmer {
  CacheWarmer._();
  static final CacheWarmer instance = CacheWarmer._();

  bool _running = false;

  /// يبدأ التسخين في الخلفية لوضع QPC1.
  /// آمن للاستدعاء أكثر من مرة — يتجاهل إن كان يعمل أو اكتمل.
  Future<void> warmV1({void Function(int done, int total)? onProgress}) async {
    if (_running) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kWarmV1Done) == true) return;
    _running = true;
    try {
      for (var page = 1; page <= _kTotalPages; page++) {
        // تخطّى الصفحات الموجودة بالفعل في ROM
        if (await PagePersistentCache.instance.has('qpc1', page)) {
          onProgress?.call(page, _kTotalPages);
          continue;
        }
        try {
          await loadQpcV1Page(page).then((lines) async {
            if (lines.isNotEmpty) {
              await PagePersistentCache.instance.put('qpc1', page, lines);
            }
          });
        } catch (_) {
          // تجاهل أخطاء صفحة واحدة والاستمرار
        }
        onProgress?.call(page, _kTotalPages);
        // توقف قصير بعد كل دفعة لإعطاء الأولوية للـ UI
        if (page % _kBatchSize == 0) {
          await Future.delayed(const Duration(milliseconds: 16));
        }
      }
      await prefs.setBool(_kWarmV1Done, true);
    } finally {
      _running = false;
    }
  }

  /// يبدأ التسخين في الخلفية لوضع QPC4.
  Future<void> warmV4({void Function(int done, int total)? onProgress}) async {
    if (_running) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kWarmV4Done) == true) return;
    _running = true;
    try {
      for (var page = 1; page <= _kTotalPages; page++) {
        if (await PagePersistentCache.instance.has('qpc4', page)) {
          onProgress?.call(page, _kTotalPages);
          continue;
        }
        try {
          final lines = await QpcV4Renderer.instance
              .loadPage(page, populateRamCache: false);
          if (lines.isNotEmpty) {
            await PagePersistentCache.instance.put('qpc4', page, lines);
          }
        } catch (_) {}
        onProgress?.call(page, _kTotalPages);
        if (page % _kBatchSize == 0) {
          await Future.delayed(const Duration(milliseconds: 16));
        }
      }
      await prefs.setBool(_kWarmV4Done, true);
    } finally {
      _running = false;
    }
  }

  /// يُسخّن كلا الوضعين تسلسلياً في الخلفية.
  /// استدعِه مرة واحدة بعد تهيئة قاعدة البيانات.
  Future<void> warmAll({void Function(int done, int total)? onProgress}) async {
    await warmV1(onProgress: onProgress);
    await warmV4(onProgress: onProgress);
  }

  /// هل اكتمل التسخين لـ QPC1؟
  static Future<bool> isV1Done() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWarmV1Done) == true;
  }

  /// هل اكتمل التسخين لـ QPC4؟
  static Future<bool> isV4Done() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWarmV4Done) == true;
  }

  /// إعادة ضبط العلامات (للاختبار أو عند تحديث نسخة البيانات).
  static Future<void> resetFlags() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kWarmV1Done);
    await prefs.remove(_kWarmV4Done);
  }
}
