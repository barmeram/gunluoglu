// ==============================
// FILE: baker_stock_page.dart
// ==============================
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BakerStockPage extends StatelessWidget {
  const BakerStockPage({
    super.key,
    required this.userId,
    this.initialItems, // AdminDailyPicker'dan gelen aggregate özet (opsiyonel)
    this.dayLabel, // Hangi gün gösterilecek? (opsiyonel, yoksa bugün)
  });

  final String userId;
  final List<Map<String, dynamic>>? initialItems;
  final String? dayLabel;

  // Gün anahtarı
  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  String _day() => dayLabel ?? _todayKey();

  String _slugify(String s) {
    const trMap = {
      'İ': 'I',
      'I': 'I',
      'Ş': 'S',
      'Ğ': 'G',
      'Ü': 'U',
      'Ö': 'O',
      'Ç': 'C',
      'ı': 'i',
      'ş': 's',
      'ğ': 'g',
      'ü': 'u',
      'ö': 'o',
      'ç': 'c',
    };
    final replaced = s.trim().split('').map((c) => trMap[c] ?? c).join();
    final lower = replaced.toLowerCase();
    final keep = RegExp(r'[a-z0-9]+');
    final parts = keep.allMatches(lower).map((m) => m.group(0)!).toList();
    final slug = parts.join('_');
    return slug.isEmpty ? 'urun_${DateTime.now().millisecondsSinceEpoch}' : slug;
  }

  // --- Stok Sıfırlama: sadece seçili gün ---
  Future<void> _resetDayStocks(BuildContext context) async {
    final db = FirebaseFirestore.instance;
    final day = _day();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stokları Sıfırla'),
        content: Text(
          "'$day' gününe ait production kayıtlarının TÜMÜ silinecek. Emin misin?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Evet, Sıfırla')),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      const chunk = 450;
      Query<Map<String, dynamic>> q =
      db.collection('production').where('date', isEqualTo: day).limit(chunk);
      while (true) {
        final snap = await q.get();
        if (snap.docs.isEmpty) break;

        final batch = db.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Stoklar sıfırlandı ✅ ($day)")),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sıfırlama hatası: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final db = FirebaseFirestore.instance;
    final day = _day();
    final s = _scaleFor(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: Text(
          'Stok • $day',
          style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 16 * s),
        ),
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
          // AdminDailyPicker'dan gelen özet varsa göster
          if (initialItems != null && initialItems!.isNotEmpty)
            _AdminSummaryBanner(initialItems: initialItems!),

          // Canlı stok (seçili gün)
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db
                  .collection('production')
                  .where('date', isEqualTo: day)
                  .orderBy('productName')
                  .snapshots(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: EdgeInsets.all(12 * s),
                      child: Text(
                        'Hata oluştu: ${snap.error}',
                        style: TextStyle(color: Colors.red, fontSize: 14 * s),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFFD700)),
                  );
                }

                final docs = snap.data!.docs;

                // Toplam hesapla
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
                      child: Text(
                        'Kayıt yok',
                        style: TextStyle(color: gold, fontSize: 16 * s),
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    // toplam özet bar
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
                              child: Text(
                                'Toplam Tava: $totalTrays',
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14 * s,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 8 * s),
                          Expanded(
                            child: FittedBox(
                              alignment: Alignment.centerRight,
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Toplam Adet: $totalUnits',
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14 * s,
                                ),
                              ),
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
                          final name = (m['productName'] ?? '-') as String;
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
                                // Ürün adı (sol) – genişleyebilir
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

                                // Değerler (sağ) – wrap ile taşmadan alt satıra iner
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
          Text(
            '$label: ',
            style: TextStyle(color: Colors.white70, fontSize: 12 * s),
          ),
          Text(
            value,
            style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 14 * s),
          ),
        ],
      ),
    );
  }
}

/// AdminDailyPicker’dan gelen agregasyonun üstte küçük özeti
class _AdminSummaryBanner extends StatelessWidget {
  const _AdminSummaryBanner({required this.initialItems});
  final List<Map<String, dynamic>> initialItems;

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final s = _scaleFor(context);

    int tTrays = 0, tUnits = 0;
    for (final m in initialItems) {
      tTrays += (m['trays'] as int?) ?? 0;
      tUnits += (m['units'] as int?) ?? 0;
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
          Text(
            'Toplam Tava: $tTrays • Toplam Adet: $tUnits',
            style: TextStyle(color: Colors.white70, fontSize: 12 * s),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// GENEL YARDIMCI (başka sayfalardan da çağırabilirsin)
/// production.productName eşleşmesine göre `units` değerini güvenli şekilde azaltır.
/// - Transaction kullanır (yarış durumunda doğru çalışır)
/// - Negatife düşmez (taban 0)
/// - Doküman yoksa oluşturur (units 0’dan aşağı düşmez)
/// ---------------------------------------------------------------------------
Future<void> decrementProductionUnitsByName({
  required String productName,
  required int minusUnits,
}) async {
  if (minusUnits <= 0) return;
  final db = FirebaseFirestore.instance;
  final col = db.collection('production');

  // productName ile doküman bul (yoksa yeni doc referansı)
  final q = await col.where('productName', isEqualTo: productName).limit(1).get();
  final ref = q.docs.isNotEmpty ? q.docs.first.reference : col.doc();

  await db.runTransaction((tx) async {
    final snap = await tx.get(ref);
    final curUnits = (snap.data()?['units'] as num?)?.toInt() ?? 0;
    final curTrays = (snap.data()?['trays'] as num?)?.toInt() ?? 0;
    final newUnits = max(0, curUnits - minusUnits);

    tx.set(
      ref,
      {
        'productName': productName,
        'units': newUnits,
        'trays': curTrays,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  });
}

/// -------------------------
/// Responsive ölçek yardımcı
/// -------------------------
double _scaleFor(BuildContext context) {
  final mq = MediaQuery.of(context);
  // shortestSide: telefonlar için yatay/dikey fark etmeden en güvenli metrik
  final shortest = mq.size.shortestSide; // dp
  // 360dp taban kabul (orta boy telefon). 4" civarı ~320dp → ~0.9; 7" civarı daha büyük → >1.0
  double s = shortest / 360.0;
  // Aşırı küçülme/büyümeyi sınırlayalım:
  if (s < 0.85) s = 0.85; // çok küçük ekranlarda bile okunabilir kalsın
  if (s > 1.35) s = 1.35; // çok büyük telefon/tabletlerde aşırı büyütmeyelim
  return s;
}
