// auth.dart
// Pure authentication layer for SnapCam.
// No imports from the rest of the app — zero circular dependencies.
//
// Contains:
//   • Auth          — SharedPreferences storage (sign-up, log-in, log-out)
//   • Shared UI     — AuthField, AuthBtn, authHeader, showAuthErr
//   • Palette consts — kAuthBg, kAuthSurface, kAuthBorder, etc.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// PALETTE
// ═══════════════════════════════════════════════════════════════════════════════
const kAuthBg = Color(0xFF0A0A0A);
const kAuthSurface = Color(0xFF141414);
const kAuthBorder = Color(0xFF2A2A2A);
const kAuthRed = Color(0xFFFF3B30);
const kAuthWhite = Color(0xFFFFFFFF);
const kAuthGrey = Color(0xFF6B6B6B);
const kAuthGrey2 = Color(0xFF3A3A3A);

// ═══════════════════════════════════════════════════════════════════════════════
// AUTH — local SharedPreferences storage
//
// Schema (all keys namespaced under 'sc_'):
//   sc_user_name:{email}  →  display name
//   sc_user_pass:{email}  →  password  (plain — local-only, no server)
//   sc_logged_in          →  email of current user, or ''
// ═══════════════════════════════════════════════════════════════════════════════
class Auth {
  Auth._();

  static const _loggedInKey = 'sc_logged_in';
  static String _nameKey(String e) => 'sc_user_name:$e';
  static String _passKey(String e) => 'sc_user_pass:$e';

  static Future<String?> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final norm = email.trim().toLowerCase();
    if (prefs.containsKey(_passKey(norm))) return 'Email already registered.';
    await prefs.setString(_nameKey(norm), name.trim());
    await prefs.setString(_passKey(norm), password);
    await prefs.setString(_loggedInKey, norm);
    return null;
  }

  static Future<String?> logIn({
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final norm = email.trim().toLowerCase();
    final stored = prefs.getString(_passKey(norm));
    if (stored == null) return 'No account found for that email.';
    if (stored != password) return 'Incorrect password.';
    await prefs.setString(_loggedInKey, norm);
    return null;
  }

  static Future<String?> currentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_loggedInKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  static Future<String> displayName(String email) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey(email)) ?? email;
  }

  static Future<void> logOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_loggedInKey, '');
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// AuthField — animated input with red focus glow
// ═══════════════════════════════════════════════════════════════════════════════
class AuthField extends StatefulWidget {
  final TextEditingController ctrl;
  final String hint;
  final bool obscure;
  final TextInputType keyboard;
  final String? Function(String?)? validator;

  const AuthField({
    super.key,
    required this.ctrl,
    required this.hint,
    this.obscure = false,
    this.keyboard = TextInputType.text,
    this.validator,
  });

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  bool _show = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (f) => setState(() => _focused = f),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: kAuthSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _focused ? kAuthRed.withOpacity(0.6) : kAuthBorder,
          width: 1,
        ),
      ),
      child: TextFormField(
        controller: widget.ctrl,
        obscureText: widget.obscure && !_show,
        keyboardType: widget.keyboard,
        validator: widget.validator,
        style: const TextStyle(
          color: kAuthWhite,
          fontSize: 15,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w300,
        ),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(
            color: kAuthGrey,
            fontSize: 15,
            fontWeight: FontWeight.w300,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          suffixIcon: widget.obscure
              ? GestureDetector(
                  onTap: () => setState(() => _show = !_show),
                  child: Icon(
                    _show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: kAuthGrey,
                    size: 18,
                  ),
                )
              : null,
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// AuthBtn — red primary button with press-scale + loading state
// ═══════════════════════════════════════════════════════════════════════════════
class AuthBtn extends StatefulWidget {
  final String label;
  final bool loading;
  final VoidCallback onTap;

  const AuthBtn({
    super.key,
    required this.label,
    required this.loading,
    required this.onTap,
  });

  @override
  State<AuthBtn> createState() => _AuthBtnState();
}

class _AuthBtnState extends State<AuthBtn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  );
  late final _scale = Tween<double>(
    begin: 1.0,
    end: 0.96,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => _c.forward(),
    onTapUp: (_) {
      _c.reverse();
      widget.onTap();
    },
    onTapCancel: () => _c.reverse(),
    child: ScaleTransition(
      scale: _scale,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: kAuthRed,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55FF3B30),
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: widget.loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  widget.label,
                  style: const TextStyle(
                    color: kAuthWhite,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// authHeader — SnapCam logo + title + subtitle
// ═══════════════════════════════════════════════════════════════════════════════
Widget authHeader(String title, String subtitle) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: kAuthRed,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(Icons.videocam_rounded, color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'SnapCam',
          style: TextStyle(
            color: kAuthWhite,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    ),
    const SizedBox(height: 36),
    Text(
      title,
      style: const TextStyle(
        color: kAuthWhite,
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
    ),
    const SizedBox(height: 6),
    Text(
      subtitle,
      style: const TextStyle(
        color: kAuthGrey,
        fontSize: 14,
        fontWeight: FontWeight.w300,
        letterSpacing: 0.2,
      ),
    ),
  ],
);

// ═══════════════════════════════════════════════════════════════════════════════
// showAuthErr — dark floating snackbar for errors
// ═══════════════════════════════════════════════════════════════════════════════
void showAuthErr(BuildContext ctx, String msg) =>
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: const Color(0xFF1E1E1E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
