import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_page.dart';
import 'pos_page.dart'; // Akşamcı kayıttan sonra POS'a gider

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  _RegisterPageState createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final auth = FirebaseAuth.instance;
  bool loading = false;

  // "firin" / "firinci" / "tezgah" / "aksamci" / "siparis"
  String? _selectedRole;

  Future<void> register() async {
    if (_selectedRole == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Lütfen rol seçin (Üretici / Fırıncı / Tezgah / Akşamcı / Sipariş)")),
      );
      return;
    }

    try {
      setState(() => loading = true);
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      final cred = await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = cred.user!;
      final displayName = email.split('@').first;

      // Kayıt edilecek "role" (kanonik) ve "roleSource" (ham seçim)
      // - firin     -> role = producer
      // - firinci   -> role = baker
      // - tezgah    -> role = user
      // - aksamci   -> role = user
      // - siparis   -> role = order   ✅ yeni
      final String roleToSave;
      switch (_selectedRole) {
        case 'firin':
          roleToSave = 'producer';
          break;
        case 'firinci':
          roleToSave = 'baker';
          break;
        case 'siparis':
          roleToSave = 'order'; // ✅ yeni kanonik rol
          break;
        case 'tezgah':
        case 'aksamci':
        default:
          roleToSave = 'user';
      }

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'email': email,
        'name': displayName,
        'role': roleToSave,          // kanonik rol (LoginPage bunu okuyacak)
        'roleSource': _selectedRole, // "firin" / "firinci" / "tezgah" / "aksamci" / "siparis"
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtAuth': user.metadata.creationTime,
        'lastSignInAtAuth': user.metadata.lastSignInTime,
        'emailVerified': user.emailVerified,
      }, SetOptions(merge: true));

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kayıt başarılı.')),
      );

      // Yönlendirme (şimdilik aynı):
      // - Akşamcı: direkt POS (satış) sayfasına
      // - Diğer roller: LoginPage
      if (_selectedRole == 'aksamci') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PosSalesPage(userId: user.uid),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
      }
    } on FirebaseAuthException catch (e) {
      final msg = e.message ?? 'Registration failed';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gold = Colors.amber[700];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Günlüoğlu",
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: gold,
              ),
            ),
            const SizedBox(height: 40),

            // EMAIL
            TextField(
              controller: emailController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: "Email",
                labelStyle: TextStyle(color: gold),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: gold ?? Colors.amber),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.amberAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // PASSWORD
            TextField(
              controller: passwordController,
              style: const TextStyle(color: Colors.white),
              obscureText: true,
              decoration: InputDecoration(
                labelText: "Password",
                labelStyle: TextStyle(color: gold),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: gold ?? Colors.amber),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.amberAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ROL SEÇİMİ
            DropdownButtonFormField<String>(
              value: _selectedRole,
              dropdownColor: Colors.black,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: "Rol Seçiniz",
                labelStyle: TextStyle(color: gold),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: gold ?? Colors.amber),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.amberAccent, width: 2),
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: "firin",
                  child: Text("Üretici", style: TextStyle(color: Colors.white)),
                ),
                DropdownMenuItem(
                  value: "firinci",
                  child: Text("Fırıncı", style: TextStyle(color: Colors.white)),
                ),
                DropdownMenuItem(
                  value: "tezgah",
                  child: Text("Tezgah", style: TextStyle(color: Colors.white)),
                ),
                DropdownMenuItem(
                  value: "aksamci",
                  child: Text("Akşamcı", style: TextStyle(color: Colors.white)),
                ),
                DropdownMenuItem(
                  value: "siparis",
                  child: Text("Sipariş", style: TextStyle(color: Colors.white)), // ✅ yeni
                ),
              ],
              onChanged: (v) => setState(() => _selectedRole = v),
            ),
            const SizedBox(height: 20),

            // REGISTER BUTTON
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: loading
                    ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                )
                    : const Text("Register", style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
