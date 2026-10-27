import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../data/api.dart';
import '../data/auth.dart';

/// W1: the ONE sign-in surface. No signup, no forgot-password, one generic
/// error, and a deliberate delay after a rejection.
///
/// Lives under `lib/ui/` (not in the shell) because Settings pushes it: the
/// shell only boots the session, this screen is where the session is made.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = Api.instance.isReady
        ? Api.instance.client.auth.currentUser?.email
        : null;
    _email.text = current ?? '';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await OwnerAuth.instance.signIn(
      email: _email.text.trim(),
      password: _password.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = outcome == SignInOutcome.ok
          ? null
          : outcome.messageWithDetail(OwnerAuth.instance.lastError);
    });
    if (outcome == SignInOutcome.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Signed in successfully!'),
          backgroundColor: Color(0xFF2E7D32),
          duration: Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: const Text('Sign in'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/stardom-logo.webp',
                      height: 52,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const Text(
                        'ST⭐️R:Dom',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '×',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.inkSoft,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Image.asset(
                      'assets/ka1ofakind.png',
                      height: 48,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Sign in once to sync this device with the shop database.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppColors.inkSoft),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Owner email',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.inkSoft,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.m),
                    ),
                  ),
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Sign in',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.failedBg,
                    border: Border.all(color: AppColors.failedBorder),
                    borderRadius: BorderRadius.circular(AppRadius.m),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 20,
                        color: AppColors.failedText,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.failedText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
