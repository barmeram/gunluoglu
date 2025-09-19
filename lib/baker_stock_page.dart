// ===========================
// FILE: baker_stock_page.dart
// ===========================
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BakerStockPage extends StatelessWidget {
  const BakerStockPage({
    super.key,
    required this.userId,
    required this.day,           // ← AdminDailyPicker'dan zorunlu geliyor
    this.initialItems,
  });

  final String userId;
  final String day; // "YYYY-MM-DD" beklenir
  final List<Map<String, dynamic>>? initialItems;

  // --- Güvenlik: tarih anahtarı geçerli mi? ---
  bool get _isValidDay => _isValidDateKey(day);

  // --- Stok Sıfırlama: sadece SEÇİLİ gün, production_daily üzerinde ---
  Future<void> _resetDayStocks(BuildContext context) async {
    if (!_isValidDay) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geçersiz gün formatı. Sıfırlama iptal.')),
      );
      return;
    }

    final db = FirebaseFirestore.instance;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stokları Sıfırla'),
        content: Text("'$day' gününe ait production_daily kayıtlarının TÜMÜ silinecek. Emin misin?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Evet, Sıfırla')),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // Çok belge varsa parça parça sil
      const chunk = 450;
      Query<Map<String, dynamic>> q = db
          .collection('production_daily')
          .where('date', isEqualTo: day)
          .limit(chunk);

      while (true) {
        final snap = await q.get();
        if (snap.docs.isEmpty) break;

        final batch = db.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Stoklar sıfırlandı ✅ ($day)")),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sıfırlama hatası: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final db = FirebaseFirestore.instance;
    final s = _scaleFor(context);

    // Seçili güne ait CANLI stok listesi (production_daily)
    final Stream<QuerySnapshot<Map<String, dynamic>>>? dayStream = _isValidDay
        ? db
        .collection('production_daily')
        .where('date', isEqualTo: day)
        .orderBy('productName')
        .snapshots()
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: Text('Stok • $day',
            style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 16 * s)),
        actions: [
          IconButton(
            tooltip: 'Seçili günü sıfırla',
            icon: const Icon(Icons.delete_forever, color: gold),
            onPressed: () => _resetDayStocks(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // AdminDailyPicker’dan gelen özet varsa üst bantta göster
          if (initialItems != null && initialItems!.isNotEmpty)
            _AdminSummaryBanner(initialItems: initialItems!),

          // Tarih formatı bozuksa hemen uyar
          if (!_isValidDay)
            Container(
              width: double.infinity,
              margin: EdgeInsets.fromLTRB(12 * s, 12 * s, 12 * s, 0),
              padding: EdgeInsets.all(12 * s),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                border: Border.all(color: Colors.redAccent),
                borderRadius: BorderRadius.circular(10 * s),
              ),
              child: const Text(
                "Gün formatı hatalı. Beklenen örnek: 2025-01-17",
                style: TextStyle(color: Colors.redAccent),
              ),
            ),

          // Seçili güne ait CANLI stok listesi (production_daily)
          if (_isValidDay)
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                // Key: gün değişirse StreamBuilder komple yenilensin
                key: ValueKey<String>('stock-$day'),
                stream: dayStream,
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(12 * s),
                        child: Text('Hata oluştu: ${snap.error}',
                            style: TextStyle(color: Colors.red, fontSize: 14 * s),
                            textAlign: TextAlign.center),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(color: Color(0xFFFFD700)),
                    );
                  }

                  final docs = snap.data!.docs;

                  // Toplamlar
                  int totalTrays = 0;
                  int totalUnits = 0;
                  for (final d in docs) {
                    final m = d.data();
                    totalTrays += (m['trays'] as num? ?? 0).toInt();
                    totalUnits += (m['units'] as num? ?? 0).toInt();
                  }

                  if (docs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(16 * s),
                        child: Text('Kayıt yok', style: TextStyle(color: gold, fontSize: 16 * s)),
                      ),
                    );
                  }

                  return Column(
                    children: [
                      // toplam özet
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.all(12 * s),
                        padding: EdgeInsets.all(12 * s),
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(10 * s),
                          border: Border.all(color: gold, width: 1),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: FittedBox(
                                alignment: Alignment.centerLeft,
                                fit: BoxFit.scaleDown,
                                child: Text('Toplam Tava: $totalTrays',
                                    maxLines: 1,
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14 * s)),
                              ),
                            ),
                            SizedBox(width: 8 * s),
                            Expanded(
                              child: FittedBox(
                                alignment: Alignment.centerRight,
                                fit: BoxFit.scaleDown,
                                child: Text('Toplam Adet: $totalUnits',
                                    maxLines: 1,
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14 * s)),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ürün listesi
                      Expanded(
                        child: ListView.separated(
                          padding: EdgeInsets.fromLTRB(12 * s, 6 * s, 12 * s, 12 * s),
                          itemCount: docs.length,
                          separatorBuilder: (_, __) => SizedBox(height: 10 * s),
                          itemBuilder: (_, i) {
                            final m = docs[i].data();
                            final name = (m['productName'] as String?) ?? '-';
                            final trays = (m['trays'] as num? ?? 0).toInt();
                            final units = (m['units'] as num? ?? 0).toInt();

                            return Container(
                              padding: EdgeInsets.all(12 * s),
                              decoration: BoxDecoration(
                                color: Colors.grey[900],
                                borderRadius: BorderRadius.circular(12 * s),
                                border: Border.all(color: gold, width: 1),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: gold,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14 * s,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 8 * s),
                                  Flexible(
                                    child: Wrap(
                                      alignment: WrapAlignment.end,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      spacing: 8 * s,
                                      runSpacing: 6 * s,
                                      children: [
                                        _pill(context, 'Tava', trays.toString()),
                                        _pill(context, 'Adet', units.toString()),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // Basit pill
  Widget _pill(BuildContext context, String label, String value) {
    const gold = Color(0xFFFFD700);
    final s = _scaleFor(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 6 * s),
      decoration: BoxDecoration(
        border: Border.all(color: gold, width: 1),
        color: Colors.black,
        borderRadius: BorderRadius.circular(999 * s),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: TextStyle(color: Colors.white70, fontSize: 12 * s)),
          Text(value, style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 14 * s)),
        ],
      ),
    );
  }
}

class _AdminSummaryBanner extends StatelessWidget {
  const _AdminSummaryBanner({required this.initialItems});
  final List<Map<String, dynamic>> initialItems;

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final s = _scaleFor(context);

    int tTrays = 0, tUnits = 0;
    for (final m in initialItems) {
      tTrays += (m['trays'] as num? ?? 0).toInt();
      tUnits += (m['units'] as num? ?? 0).toInt();
    }

    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(12 * s, 12 * s, 12 * s, 0),
      padding: EdgeInsets.all(12 * s),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border.all(color: gold, width: 1),
        borderRadius: BorderRadius.circular(10 * s),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Admin Özeti',
              style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 14 * s)),
          SizedBox(height: 6 * s),
          Text('Toplam Tava: $tTrays • Toplam Adet: $tUnits',
              style: TextStyle(color: Colors.white70, fontSize: 12 * s)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// GENEL YARDIMCI (GÜNCEL)
// productName’e göre GÜNLÜK kayıtta `units` azaltır.
// `day` verilmezse bugünün tarihi kullanılır. (production_daily)
// Transaction kullanır, negatife düşürmez.
// ---------------------------------------------------------------------------
Future<void> decrementProductionUnitsByName({
  required String productName,
  required int minusUnits,
  String? day, // opsiyonel: verilmezse bugün kullanılır
}) async {
  if (minusUnits <= 0) return;

  final db = FirebaseFirestore.instance;
  final col = db.collection('production_daily');
  final String finalDay = (day != null && day.isNotEmpty) ? day : _todayKey();

  // Aynı gün + ürün adına göre bir kaydı hedefle
  Query<Map<String, dynamic>> q = col
      .where('productName', isEqualTo: productName)
      .where('date', isEqualTo: finalDay);

  final snap = await q.limit(1).get();
  final ref = snap.docs.isNotEmpty
      ? snap.docs.first.reference
      : col.doc("${finalDay}__${productName.hashCode}");

  await db.runTransaction((tx) async {
    final cur = await tx.get(ref);
    final curUnits = (cur.data()?['units'] as num?)?.toInt() ?? 0;
    final curTrays = (cur.data()?['trays'] as num?)?.toInt() ?? 0;
    final newUnits = max(0, curUnits - minusUnits);

    tx.set(
      ref,
      {
        'date': finalDay,
        'productName': productName,
        'units': newUnits,
        'trays': curTrays,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  });
}

// -------------------------
// Responsive ölçek yardımcı
// -------------------------
double _scaleFor(BuildContext context) {
  final mq = MediaQuery.of(context);
  final shortest = mq.size.shortestSide;
  double s = shortest / 360.0;
  if (s < 0.85) s = 0.85;
  if (s > 1.35) s = 1.35;
  return s;
}

// -------------------------
// Bugünün YYYY-MM-DD formatı
// -------------------------
String _todayKey() {
  final now = DateTime.now();
  return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
}

// -------------------------
// Tarih format kontrol ("YYYY-MM-DD")
// -------------------------
bool _isValidDateKey(String v) {
  final re = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (!re.hasMatch(v)) return false;
  try {
    final y = int.parse(v.substring(0, 4));
    final m = int.parse(v.substring(5, 7));
    final d = int.parse(v.substring(8, 10));
    final dt = DateTime(y, m, d);
    // normalize edip tekrar formatlayalım
    final back = "${dt.year.toString().padLeft(4, '0')}-"
        "${dt.month.toString().padLeft(2, '0')}-"
        "${dt.day.toString().padLeft(2, '0')}";
    return back == v;
  } catch (_) {
    return false;
  }
}
