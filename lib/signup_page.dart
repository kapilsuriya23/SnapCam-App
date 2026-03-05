// signup_page.dart
// SnapCam — Sign-up screen.
// Stores name/email/password locally via SharedPreferences (through Auth).
// On success → navigates directly to CamPage (user is immediately logged in).

import 'package:flutter/material.dart';
import 'auth.dart'
    show Auth, AuthField, AuthBtn, authHeader, showAuthErr, kAuthBg, kAuthGrey;
import 'main.dart' show CamPage;

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});
  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage>
    with SingleTickerProviderStateMixin {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
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
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final err = await Auth.signUp(
      name: _name.text.trim(),
      email: _email.text.trim(),
      password: _pass.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      showAuthErr(context, err);
      return;
    }
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const CamPage(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

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
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Padding(
                      padding: EdgeInsets.only(bottom: 32),
                      child: Row(
                        children: [
                          Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: kAuthGrey,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Back',
                            style: TextStyle(color: kAuthGrey, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),

                  authHeader(
                    'Create account.',
                    'Stored locally — private by default.',
                  ),
                  const SizedBox(height: 44),

                  AuthField(
                    ctrl: _name,
                    hint: 'Full name',
                    validator: (v) {
                      if (v == null || v.trim().isEmpty)
                        return 'Enter your name';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  AuthField(
                    ctrl: _email,
                    hint: 'Email address',
                    keyboard: TextInputType.emailAddress,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty)
                        return 'Enter your email';
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
                      if (v == null || v.length < 6)
                        return 'At least 6 characters';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  AuthField(
                    ctrl: _confirm,
                    hint: 'Confirm password',
                    obscure: true,
                    validator: (v) {
                      if (v != _pass.text) return 'Passwords do not match';
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),

                  AuthBtn(
                    label: 'CREATE ACCOUNT',
                    loading: _loading,
                    onTap: _signUp,
                  ),
                  const SizedBox(height: 24),

                  const Center(
                    child: Text(
                      '🔒  All data stays on this device. Nothing is uploaded.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: kAuthGrey,
                        fontSize: 11,
                        letterSpacing: 0.3,
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
