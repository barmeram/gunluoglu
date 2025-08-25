import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CompetitionPage extends StatefulWidget {
  const CompetitionPage({super.key});

  @override
  State<CompetitionPage> createState() => _CompetitionPageState();
}

class _CompetitionPageState extends State<CompetitionPage> {
  final db = FirebaseFirestore.instance;
  final auth = FirebaseAuth.instance;

  bool loading = true;      // veri/rol yüklenirken
  bool hasAccess = false;   // sadece admin görebilsin
  String? role;             // kullanıcının rolü (debug/ilerisi için)

  // Satış toplamları
  Map<String, double> today = {};
  Map<String, double> month = {};
  Map<String, double> year = {};

  // ✅ uid -> görünen isim (name yoksa email, o da yoksa uid)
  Map<String, String> userNames = {};

  @override
  void initState() {
    super.initState();
    _checkRoleAndLoad(); // önce rolü kontrol et
  }

  // ---------- ROL KONTROLÜ ----------
  Future<void> _checkRoleAndLoad() async {
    setState(() => loading = true);

    final uid = auth.currentUser?.uid;
    if (uid == null) {
      setState(() {
        role = null;
        hasAccess = false;
        loading = false;
      });
      return;
    }

    try {
      final snap = await db.collection('users').doc(uid).get();
      role = snap.data()?['role'] as String?;
      hasAccess = role == 'admin';

      if (hasAccess) {
        // Admin ise önce kullanıcı isimlerini, sonra satışları yükle
        await _loadUsers();
        await _loadCompetition();
      } else {
        setState(() => loading = false);
      }
    } catch (e) {
      setState(() {
        hasAccess = false;
        loading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rol okunamadı: $e')),
        );
      }
    }
  }

  // ---------- USERS'tan isimleri çek ----------
  Future<void> _loadUsers() async {
    try {
      final qs = await db.collection('users').get();
      final Map<String, String> map = {};
      for (final doc in qs.docs) {
        final m = doc.data();
        final name = (m['name'] ?? m['email'] ?? doc.id).toString();
        map[doc.id] = name;
      }
      userNames = map;
    } catch (e) {
      // İsimler yüklenemese bile satışları gösterebiliriz (uid ile)
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kullanıcı isimleri alınamadı: $e')),
        );
      }
    }
  }

  // ---------- TARİH YARDIMCILARI ----------
  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _startOfYear(DateTime d) => DateTime(d.year, 1, 1);

  // ---------- KULLANICIYA GÖRE TOPLAM ----------
  Future<Map<String, double>> _sumByUser(DateTime start) async {
    final qs = await db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .get();

    final Map<String, double> out = {};
    for (final doc in qs.docs) {
      final m = doc.data();
      final uid = m['userId'] ?? '??'; // siparişi açan kişi
      final price = (m['totalPrice'] as num?)?.toDouble() ?? 0.0;
      out[uid] = (out[uid] ?? 0) + price;
    }
    return out;
  }

  // ---------- SATIŞLARI YÜKLE ----------
  Future<void> _loadCompetition() async {
    if (!hasAccess) return; // güvenli
    setState(() => loading = true);

    final now = DateTime.now();
    try {
      final results = await Future.wait([
        _sumByUser(_startOfDay(now)),   // bugün
        _sumByUser(_startOfMonth(now)), // bu ay
        _sumByUser(_startOfYear(now)),  // bu yıl
      ]);

      setState(() {
        today = results[0];
        month = results[1];
        year = results[2];
        loading = false;
      });
    } catch (e) {
      setState(() => loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Yarış verileri yüklenemedi: $e')),
        );
      }
    }
  }

  // ---------- TOPTAN YENİLE ----------
  Future<void> _refreshAll() async {
    // hem isimleri hem satışları güncelle
    await _loadUsers();
    await _loadCompetition();
  }

  // ---------- LİSTE KARTI ----------
  Widget _buildRanking(String title, Map<String, double> data) {
    final sorted = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // çok satan en üstte

    return Card(
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                  color: Color(0xFFFFD700),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                )),
            const SizedBox(height: 8),
            for (final e in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // ✅ uid yerine isim göster
                    Text(
                      userNames[e.key] ?? e.key,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Text(
                      "₺${e.value.toStringAsFixed(2)}",
                      style: const TextStyle(
                        color: Color(0xFFFFD700),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          "Satış Yarışı",
          style: TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            icon: const Icon(Icons.refresh, color: gold),
            onPressed: hasAccess ? _refreshAll : _checkRoleAndLoad,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: gold))
          : (!hasAccess)
      // Admin değilse erişim yok
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: gold, size: 40),
              const SizedBox(height: 12),
              const Text(
                "Bu sayfayı sadece admin görebilir.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, color: gold),
                label: const Text("Geri", style: TextStyle(color: gold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: gold),
                ),
              ),
            ],
          ),
        ),
      )
      // Admin ise içerik
          : RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildRanking("Bugün", today),
            _buildRanking("Bu Ay", month),
            _buildRanking("Bu Yıl", year),
          ],
        ),
      ),
    );
  }
}
