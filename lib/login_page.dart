// login_page.dart (LoginPage)
// ✅ Girişten hemen sonra users/{uid} dokümanı okunur.
// ✅ isActive == false ise kullanıcı derhal signOut edilir ve engel mesajı gösterilir.
// ✅ "Beni hatırla" ile uygulama açılışında otomatik rol sayfasına yönlendirme yapılır.

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stock_from_customer_orders_page.dart'; // günlük stok ekranı (tüm siparişler)
import 'pos_page.dart';
import 'users_page.dart';
import 'baker_tava_page.dart';   // üretim ekranı
import 'CustomerOrderPage.dart'; // 🆕 sipariş ekranı

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final auth = FirebaseAuth.instance;

  // UI state
  bool rememberMe = false;     // ✅ Beni hatırla seçimi
  bool _checkingAuto = true;   // Uygulama açılışında otomatik kontrol (splash/loader)
  bool _navigated = false;     // Aynı anda birden fazla pushReplacement'ı engelle

  @override
  void initState() {
    super.initState();
    _tryAutoLogin(); // Uygulama açılınca otomatik kontrol et
  }

  /// Açılışta "beni hatırla" ve mevcut oturumu kontrol et.
  Future<void> _tryAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedRemember = prefs.getBool('rememberMe') ?? false;

      // Kullanıcı daha önce "beni hatırla" dediyse ve hala oturum varsa
      final user = auth.currentUser;
      if (savedRemember && user != null) {
        final uid = user.uid;

        final snap = await FirebaseFirestore.instance
            .collection("users")
            .doc(uid)
            .get();
        final data = snap.data() ?? {};

        final bool isActive = (data["isActive"] as bool?) ?? true;
        if (!isActive) {
          await auth.signOut();
          await prefs.remove('rememberMe');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Hesabın engellenmiş. Lütfen yöneticiyle iletişime geç.")),
            );
          }
        } else {
          final String role = (data["role"] as String?) ?? "user";
          // Kaydı güncel tutmak adına rolü de saklayalım (opsiyonel)
          await prefs.setString('lastRole', role);
          if (mounted) _navigateByRole(uid, role);
        }
      }
    } catch (_) {
      // Sessiz geç; login ekranı gösterilecek
    } finally {
      if (mounted) setState(() => _checkingAuto = false);
    }
  }

  Future<void> login() async {
    try {
      final cred = await auth.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final uid = cred.user!.uid;

      // Firestore'dan kullanıcı verisi
      final snap = await FirebaseFirestore.instance.collection("users").doc(uid).get();
      final data = snap.data() ?? {};

      // 🔒 Hesap engelli mi?
      final bool isActive = (data["isActive"] as bool?) ?? true;
      if (!isActive) {
        await auth.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Hesabın engellenmiş. Lütfen yöneticiyle iletişime geç.")),
          );
        }
        return;
      }

      final String role = (data["role"] as String?) ?? "user"; // admin / producer / order / baker / user

      // ✅ Beni hatırla seçiliyse kaydet
      final prefs = await SharedPreferences.getInstance();
      if (rememberMe) {
        await prefs.setBool('rememberMe', true);
        await prefs.setString('lastRole', role);
      } else {
        await prefs.remove('rememberMe');
        await prefs.remove('lastRole');
      }

      if (mounted) _navigateByRole(uid, role);
    } on FirebaseAuthException catch (e) {
      String msg;
      if (e.code == 'user-not-found') {
        msg = "Kullanıcı bulunamadı!";
      } else if (e.code == 'wrong-password') {
        msg = "Şifre yanlış!";
      } else {
        msg = "Login failed: ${e.message}";
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bilinmeyen hata: $e")),
        );
      }
    }
  }

  void _navigateByRole(String uid, String role) {
    if (_navigated || !mounted) return;
    _navigated = true;

    if (role == "admin") {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => UsersPage(currentUid: uid, currentRole: role)),
      );
      return;
    }

    if (role == "producer") {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => BakerTavaPage(userId: uid)),
      );
      return;
    }

    if (role == "order") {
      // 🆕 Sipariş rolü → CustomerOrderPage
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => CustomerOrderPage(userId: uid)),
      );
      return;
    }

    if (role == "baker") {
      // Fırıncı: Günlük stok sayfasına (tüm siparişleri görsün)
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => StockFromCustomerOrdersPage(
            userId: uid,      // sayfa imzası gereği
            showAll: true,    // baker tüm kullanıcıları görsün
          ),
        ),
      );
      return;
    }

    // default: user (tezgah / akşamcı) → POS
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => PosSalesPage(userId: uid)),
    );
  }

  // Opsiyonel: uygulama içinde bir yerde çağırmak istersen kullan.
  Future<void> appLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('rememberMe');
    await prefs.remove('lastRole');
    await auth.signOut();
    if (!mounted) return;
    // LoginPage'e dönmek için:
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Açılışta otomatik kontrol sırasında basit bir loader göstermek UI'i temiz tutar
    if (_checkingAuto) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Günlüoğlu",
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber[700],
                  shadows: const [
                    Shadow(
                      blurRadius: 4,
                      color: Colors.black54,
                      offset: Offset(2, 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // EMAIL
              TextField(
                controller: emailController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: "Email",
                  labelStyle: const TextStyle(color: Colors.amber),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber.shade700),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber.shade400, width: 2),
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
                  labelStyle: const TextStyle(color: Colors.amber),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber.shade700),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber.shade400, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // ✅ Beni Hatırla
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Checkbox(
                    value: rememberMe,
                    activeColor: Colors.amber[700],
                    onChanged: (v) => setState(() => rememberMe = v ?? false),
                  ),
                  const Text("Beni hatırla", style: TextStyle(color: Colors.white)),
                ],
              ),
              const SizedBox(height: 8),

              ElevatedButton(
                onPressed: login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber[700],
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text("Login", style: TextStyle(fontSize: 18)),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
