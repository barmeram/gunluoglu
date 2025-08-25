import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UserRevenuePage extends StatelessWidget {
  const UserRevenuePage({
    super.key,
    required this.uid,
    required this.name,
    required this.email,
  });

  final String uid;
  final String name;
  final String email;

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final db = FirebaseFirestore.instance;

    // revenues stream
    final revenuesStream = db
        .collection('revenues')
        .where('userId', isEqualTo: uid)
        .snapshots();

    // orders stream (sıralamayı client-side yapacağız)
    final ordersStream = db
        .collection('orders')
        .where('userId', isEqualTo: uid)
        .snapshots();

    Widget revenueCards(AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snap) {
      if (snap.hasError) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Hata (revenues)', style: TextStyle(color: Colors.redAccent)),
        );
      }
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(color: gold)),
        );
      }

      final docs = snap.data!.docs;

      num totalAll = 0, totalToday = 0, totalWeek = 0, totalMonth = 0;
      final now = DateTime.now();
      final todayKey =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final weekStart = now.subtract(Duration(days: (now.weekday + 6) % 7)); // Pazartesi
      final monthStart = DateTime(now.year, now.month, 1);

      for (final d in docs) {
        final m = d.data();
        final amount = (m['total'] as num?) ?? 0;
        final dateStr = (m['date'] as String?) ?? '';
        if (amount == 0 || dateStr.isEmpty) continue;

        totalAll += amount;

        DateTime? date;
        try {
          date = DateTime.parse(dateStr); // YYYY-MM-DD
        } catch (_) {}

        if (dateStr == todayKey) totalToday += amount;
        if (date != null) {
          if (!date.isBefore(weekStart)) totalWeek += amount;
          if (!date.isBefore(monthStart)) totalMonth += amount;
        }
      }

      Widget card(String title, num value) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: gold),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 4),
              Text("₺${value.toStringAsFixed(2)}",
                  style: const TextStyle(color: gold, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              card("Bugün", totalToday),
              const SizedBox(width: 8),
              card("Hafta", totalWeek),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              card("Ay", totalMonth),
              const SizedBox(width: 8),
              card("Toplam", totalAll),
            ]),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: Text(
          '$name — Detay',
          style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(email, style: const TextStyle(color: Colors.white70)),
          ),
        ),
      ),
      body: Column(
        children: [
          // ⬇️ Yalnızca içerik kadar yer kaplayan üst bölüm (Expanded YOK)
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: revenuesStream,
            builder: (context, snap) => revenueCards(snap),
          ),

          const Divider(color: gold, height: 1),

          // ⬇️ Geri kalan tüm alanı alan sipariş listesi
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: ordersStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Hata (orders)', style: TextStyle(color: Colors.redAccent)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }

                final orders = snap.data!.docs.toList();

                // Client-side sıralama (createdAt varsa)
                orders.sort((a, b) {
                  final ta = a.data()['createdAt'];
                  final tb = b.data()['createdAt'];
                  if (ta is Timestamp && tb is Timestamp) {
                    return tb.toDate().compareTo(ta.toDate()); // yeni → eski
                  }
                  return b.id.compareTo(a.id);
                });

                if (orders.isEmpty) {
                  return const Center(
                    child: Text("Sipariş yok", style: TextStyle(color: Colors.white70)),
                  );
                }

                String fmtTs(Timestamp? ts) {
                  if (ts == null) return '-';
                  final d = ts.toDate();
                  final dd = d.day.toString().padLeft(2, '0');
                  final mm = d.month.toString().padLeft(2, '0');
                  final yyyy = d.year.toString();
                  final hh = d.hour.toString().padLeft(2, '0');
                  final min = d.minute.toString().padLeft(2, '0');
                  return "$dd.$mm.$yyyy $hh:$min";
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: orders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final o = orders[i];
                    final m = o.data();
                    final total = (m['totalPrice'] as num?) ?? 0;
                    final createdAt = m['createdAt'] as Timestamp?;

                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: gold),
                      ),
                      child: Theme(
                        // ExpansionTile ok rengi vs
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                          splashColor: Colors.white10,
                          hoverColor: Colors.white10,
                        ),
                        child: ExpansionTile(
                          collapsedIconColor: gold,
                          iconColor: gold,
                          title: Text(
                            "Sipariş #${o.id.substring(0, 6)} • ₺${total.toStringAsFixed(2)}",
                            style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            fmtTs(createdAt),
                            style: const TextStyle(color: Colors.white70),
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: [
                            // 🔽 Items alt koleksiyonu
                            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                              stream: o.reference.collection('items').snapshots(),
                              builder: (ctx, itemsSnap) {
                                if (itemsSnap.hasError) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('Hata (items)', style: TextStyle(color: Colors.redAccent)),
                                  );
                                }
                                if (!itemsSnap.hasData) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: LinearProgressIndicator(color: gold),
                                  );
                                }
                                final items = itemsSnap.data!.docs;
                                if (items.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('Kalem yok', style: TextStyle(color: Colors.white70)),
                                  );
                                }

                                return Column(
                                  children: items.map((it) {
                                    final im = it.data();
                                    final name = (im['name'] ?? '-') as String;
                                    final qty = (im['qty'] as num?);
                                    final kg = (im['kg'] as num?);
                                    final price = (im['price'] as num?) ?? 0;

                                    String line;
                                    if (kg != null) {
                                      line = '${kg.toStringAsFixed(2)} kg • ₺${price.toStringAsFixed(2)}/kg';
                                    } else {
                                      final q = (qty ?? 0).toInt();
                                      line = '$q adet • ₺${price.toStringAsFixed(2)}';
                                    }

                                    return ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                                      title: Text(name, style: const TextStyle(color: Colors.white)),
                                      subtitle: Text(line, style: const TextStyle(color: Colors.white70)),
                                    );
                                  }).toList(),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
