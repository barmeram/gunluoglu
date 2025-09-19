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
  String? role;             // kullanıcının rolü

  // Satış toplamları (kullanıcıya göre)
  Map<String, double> today = {};
  Map<String, double> week = {};   // ✅ YENİ: Bu Hafta
  Map<String, double> month = {};
  Map<String, double> year = {};

  // uid -> görünen isim (name yoksa email, o da yoksa uid)
  Map<String, String> userNames = {};

  // ------ STEP 1: Responsive yardımcı ------
  double _rsp(BuildContext ctx, double base) {
    final w = MediaQuery.of(ctx).size.width; // 320..430 arası (telefon)
    final scale = (w / 390).clamp(0.85, 1.15);
    return base * scale;
  }

  @override
  void initState() {
    super.initState();
    _checkRoleAndLoad(); // önce rolü kontrol et
  }

  // ------ STEP 2: Rol Kontrolü ------
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
        await _loadUsers();       // isimleri çek
        await _loadCompetition(); // satışları çek
      }
      setState(() => loading = false);
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

  // ------ STEP 3: USERS'tan isimleri çek ------
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kullanıcı isimleri alınamadı: $e')),
        );
      }
    }
  }

  // ------ STEP 4: Tarih yardımcıları ------
  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _startOfNextDay(DateTime d) => _startOfDay(d).add(const Duration(days: 1));

  DateTime _startOfWeek(DateTime d) {
    // Pazartesi başlangıç
    final diff = d.weekday - DateTime.monday; // 0..6
    return _startOfDay(d).subtract(Duration(days: diff));
  }

  DateTime _startOfNextWeek(DateTime d) => _startOfWeek(d).add(const Duration(days: 7));

  DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _startOfNextMonth(DateTime d) => DateTime(d.year, d.month + 1, 1);

  DateTime _startOfYear(DateTime d) => DateTime(d.year, 1, 1);
  DateTime _startOfNextYear(DateTime d) => DateTime(d.year + 1, 1, 1);

  // ------ STEP 5: Aralıkta kullanıcıya göre toplam ------
  Future<Map<String, double>> _sumByUserBetween(DateTime start, DateTime end) async {
    // createdAt >= start AND createdAt < end
    final qs = await db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .get();

    final Map<String, double> out = {};
    for (final doc in qs.docs) {
      final m = doc.data();
      final uid = (m['userId'] ?? '??').toString();
      final price = (m['totalPrice'] as num?)?.toDouble() ?? 0.0;
      out[uid] = (out[uid] ?? 0) + price;
    }
    return out;
  }

  // ------ STEP 6: Satışları yükle (Gün/Hafta/Ay/Yıl) ------
  Future<void> _loadCompetition() async {
    if (!hasAccess) return;
    setState(() => loading = true);

    final now = DateTime.now();

    final dayStart = _startOfDay(now);
    final dayEnd = _startOfNextDay(now);

    final weekStart = _startOfWeek(now);
    final weekEnd = _startOfNextWeek(now);

    final monthStart = _startOfMonth(now);
    final monthEnd = _startOfNextMonth(now);

    final yearStart = _startOfYear(now);
    final yearEnd = _startOfNextYear(now);

    try {
      final results = await Future.wait([
        _sumByUserBetween(dayStart, dayEnd),     // bugün
        _sumByUserBetween(weekStart, weekEnd),   // ✅ bu hafta
        _sumByUserBetween(monthStart, monthEnd), // bu ay
        _sumByUserBetween(yearStart, yearEnd),   // bu yıl
      ]);

      setState(() {
        today = results[0];
        week  = results[1];
        month = results[2];
        year  = results[3];
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

  // ------ STEP 7: Toptan yenile ------
  Future<void> _refreshAll() async {
    await _loadUsers();
    await _loadCompetition();
  }

  // ------ STEP 8: Başlık + Toplam satırı ------
  Widget _sectionHeader(BuildContext context, String title, Map<String, double> data) {
    const gold = Color(0xFFFFD700);
    final total = data.values.fold<double>(0.0, (p, c) => p + c);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: gold,
              fontSize: _rsp(context, 16),
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        // miktar sığmazsa küçült
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            "₺${total.toStringAsFixed(2)}",
            style: TextStyle(
              color: gold,
              fontWeight: FontWeight.w700,
              fontSize: _rsp(context, 14),
            ),
          ),
        ),
      ],
    );
  }

  // ------ STEP 9: Sıralama kartı (responsive) ------
  Widget _buildRanking(BuildContext context, String title, Map<String, double> data) {
    final sorted = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // çok satan en üstte

    return Card(
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(context, title, data),
            const SizedBox(height: 10),
            if (sorted.isEmpty)
              Text("Kayıt yok",
                  style: TextStyle(color: Colors.white54, fontSize: _rsp(context, 12))),
            for (final e in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    // İsim sütunu (uzunsa ellipsis)
                    Expanded(
                      child: Text(
                        userNames[e.key] ?? e.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white70, fontSize: _rsp(context, 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Miktar (FittedBox ile taşmayı engelle)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        "₺${e.value.toStringAsFixed(2)}",
                        style: TextStyle(
                          color: const Color(0xFFFFD700),
                          fontWeight: FontWeight.w600,
                          fontSize: _rsp(context, 13),
                        ),
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

  // ------ STEP 10: Özet çubukları (üstte, yatay kayar) ------
  Widget _quickSummary(BuildContext context) {
    const gold = Color(0xFFFFD700);
    Widget chip(String label, Map<String, double> data, IconData icon) {
      final total = data.values.fold<double>(0.0, (p, c) => p + c);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: gold.withOpacity(0.7)),
        ),
        child: Row(
          children: [
            Icon(icon, color: gold, size: _rsp(context, 14)),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(color: Colors.white70, fontSize: _rsp(context, 12))),
            const SizedBox(width: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                "₺${total.toStringAsFixed(2)}",
                style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: _rsp(context, 12)),
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          chip("Bugün", today, Icons.today),
          chip("Bu Hafta", week, Icons.view_week),   // ✅ Haftalık özet
          chip("Bu Ay", month, Icons.calendar_month),
          chip("Bu Yıl", year, Icons.calendar_today),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          "Satış Yarışı",
          style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: _rsp(context, 18)),
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
          : RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            // Üst özet çubukları (Bugün / Hafta / Ay / Yıl)
            _quickSummary(context),

            // Sıralama kartları
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _buildRanking(context, "Bugün", today),
                  _buildRanking(context, "Bu Hafta", week),   // ✅ YENİ
                  _buildRanking(context, "Bu Ay", month),
                  _buildRanking(context, "Bu Yıl", year),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
