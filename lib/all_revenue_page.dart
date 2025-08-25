import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AllRevenuePage extends StatefulWidget {
  const AllRevenuePage({super.key});

  @override
  State<AllRevenuePage> createState() => _AllRevenuePageState();
}

class _AllRevenuePageState extends State<AllRevenuePage> {
  final db = FirebaseFirestore.instance;

  // ---- Özet toplamlar ----
  double todayTotal = 0,    todayCash = 0,    todayCredit = 0;
  double weekTotal = 0,     weekCash = 0,     weekCredit = 0;
  double monthTotal = 0,    monthCash = 0,    monthCredit = 0;
  double yearTotal = 0,     yearCash = 0,     yearCredit = 0;

  bool loading = true;

  @override
  void initState() {
    super.initState();
    _calculateRevenue();
  }

  // ---- Tarih yardımcıları ----
  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  // Pazartesi hafta başlangıcı
  DateTime _startOfWeek(DateTime d) {
    final sod = _startOfDay(d);
    return sod.subtract(Duration(days: sod.weekday - 1));
  }

  DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _startOfYear(DateTime d) => DateTime(d.year, 1, 1);

  DateTime _endOfWeek(DateTime d) => _startOfWeek(d).add(const Duration(days: 7));
  DateTime _startOfNextMonth(DateTime d) =>
      d.month == 12 ? DateTime(d.year + 1, 1, 1) : DateTime(d.year, d.month + 1, 1);
  DateTime _startOfNextYear(DateTime d) => DateTime(d.year + 1, 1, 1);

  String _fmtDay(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  String _fmtMonth(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}";

  // ---- Ödeme tipini normalize et (nakit/kredi/diğer) ----
  String _normPayment(dynamic raw) {
    final s = (raw as String? ?? '').trim().toLowerCase();
    if (s.isEmpty) return 'other';
    if (s.contains('nakit') || s.contains('cash')) return 'cash';
    if (s.contains('kart') || s.contains('kredi') || s.contains('credit')) return 'credit';
    return 'other';
  }

  // ---- Belirli tarihten itibaren (createdAt >= from) toplam/nakit/kredi hesapla ----
  Future<_Totals> _sumSplit(DateTime from) async {
    final qs = await db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .get();

    final out = _Totals.zero();
    for (final doc in qs.docs) {
      final m = doc.data();
      final price = (m['totalPrice'] as num?)?.toDouble() ?? 0.0;
      out.total += price;

      final t = _normPayment(m['paymentType']);
      if (t == 'cash') out.cash += price;
      else if (t == 'credit') out.credit += price;
    }
    return out;
  }

  // ---- Belirli aralıkta (start <= createdAt < end) gün/ay bazında detay (Toplam/Nakit/Kredi) ----
  Future<List<_GroupEntry>> _groupedSumDetailed({
    required DateTime start,
    required DateTime end,
    required bool byMonth, // true: YYYY-MM, false: YYYY-MM-DD
  }) async {
    final qs = await db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .get();

    final Map<String, _Totals> acc = {};
    for (final doc in qs.docs) {
      final m = doc.data();
      final ts = m['createdAt'];
      if (ts is! Timestamp) continue;

      final d = ts.toDate();
      final key = byMonth ? _fmtMonth(d) : _fmtDay(d);
      final price = (m['totalPrice'] as num?)?.toDouble() ?? 0.0;
      final t = _normPayment(m['paymentType']);

      acc.putIfAbsent(key, () => _Totals.zero());
      acc[key]!.total += price;
      if (t == 'cash') acc[key]!.cash += price;
      else if (t == 'credit') acc[key]!.credit += price;
    }

    // 🔧 Hata düzeltildi: Iterable.sort yok, önce listeye çeviriyoruz
    final entries = acc.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return entries
        .map((e) => _GroupEntry(key: e.key, totals: e.value))
        .toList();
  }

  Future<void> _calculateRevenue() async {
    setState(() => loading = true);

    final now = DateTime.now();
    final sod = _startOfDay(now);
    final sow = _startOfWeek(now);
    final som = _startOfMonth(now);
    final soy = _startOfYear(now);

    try {
      final r = await Future.wait<_Totals>([
        _sumSplit(sod), // bugün
        _sumSplit(sow), // hafta
        _sumSplit(som), // ay
        _sumSplit(soy), // yıl
      ]);

      setState(() {
        todayTotal = r[0].total; todayCash = r[0].cash; todayCredit = r[0].credit;
        weekTotal  = r[1].total; weekCash  = r[1].cash; weekCredit  = r[1].credit;
        monthTotal = r[2].total; monthCash = r[2].cash; monthCredit = r[2].credit;
        yearTotal  = r[3].total; yearCash  = r[3].cash; yearCredit  = r[3].credit;
        loading = false;
      });
    } catch (e) {
      setState(() => loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hasılat hesaplanamadı: $e')),
        );
      }
    }
  }

  // Kart tıklanınca detay alt sayfasını açar
  Future<void> _openBreakdownSheet({
    required String title,
    required DateTime start,
    required DateTime end,
    required bool byMonth,
  }) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) {
        return FutureBuilder<List<_GroupEntry>>(
          future: _groupedSumDetailed(start: start, end: end, byMonth: byMonth),
          builder: (context, snap) {
            const gold = Color(0xFFFFD700);
            if (!snap.hasData) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: gold)),
              );
            }
            final data = snap.data!;
            final total = data.fold<double>(0, (a, e) => a + e.totals.total);
            final totalCash = data.fold<double>(0, (a, e) => a + e.totals.cash);
            final totalCredit = data.fold<double>(0, (a, e) => a + e.totals.credit);

            if (data.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: gold, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    const Text('Kayıt bulunamadı.',
                        style: TextStyle(color: Colors.white70)),
                  ],
                ),
              );
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              minChildSize: 0.45,
              maxChildSize: 0.92,
              builder: (_, controller) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(title,
                          style: const TextStyle(
                              color: gold, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(
                        "Toplam: ₺${total.toStringAsFixed(2)}  •  "
                            "Nakit: ₺${totalCash.toStringAsFixed(2)}  •  "
                            "Kredi: ₺${totalCredit.toStringAsFixed(2)}",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          controller: controller,
                          itemCount: data.length,
                          itemBuilder: (_, i) {
                            final row = data[i];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey[900],
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: gold),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    row.key, // YYYY-MM veya YYYY-MM-DD
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text("Toplam: ₺${row.totals.total.toStringAsFixed(2)}",
                                          style: const TextStyle(
                                              color: gold, fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text("Nakit: ₺${row.totals.cash.toStringAsFixed(2)}",
                                          style: const TextStyle(color: Colors.white70)),
                                      Text("Kredi: ₺${row.totals.credit.toStringAsFixed(2)}",
                                          style: const TextStyle(color: Colors.white70)),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Toplam Hasılat", style: TextStyle(color: gold)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            icon: const Icon(Icons.refresh, color: gold),
            onPressed: _calculateRevenue,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: gold))
          : RefreshIndicator(
        onRefresh: _calculateRevenue,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildSummary(gold),
            const SizedBox(height: 12),
            _buildCard(
              title: "Bugün",
              amount: todayTotal,
              cash: todayCash,
              credit: todayCredit,
              onTap: null, // istersen günlük sipariş listesi açabiliriz
            ),
            _buildCard(
              title: "Bu Hafta",
              amount: weekTotal,
              cash: weekCash,
              credit: weekCredit,
              onTap: () {
                final now = DateTime.now();
                final start = _startOfWeek(now);
                final end = _endOfWeek(now);
                _openBreakdownSheet(
                  title: "Bu Hafta – Günlük Toplamlar",
                  start: start,
                  end: end,
                  byMonth: false, // gün gün
                );
              },
            ),
            _buildCard(
              title: "Bu Ay",
              amount: monthTotal,
              cash: monthCash,
              credit: monthCredit,
              onTap: () {
                final now = DateTime.now();
                final start = _startOfMonth(now);
                final end = _startOfNextMonth(now);
                _openBreakdownSheet(
                  title: "Bu Ay – Günlük Toplamlar",
                  start: start,
                  end: end,
                  byMonth: false, // gün gün
                );
              },
            ),
            _buildCard(
              title: "Bu Yıl",
              amount: yearTotal,
              cash: yearCash,
              credit: yearCredit,
              onTap: () {
                final now = DateTime.now();
                final start = _startOfYear(now);
                final end = _startOfNextYear(now);
                _openBreakdownSheet(
                  title: "Bu Yıl – Aylık Toplamlar",
                  start: start,
                  end: end,
                  byMonth: true, // ay ay
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Üstte kısa özet
  Widget _buildSummary(Color gold) {
    final totalText =
        "Bugün: ₺${todayTotal.toStringAsFixed(2)}  •  "
        "Hafta: ₺${weekTotal.toStringAsFixed(2)}  •  "
        "Ay: ₺${monthTotal.toStringAsFixed(2)}  •  "
        "Yıl: ₺${yearTotal.toStringAsFixed(2)}";

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: gold),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(totalText,
              style: const TextStyle(
                color: Color(0xFFFFD700),
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 6),
          Text(
            "Nakit (Bugün/Ay/Yıl): "
                "₺${todayCash.toStringAsFixed(2)} / ₺${monthCash.toStringAsFixed(2)} / ₺${yearCash.toStringAsFixed(2)}",
            style: const TextStyle(color: Colors.white70),
          ),
          Text(
            "Kredi (Bugün/Ay/Yıl): "
                "₺${todayCredit.toStringAsFixed(2)} / ₺${monthCredit.toStringAsFixed(2)} / ₺${yearCredit.toStringAsFixed(2)}",
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required double amount,
    required double cash,
    required double credit,
    VoidCallback? onTap,
  }) {
    const gold = Color(0xFFFFD700);
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("$title:",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: gold,
                    )),
                const SizedBox(height: 6),
                Text("Nakit: ₺${cash.toStringAsFixed(2)}",
                    style: const TextStyle(color: Colors.white70)),
                Text("Kredi: ₺${credit.toStringAsFixed(2)}",
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          Text(
            "₺${amount.toStringAsFixed(2)}",
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: gold,
            ),
          ),
        ],
      ),
    );

    return Card(
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: onTap == null
          ? content
          : InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

// ---- Dahili küçük modeller ----
class _Totals {
  double total;
  double cash;
  double credit;

  _Totals({required this.total, required this.cash, required this.credit});
  factory _Totals.zero() => _Totals(total: 0, cash: 0, credit: 0);
}

class _GroupEntry {
  final String key;     // YYYY-MM veya YYYY-MM-DD
  final _Totals totals; // Toplam/Nakit/Kredi
  _GroupEntry({required this.key, required this.totals});
}
