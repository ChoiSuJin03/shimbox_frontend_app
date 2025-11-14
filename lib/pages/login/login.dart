import 'package:flutter/material.dart';
import 'package:shimbox_app/models/login_data.dart';
import 'package:shimbox_app/models/login_response.dart' as model;
import 'package:shimbox_app/utils/api_service.dart';
import '../root/root.dart';
import 'package:shimbox_app/models/test_user_data.dart';
import 'package:shimbox_app/services/global_location_bootstrap.dart'; // ✅ 로그인 직후 위치/WS 부트스트랩 (선택)

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _loading = false;

  Future<void> _login() async {
    if (_loading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('아이디와 비밀번호를 입력해 주세요.')));
      return;
    }

    setState(() => _loading = true);
    try {
      final loginData = LoginData(email: email, password: password);
      final model.LoginResponse? result = await ApiService.loginUser(loginData);
      debugPrint('서버 응답값: $result');

      if (result == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❗계정이 존재하지 않거나 비밀번호가 틀렸습니다')),
        );
        return;
      }

      final userData = result.data;
      if (!userData.approved) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❗승인되지 않은 계정입니다. 관리자에게 문의하세요.')),
        );
        return;
      }

      // 승인된 사용자 저장
      UserData.name = userData.name;
      UserData.token = userData.accessToken;
      UserData.email = email;
      UserData.residence = userData.residence;

      debugPrint('✅ 저장된 사용자 이름: ${UserData.name}');
      debugPrint('✅ 저장된 토큰: ${UserData.token}');

      // ✅ 선택: 로그인 직후 전역 위치/WS 시작 (홈에 안 가도 위치 전송)
      try {
        await GlobalLocationBootstrap.instance.start();
      } catch (e) {
        debugPrint('GlobalLocationBootstrap start 실패: $e');
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RootPage()),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 45),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 로고
                Image.asset('assets/images/logo.png', height: 55),
                const SizedBox(height: 60),

                // 아이디
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '아이디',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFD9D9D9)),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFD9D9D9)),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // 비밀번호
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '비밀번호',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFD9D9D9)),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFD9D9D9)),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // 링크 (회원가입 동작 추가)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      '아이디 찾기 | 비밀번호 찾기 | ',
                      style: TextStyle(fontSize: 13, color: Color(0xFFBDBDBD)),
                    ),
                    GestureDetector(
                      onTap:
                          () => Navigator.pushNamed(
                            context,
                            '/start',
                          ), // ✅ 회원가입 이동
                      child: const Text(
                        '회원가입',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF54D2A7),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 70),

                // 로그인 버튼
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF54D2A7),
                      shape: const StadiumBorder(),
                    ),
                    child:
                        _loading
                            ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                            : const Text(
                              '로그인',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
