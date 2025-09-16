import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import 'package:shimbox_app/pages/alarm/alarm.dart';
import 'package:shimbox_app/pages/main_scaffold.dart';
import 'package:shimbox_app/pages/signup/signup_detail.dart';
import 'package:shimbox_app/pages/signup/signup_experience.dart';
import 'package:shimbox_app/pages/signup/signup_health.dart';
import 'package:shimbox_app/pages/signup/signup_license.dart';
import 'package:shimbox_app/pages/signup/signup_waiting.dart';
// import 'app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:get/get.dart';
import 'bindings/init_bindings.dart';
import 'pages/root/root.dart';
import 'pages/splash.dart';
import 'pages/start.dart';
import 'pages/login/login.dart';
import 'pages/signup/signup_verify.dart';
import 'pages/signup/signup_account.dart';
import 'pages/signup/signup_license.dart';
import 'pages/signup/signup_experience.dart';
import 'pages/signup/signup_detail.dart';
import 'pages/signup/signup_health.dart';
import 'pages/signup/signup_waiting.dart';
import 'pages/health/health_status.dart';
import 'pages/wearable/wearable.dart';
import 'pages/home/home.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;

import 'controllers/alarm_controller.dart';
import 'package:get/get.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 한 번만 호출!
  await Firebase.initializeApp(); // Firebase 초기화

  // final prefs = await SharedPreferences.getInstance();
  // localUser.UserData.token = prefs.getString('token');
  Get.put(AlarmController(), permanent: true);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      initialBinding: InitBindings(),
      initialRoute: '/splash',
      getPages: [
        GetPage(name: '/splash', page: () => SplashPage()),
        GetPage(name: '/start', page: () => StartPage()),
        GetPage(name: '/login', page: () => LoginPage()),
        GetPage(name: '/signup_verify', page: () => SignupVerifyPage()),
        GetPage(name: '/signup_account', page: () => SignupAccountPage()),
        GetPage(name: '/signup_license', page: () => LicenseVerifyPage()),
        GetPage(name: '/signup_experience', page: () => ExperienceSelectPage()),
        GetPage(name: '/signup_detail', page: () => ExperienceDetailPage()),
        GetPage(name: '/signup_health', page: () => SignupHealthPage()),
        GetPage(name: '/signup_waiting', page: () => SignupCompletePage()),
        GetPage(name: '/home', page: () => RootPage()),
        GetPage(name: '/health_status', page: () => HealthPage()),
        GetPage(name: '/wearable', page: () => WearablePage()),
        // GetPage(name: '/main', page: () => HomePage()),
        GetPage(name: '/main', page: () => MainScaffold()),
        // GetPage(name: '/alarmPage', page: () => AlarmPage()),
        GetPage(name: '/alarmPage', page: () => const AlarmPage()),
      ],
    );
  }
}
