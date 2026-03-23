import 'package:shared_preferences/shared_preferences.dart';

/// تعليمات أول تشغيل: لمسة للقائمة، ضغط مطوّل للاستماع، ثم تغيير القارئ.
class MushafIntroPrefs {
  MushafIntroPrefs._();

  static const _keyDone = 'mushaf_intro_v1_done';
  static const _keyStep = 'mushaf_intro_v1_step';

  /// 0 = خطوة «لمسة القائمة»، 1 = «ضغط مطوّل»، 2 = انتظار التشغيل ثم «القارئ».
  static const int stepTapMenu = 0;
  static const int stepLongPress = 1;
  static const int stepWaitPlayback = 2;
  static const int stepReciter = 3;
  static const int completedMarker = 4;

  /// مستخدم قديم: كان لديه صفحة محفوظة قبل إضافة التعريف — لا نعرض الجولة.
  static Future<void> migrateLegacyUsers() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_keyDone) == true) return;
    if (p.containsKey(_keyStep)) return;
    final hadPage = p.getInt('current_page') != null;
    if (hadPage) {
      await p.setBool(_keyDone, true);
      await p.setInt(_keyStep, completedMarker);
    }
  }

  static Future<bool> isCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyDone) ?? false;
  }

  static Future<int> loadStep() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_keyDone) == true) return completedMarker;
    return p.getInt(_keyStep) ?? stepTapMenu;
  }

  static Future<void> setStep(int step) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyStep, step);
  }

  static Future<void> markCompleted() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyDone, true);
    await p.setInt(_keyStep, completedMarker);
  }
}
