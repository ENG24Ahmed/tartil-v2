import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ضروري لتشغيل الصوت من روابط الشبكة (مثل أذكار islamway) وتقليل التعارض مع مشغّل التلاوة
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const TartilApp());
}

class TartilApp extends StatelessWidget {
  const TartilApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترتيل',
      home: SplashScreen(),
    );
  }
}
