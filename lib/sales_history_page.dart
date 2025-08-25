import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SalesHistoryPage extends StatelessWidget {
  const SalesHistoryPage({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    final baseQuery = db
        .collection('orders')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true);

    const gold = Color(0xFFFFD700);

    // Basit ödeme tipi etiketi
    Widget paymentChip(String paymentType) {
      // Görünüm: küçük border'lı rozet
      final text = paymentType.isEmpty ? '-' : paymentType;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: gold),
          borderRadius: BorderRadius.circular(999),
          color: Colors.black,
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: gold,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Color(0xFFFFD700)),
        title: const Text(
          'Satış Geçmişim',
          style: TextStyle(
            color: Color(0xFFFFD700),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: baseQuery.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Hata (orders): ${snap.error}',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFD700)),
            );
          }

          final orders = snap.data!.docs;
          if (orders.isEmpty) {
            return const Center(
              child: Text(
                'Henüz satış yok.',
                style: TextStyle(color: Color(0xFFFFD700)),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: orders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final o = orders[i];
              final d = o.data();
              final total = (d['totalPrice'] as num?) ?? 0;
              final ts = d['createdAt'] as Timestamp?;
              final dt = ts?.toDate();
              final when = dt == null
                  ? '-'
                  : '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

              final paymentType = (d['paymentType'] as String?) ?? '';

              return Card(
                color: Colors.grey[900],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFFFD700), width: 1),
                ),
                elevation: 4,
                child: ExpansionTile(
                  collapsedIconColor: gold,
                  iconColor: gold,
                  title: Text(
                    'Sipariş #${o.id.substring(0, 6)} • ₺${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Color(0xFFFFD700),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Tarih: $when',
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                        ),
                        // Sağda ödeme tipi chip
                        paymentChip(paymentType),
                      ],
                    ),
                  ),
                  children: [
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: o.reference.collection('items').snapshots(),
                      builder: (ctx, itemsSnap) {
                        if (itemsSnap.hasError) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'Hata (items): ${itemsSnap.error}',
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          );
                        }
                        if (!itemsSnap.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: LinearProgressIndicator(
                              color: Color(0xFFFFD700),
                            ),
                          );
                        }
                        final items = itemsSnap.data!.docs;
                        if (items.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Kalem yok',
                              style: TextStyle(color: Color(0xFFFFD700)),
                            ),
                          );
                        }

                        return Column(
                          children: items.map((it) {
                            final m = it.data();
                            final name = (m['name'] ?? '-') as String;
                            final qty = (m['qty'] as num?) ?? 0;
                            final kg = (m['kg'] as num?) ?? 0;
                            final price = (m['price'] as num?) ?? 0;

                            final line = (m['kg'] != null)
                                ? '$kg kg • ₺${price.toStringAsFixed(2)}/kg'
                                : '$qty adet • ₺${price.toStringAsFixed(2)}';

                            return ListTile(
                              title: Text(
                                name,
                                style: const TextStyle(
                                  color: Color(0xFFFFD700),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                line,
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
