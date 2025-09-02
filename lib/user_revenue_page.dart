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

    // NOTE: where(userId) + orderBy(createdAt) için kompozit index gerekebilir.
    final ordersStream = db
        .collection('orders')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots();

    DateTime _mondayOfWeek(DateTime x) {
      final wd = x.weekday; // 1..7 (1 = Pazartesi)
      final today00 = DateTime(x.year, x.month, x.day);
      return today00.subtract(Duration(days: wd - 1));
    }

    // ---- Responsive yardımcıları ----
    EdgeInsets _pagePadding(BoxConstraints c) {
      final w = c.maxWidth;
      return EdgeInsets.symmetric(horizontal: w < 360 ? 8 : 12);
    }

    EdgeInsets _pagePaddingForWidth(double w) {
      return EdgeInsets.symmetric(horizontal: w < 360 ? 8 : 12);
    }

    double _gap(BoxConstraints c) => c.maxWidth < 360 ? 6 : 8;
    double _gapForWidth(double w) => w < 360 ? 6 : 8;

    int _columnCount(double maxWidth) {
      if (maxWidth >= 900) return 3;
      if (maxWidth >= 560) return 2;
      return 1;
    }

    double _cardWidth(double maxWidth, double gap) {
      final cols = _columnCount(maxWidth);
      final totalGap = gap * (cols - 1);
      return (maxWidth - totalGap) / cols;
    }

    // ---------- TOPLAM KARTLARI ----------
    Widget revenueCardsFromOrders(
        BuildContext context,
        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snap,
        ) {
      if (snap.hasError) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Hata (orders → revenues)', style: TextStyle(color: Colors.redAccent)),
        );
      }
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(color: gold)),
        );
      }

      final docs = snap.data!.docs;

      num totalAll = 0, totalToday = 0, totalWeek = 0, totalMonth = 0, totalYear = 0;
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      final weekStart = _mondayOfWeek(now);
      final monthStart = DateTime(now.year, now.month, 1);
      final yearStart = DateTime(now.year, 1, 1);

      for (final d in docs) {
        final m = d.data();
        final total = (m['totalPrice'] as num?) ?? 0;
        final ts = m['createdAt'] as Timestamp?;
        if (total <= 0 || ts == null) continue;

        final dt = ts.toDate();
        final dateOnly = DateTime(dt.year, dt.month, dt.day);

        totalAll += total;
        if (!dateOnly.isBefore(dayStart)) totalToday += total;
        if (!dateOnly.isBefore(weekStart)) totalWeek += total;
        if (!dateOnly.isBefore(monthStart)) totalMonth += total;
        if (!dateOnly.isBefore(yearStart)) totalYear += total;
      }

      Widget statCard(String title, num value, {double? width}) {
        return SizedBox(
          width: width,
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
                Text(
                  "₺${value.toStringAsFixed(2)}",
                  style: const TextStyle(color: gold, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        );
      }

      return LayoutBuilder(
        builder: (context, c) {
          final pad = _pagePadding(c);
          final gap = _gap(c);
          final cw = _cardWidth(c.maxWidth - pad.horizontal, gap);

          return Padding(
            padding: EdgeInsets.fromLTRB(pad.left, 12, pad.right, 8),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                statCard("Bugün", totalToday, width: cw),
                statCard("Hafta", totalWeek, width: cw),
                statCard("Ay", totalMonth, width: cw),
                statCard("Yıl", totalYear, width: cw),
                statCard("Toplam", totalAll, width: cw),
              ],
            ),
          );
        },
      );
    }

    // ---------- ÖDEME TÜRÜ KIRILIMI ----------
    Widget paymentBreakdowns(
        BuildContext context,
        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snap,
        ) {
      if (snap.hasError) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Hata (orders breakdown)', style: TextStyle(color: Colors.redAccent)),
        );
      }
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: LinearProgressIndicator(color: gold),
        );
      }

      final orders = snap.data!.docs;

      Map<String, num> z() => {'Nakit': 0, 'Kart': 0, 'Veresiye': 0};
      void bump(Map<String, num> m, String type, num val) {
        final key = (type == 'Nakit' || type == 'Kart' || type == 'Veresiye') ? type : 'Nakit';
        m[key] = (m[key] ?? 0) + val;
      }

      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      final weekStart = _mondayOfWeek(now);
      final monthStart = DateTime(now.year, now.month, 1);
      final yearStart = DateTime(now.year, 1, 1);

      final byDay = z();
      final byWeek = z();
      final byMonth = z();
      final byYear = z();

      for (final o in orders) {
        final m = o.data();
        final total = (m['totalPrice'] as num?) ?? 0;
        final pType = (m['paymentType'] as String?) ?? 'Nakit';
        final created = m['createdAt'] as Timestamp?;

        if (total <= 0 || created == null) continue;

        final d = created.toDate();
        final dOnly = DateTime(d.year, d.month, d.day);

        if (!dOnly.isBefore(dayStart)) bump(byDay, pType, total);
        if (!dOnly.isBefore(weekStart)) bump(byWeek, pType, total);
        if (!dOnly.isBefore(monthStart)) bump(byMonth, pType, total);
        if (!dOnly.isBefore(yearStart)) bump(byYear, pType, total);
      }

      Widget amount(num v) => Text(
        "₺${v.toStringAsFixed(2)}",
        style: const TextStyle(color: gold, fontWeight: FontWeight.w700, fontSize: 14),
      );

      Widget line(String label, num v) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          amount(v),
        ],
      );

      Widget bCard(String title, Map<String, num> map, {double? width}) => SizedBox(
        width: width,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: gold),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              line('Nakit', map['Nakit'] ?? 0),
              const SizedBox(height: 4),
              line('Kart', map['Kart'] ?? 0),
              const SizedBox(height: 4),
              line('Veresiye', map['Veresiye'] ?? 0),
            ],
          ),
        ),
      );

      return LayoutBuilder(
        builder: (context, c) {
          final pad = _pagePadding(c);
          final gap = _gap(c);
          final cw = _cardWidth(c.maxWidth - pad.horizontal, gap);

          return Padding(
            padding: EdgeInsets.fromLTRB(pad.left, 0, pad.right, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: c.maxWidth < 360 ? 4 : 6),
                    child: const Text(
                      'Ödeme Türü Kırılımları',
                      style: TextStyle(
                        color: gold,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    bCard('Bugün', byDay, width: cw),
                    bCard('Hafta', byWeek, width: cw),
                    bCard('Ay', byMonth, width: cw),
                    bCard('Yıl', byYear, width: cw),
                  ],
                ),
              ],
            ),
          );
        },
      );
    }

    // ---------- SİPARİŞ LİSTESİ (Sliver) ----------
    Widget ordersSliver(
        BuildContext context,
        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snap,
        ) {
      if (snap.hasError) {
        return const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Hata (orders)', style: TextStyle(color: Colors.redAccent)),
          ),
        );
      }
      if (!snap.hasData) {
        return const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(color: gold)),
          ),
        );
      }

      final orders = snap.data!.docs; // Zaten orderBy ile geldi
      final w = MediaQuery.of(context).size.width;
      final pad = _pagePaddingForWidth(w);
      final gap = _gapForWidth(w);

      if (orders.isEmpty) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad.left, 12, pad.right, 12),
            child: const Center(
              child: Text("Sipariş yok", style: TextStyle(color: Colors.white70)),
            ),
          ),
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

      return SliverPadding(
        padding: EdgeInsets.fromLTRB(pad.left, 12, pad.right, 12),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
                (context, i) {
              final o = orders[i];
              final m = o.data();
              final total = (m['totalPrice'] as num?) ?? 0;
              final createdAt = m['createdAt'] as Timestamp?;
              final pType = (m['paymentType'] as String?) ?? '-';
              final paid = (m['paidAmount'] as num?);
              final change = (m['change'] as num?);

              return Container(
                margin: EdgeInsets.only(bottom: gap),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: gold),
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                    splashColor: Colors.white10,
                    hoverColor: Colors.white10,
                  ),
                  child: ExpansionTile(
                    collapsedIconColor: gold,
                    iconColor: gold,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    title: Text(
                      "Sipariş #${o.id.substring(0, 6)} • ₺${total.toStringAsFixed(2)}",
                      style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      "${fmtTs(createdAt)}  •  $pType"
                          "${pType == 'Nakit' && (paid != null || change != null) ? "  (Verilen: ₺${(paid ?? 0).toStringAsFixed(2)}, Üstü: ₺${(change ?? 0).toStringAsFixed(2)})" : ""}",
                      style: const TextStyle(color: Colors.white70),
                    ),
                    children: [
                      // items alt koleksiyonu
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
            childCount: orders.length,
          ),
        ),
      );
    }

    // --- Metin ölçeklemesini kontrol et (aşırı büyük erişilebilirlik fontlarında taşmayı engelle) ---
    final clampedTextScaler = MediaQuery.of(context).textScaler.clamp(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.2,
    );

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: clampedTextScaler),
      child: Scaffold(
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
        body: CustomScrollView(
          slivers: [
            // ⬆️ TOP Özet: ORDERS
            SliverToBoxAdapter(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: ordersStream,
                builder: (context, snap) => revenueCardsFromOrders(context, snap),
              ),
            ),

            // ⬆️ Ödeme Türü Kırılımları: ORDERS
            SliverToBoxAdapter(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: ordersStream,
                builder: (context, snap) => paymentBreakdowns(context, snap),
              ),
            ),

            const SliverToBoxAdapter(child: Divider(color: gold, height: 1)),

            // ⬇️ Sipariş listesi (SliverList)
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: ordersStream,
              builder: (context, snap) => ordersSliver(context, snap),
            ),
          ],
        ),
      ),
    );
  }
}
