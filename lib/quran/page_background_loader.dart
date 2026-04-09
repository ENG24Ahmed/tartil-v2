/// سابقاً: تحميل تدريجي لملء كاش الذاكرة. كاش صفحات RAM أُلغي؛ يبقى تتبع الصفحة الحالية فقط.
class PageBackgroundLoader {
  PageBackgroundLoader._();
  static final PageBackgroundLoader instance = PageBackgroundLoader._();

  static const int totalPages = 604;

  void setCurrentPage(int _) {
    // يُستدعى عند التقليب؛ لا تخزين بعد إلغاء كاش RAM للصفحات.
  }

  void start() {
    // عمداً فارغ: المحتوى يُحمَّل من التخزين الدائم عند بناء الصفحة.
  }

  void stop() {}

  void dispose() {}
}
