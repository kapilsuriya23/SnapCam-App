// login_page.dart
// SnapCam — Login screen.
// Validates credentials against local SharedPreferences (via Auth).
// On success → navigates to CamPage.
// "Create account" → slides to SignUpPage.

import 'package:flutter/material.dart';
import 'auth.dart'
    show
        Auth,
        AuthField,
        AuthBtn,
        authHeader,
        showAuthErr,
        kAuthBg,
        kAuthBorder,
        kAuthWhite,
        kAuthGrey,
        kAuthGrey2;
import 'main.dart' show CamPage;
import 'signup_page.dart' show SignUpPage;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;

  late final _enterC = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final _enterA = CurvedAnimation(parent: _enterC, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    _enterC.forward();
  }

  @override
  void dispose() {
    _enterC.dispose();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final err = await Auth.logIn(
      email: _email.text.trim(),
      password: _pass.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      showAuthErr(context, err);
      return;
    }
    _goCamera();
  }

  void _goCamera() => Navigator.pushReplacement(
    context,
    PageRouteBuilder(
      pageBuilder: (_, __, ___) => const CamPage(),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
      transitionDuration: const Duration(milliseconds: 400),
    ),
  );

  void _goSignUp() => Navigator.push(
    context,
    PageRouteBuilder(
      pageBuilder: (_, __, ___) => const SignUpPage(),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
      transitionDuration: const Duration(milliseconds: 300),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: kAuthBg,
      body: FadeTransition(
        opacity: _enterA,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(_enterA),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(28, top + 48, 28, 32),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  authHeader('Welcome back.', 'Sign in to continue shooting.'),
                  const SizedBox(height: 44),

                  AuthField(
                    ctrl: _email,
                    hint: 'Email address',
                    keyboard: TextInputType.emailAddress,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Enter your email';
                      }

                      if (!v.contains('@')) return 'Enter a valid email';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  AuthField(
                    ctrl: _pass,
                    hint: 'Password',
                    obscure: true,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Enter your password';
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),

                  AuthBtn(label: 'SIGN IN', loading: _loading, onTap: _login),
                  const SizedBox(height: 28),

                  Row(
                    children: [
                      const Expanded(child: Divider(color: kAuthGrey2)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: const Text(
                          "Don't have an account?",
                          style: TextStyle(color: kAuthGrey, fontSize: 12),
                        ),
                      ),
                      const Expanded(child: Divider(color: kAuthGrey2)),
                    ],
                  ),
                  const SizedBox(height: 20),

                  GestureDetector(
                    onTap: _goSignUp,
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: kAuthBorder, width: 1),
                      ),
                      child: const Center(
                        child: Text(
                          'CREATE ACCOUNT',
                          style: TextStyle(
                            color: kAuthWhite,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
