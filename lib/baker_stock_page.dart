import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BakerStockPage extends StatelessWidget {
  const BakerStockPage({super.key, required this.userId});

  final String userId;

  // --- Stok Sıfırlama: onay + güvenli toplu silme (450'lik batch) ---
  Future<void> _resetStocks(BuildContext context) async {
    final db = FirebaseFirestore.instance;

    // 1) Kullanıcıdan onay al
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stokları Sıfırla'),
        content: const Text(
          'Production koleksiyonundaki TÜM stok kayıtları silinecek. Emin misin?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Evet, Sıfırla')),
        ],
      ),
    );

    if (confirm != true) return;

    // 2) Tüm dokümanları parça parça (<=500 limitine takılmadan) sil
    try {
      const chunk = 450;
      Query<Map<String, dynamic>> q = db.collection('production').limit(chunk);
      while (true) {
        final snap = await q.get();
        if (snap.docs.isEmpty) break;

        final batch = db.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
        // Döngü tekrar limit(chunk) çekerek devam eder; tümü silinene kadar
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Stoklar sıfırlandı ✅')),
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

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text(
          'Stok',
          style: TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Stokları sıfırla',
            icon: const Icon(Icons.delete_forever, color: gold),
            onPressed: () => _resetStocks(context),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('production').orderBy('productName').snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('Hata oluştu', style: TextStyle(color: Colors.red, fontSize: 16)),
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
            return const Center(
              child: Text('Kayıt yok', style: TextStyle(color: Color(0xFFFFD700), fontSize: 16)),
            );
          }

          return Column(
            children: [
              // toplam özet bar
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: gold),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Toplam Tava: $totalTrays',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Toplam Adet: $totalUnits',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),

              // ürün listesi
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = docs[i].data();
                    final name = (m['productName'] ?? '-') as String;
                    final trays = (m['trays'] as num? ?? 0).toInt();
                    final units = (m['units'] as num? ?? 0).toInt();

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: gold, width: 1),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(name, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
                          Row(
                            children: [
                              _pill('Tava', trays.toString()),
                              const SizedBox(width: 8),
                              _pill('Adet', units.toString()),
                            ],
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
    );
  }

  Widget _pill(String label, String value) {
    const gold = Color(0xFFFFD700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: gold),
        color: Colors.black,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(
            value,
            style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 14),
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
