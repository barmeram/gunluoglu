import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CustomerOrdersOverviewPage extends StatefulWidget {
  const CustomerOrdersOverviewPage({super.key});

  @override
  State<CustomerOrdersOverviewPage> createState() => _CustomerOrdersOverviewPageState();
}

class _CustomerOrdersOverviewPageState extends State<CustomerOrdersOverviewPage> {
  static const gold = Color(0xFFFFD700);
  final db = FirebaseFirestore.instance;

  // basit ad cache’i
  final Map<String, Future<_UserMini>> _nameCache = {};

  Future<_UserMini> _resolveUserMini(String uid) {
    return _nameCache.putIfAbsent(uid, () async {
      try {
        final snap = await db.collection('users').doc(uid).get();
        final m = snap.data() ?? {};
        final name = (m['name'] ?? m['fullName'] ?? m['displayName'] ?? '').toString().trim();
        final email = (m['email'] ?? '').toString().trim();
        if (name.isNotEmpty) return _UserMini(name: name, email: email);
        if (email.isNotEmpty) return _UserMini(name: email.split('@').first, email: email);
      } catch (_) {}
      // düşüm yolu
      final short = uid.length <= 6 ? uid : '${uid.substring(0,2)}…${uid.substring(uid.length-4)}';
      return _UserMini(name: short, email: '');
    });
  }

  // YYYY-MM-DD
  String _dayKeyFrom(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}";

  Future<_Totals> _loadTotals(String uid) async {
    // Toplam sipariş adedi & toplam sipariş tutarı (customer_orders)
    int orderCount = 0;
    double orderSum = 0;
    try {
      final q = await db
          .collection('customer_orders')
          .where('userId', isEqualTo: uid) // ✅ doğru alan
          .get();
      orderCount = q.docs.length;
      for (final d in q.docs) {
        final data = d.data();
        // Önce totalPrice, yoksa satırlardan topla (fallback)
        final tp = (data['totalPrice'] as num?);
        if (tp != null) {
          orderSum += tp.toDouble();
        } else {
          final items = (data['items'] as List?) ?? const [];
          for (final it in items) {
            if (it is! Map) continue;
            final q = (it['qty'] as num?) ?? 0;
            final up = (it['unitPrice'] as num?) ?? 0;
            final lt = (it['lineTotal'] as num?) ?? (q * up);
            orderSum += lt.toDouble();
          }
        }
      }
    } catch (_) {}

    // Toplam alınan (lifetime tahsilat): adjustments/type=payment (negatif amount)
    double received = 0;
    try {
      final payQ = await db
          .collection('customer_credits')
          .doc(uid)
          .collection('adjustments')
          .where('type', isEqualTo: 'payment')
          .get();
      for (final d in payQ.docs) {
        final a = ((d.data()['amount'] as num?)?.toDouble() ?? 0);
        received += a < 0 ? -a : a; // negatif ise mutlak değeri ekle
      }
    } catch (_) {}

    return _Totals(orderCount: orderCount, orderSum: orderSum, totalReceived: received);
  }

  String _fmt(num v) => '₺${v.toStringAsFixed(2)}';

  Future<void> _collectPayment({
    required String userId,
    required String userName,
    double? currentBalance, // UI'dan bildiğimiz bakiye varsa gönderiyoruz
  }) async {
    // Ek güvenlik: bakiye 0 ise tahsilat yok (UI race condition'a karşı)
    try {
      final balSnap = await db.collection('customer_credits').doc(userId).get();
      final liveBal = (balSnap.data()?['balance'] as num?)?.toDouble() ?? 0.0;
      final effectiveBal = currentBalance ?? liveBal;
      if (effectiveBal <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Bu müşterinin veresiye bakiyesi yok")),
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bakiye okunamadı. Daha sonra yeniden deneyin.")),
      );
      return;
    }

    final amountC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: gold)),
        title: const Text('Veresiye Tahsilat', style: TextStyle(color: gold, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(userName, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            TextField(
              controller: amountC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Tahsil edilen tutar',
                labelStyle: TextStyle(color: Colors.white70),
                hintText: 'örn: 250',
                hintStyle: TextStyle(color: Colors.white38),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kaydet', style: TextStyle(color: gold)),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final val = double.tryParse(amountC.text.replaceAll(',', '.')) ?? 0;
    if (val <= 0) return;

    final todayKey = _dayKeyFrom(DateTime.now());
    final balRef = db.collection('customer_credits').doc(userId);
    await db.runTransaction((tx) async {
      final balSnap = await tx.get(balRef);
      final current = (balSnap.data()?['balance'] as num?)?.toDouble() ?? 0;
      final newBal = (current - val).clamp(0, 1e12).toDouble(); // eksiye düşmesin
      // ⚠️ Kurallar: sadece userId, customerName, balance, updatedAt
      tx.set(
        balRef,
        {
          'userId': userId,
          'customerName': userName,
          'balance': newBal,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      // ⚠️ Kurallar: adjustments create → amount,type,createdAt,date,paymentId ZORUNLU ve SADECE bunlar
      final adjRef = balRef.collection('adjustments').doc();
      tx.set(adjRef, {
        'amount': -val, // ödeme -> negatif
        'type': 'payment',
        'createdAt': FieldValue.serverTimestamp(),
        'date': todayKey,
        'paymentId': 'manual_${DateTime.now().millisecondsSinceEpoch}',
      });
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tahsil edildi: ${_fmt(val)}')));
  }

  Future<void> _toggleBlockUser({
    required String uid,
    required bool isActive,
    required String nameForDialog,
  }) async {
    final wantDisable = isActive; // aktifse tıklayınca engelle
    final title = wantDisable ? "Hesabı Engelle" : "Engeli Kaldır";
    final msg = wantDisable
        ? "$nameForDialog kullanıcısını engellemek istiyor musun? (Giriş yapamaz)"
        : "$nameForDialog kullanıcısının engelini kaldırmak istiyor musun?";

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: gold)),
        title: Text(title, style: const TextStyle(color: gold)),
        content: Text(msg, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("İptal")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Tamam", style: TextStyle(color: gold))),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await db.collection('users').doc(uid).update({
        'isActive': !wantDisable,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(wantDisable ? "Hesap engellendi" : "Engel kaldırıldı")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("İşlem başarısız: $e")),
        );
      }
    }
  }

  Future<void> _deleteUser({required String uid, required String nameForDialog}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: gold)),
        title: const Text("Kullanıcıyı Sil", style: TextStyle(color: gold)),
        content: Text("$nameForDialog kullanıcısını silmek istediğine emin misin?",
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("İptal")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Sil", style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await db.collection('users').doc(uid).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Kullanıcı silindi")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Silinirken hata: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mevcut mantığı koruyorum: liste customer_credits üstünden (veresiye dokümanı olanlar)
    final creditsStream = db.collection('customer_credits').snapshots();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Müşteri Özetleri', style: TextStyle(color: gold)),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: creditsStream,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(child: Text('Hata: ${snap.error}', style: const TextStyle(color: Colors.redAccent)));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: gold));
          }

          final balances = <String, double>{};
          final uidSet = <String>{};

          for (final doc in snap.data!.docs) {
            final m = doc.data();
            // UID: önce alan, yoksa doc.id
            String? uid = (m['userId'] as String?);
            uid ??= doc.id;
            if (uid.isEmpty) continue;

            final bal = (m['balance'] as num?)?.toDouble() ?? 0.0;
            balances[uid] = bal;
            uidSet.add(uid);
          }

          final uids = uidSet.toList()..sort();

          if (uids.isEmpty) {
            return const Center(child: Text('Veresiye kaydı olan müşteri yok', style: TextStyle(color: gold)));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: uids.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final uid = uids[i];
              final bal = balances[uid] ?? 0.0;

              return FutureBuilder<_UserMini>(
                future: _resolveUserMini(uid),
                builder: (_, nameSnap) {
                  final mini = nameSnap.data ?? _UserMini(name: uid, email: '');
                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: db.collection('users').doc(uid).snapshots(),
                    builder: (_, userSnap) {
                      final isActive = (userSnap.data?.data()?['isActive'] as bool?) ?? true;

                      return FutureBuilder<_Totals>(
                        future: _loadTotals(uid),
                        builder: (_, totalSnap) {
                          final totals = totalSnap.data ?? const _Totals();
                          return Card(
                            color: Colors.grey[900],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: gold),
                            ),
                            child: ListTile(
                              title: Text(
                                mini.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isActive ? gold : Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (mini.email.isNotEmpty)
                                    Text(
                                      mini.email,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white70),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Veresiye Bakiye: ${_fmt(bal)}',
                                    style: TextStyle(
                                      color: bal > 0 ? Colors.redAccent : Colors.white70,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Toplam Sipariş: ${totals.orderCount} adet — ${_fmt(totals.orderSum)}',
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  Text(
                                    'Toplam Alınan: ${_fmt(totals.totalReceived)}',
                                    style: const TextStyle(color: Colors.greenAccent),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (bal > 0)
                                    IconButton(
                                      tooltip: 'Veresiye Azalt',
                                      icon: const Icon(Icons.payments, color: gold),
                                      onPressed: () => _collectPayment(
                                        userId: uid,
                                        userName: mini.name,
                                        currentBalance: bal, // ✅ ek güvenlik
                                      ),
                                    ),
                                  PopupMenuButton<String>(
                                    tooltip: "İşlemler",
                                    color: Colors.grey[900],
                                    icon: const Icon(Icons.more_vert, color: Colors.white70),
                                    onSelected: (value) async {
                                      if (value == 'toggle') {
                                        await _toggleBlockUser(
                                          uid: uid,
                                          isActive: isActive,
                                          nameForDialog: mini.name.isEmpty ? (mini.email.isEmpty ? uid : mini.email) : mini.name,
                                        );
                                      } else if (value == 'delete') {
                                        await _deleteUser(
                                          uid: uid,
                                          nameForDialog: mini.name.isEmpty ? (mini.email.isEmpty ? uid : mini.email) : mini.name,
                                        );
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem<String>(
                                        value: 'toggle',
                                        child: Row(
                                          children: [
                                            Icon(isActive ? Icons.block : Icons.check_circle, color: Colors.white70, size: 18),
                                            const SizedBox(width: 8),
                                            const Text(
                                              "Hesabı Engelle / Engeli Kaldır",
                                              style: TextStyle(color: Colors.white),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem<String>(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(Icons.delete, color: Colors.redAccent, size: 18),
                                            SizedBox(width: 8),
                                            Text("Hesabı Sil", style: TextStyle(color: Colors.redAccent)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => CustomerCreditDetailPage(
                                      userId: uid,
                                      customerName: mini.name,
                                      email: mini.email,
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _UserMini {
  final String name;
  final String email;
  _UserMini({required this.name, required this.email});
}

class _Totals {
  final int orderCount;
  final double orderSum;
  final double totalReceived;
  const _Totals({this.orderCount = 0, this.orderSum = 0, this.totalReceived = 0});
}

/// ===============================
///   DETAY SAYFASI (Gün/Hafta/Ay/Yıl)
/// ===============================
class CustomerCreditDetailPage extends StatefulWidget {
  final String userId;
  final String customerName;
  final String email;

  const CustomerCreditDetailPage({
    super.key,
    required this.userId,
    required this.customerName,
    required this.email,
  });

  @override
  State<CustomerCreditDetailPage> createState() => _CustomerCreditDetailPageState();
}

class _CustomerCreditDetailPageState extends State<CustomerCreditDetailPage> {
  static const gold = Color(0xFFFFD700);
  final db = FirebaseFirestore.instance;

  int _period = 1; // 0:gün 1:hafta 2:ay 3:yıl

  String _fmt(num v) => '₺${v.toStringAsFixed(2)}';
  String _dayKeyFrom(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}";

  DateTime _periodStart(int p) {
    final now = DateTime.now();
    switch (p) {
      case 0: // gün
        return DateTime(now.year, now.month, now.day);
      case 1: // hafta (pazartesi)
        final wd = now.weekday; // 1=pazartesi
        final start = now.subtract(Duration(days: wd - 1));
        return DateTime(start.year, start.month, start.day);
      case 2: // ay
        return DateTime(now.year, now.month, 1);
      case 3: // yıl
        return DateTime(now.year, 1, 1);
    }
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _periodEnd(int p) {
    final s = _periodStart(p);
    switch (p) {
      case 0:
        return s.add(const Duration(days: 1));
      case 1:
        return s.add(const Duration(days: 7));
      case 2:
        return DateTime(s.year, s.month + 1, 1);
      case 3:
        return DateTime(s.year + 1, 1, 1);
    }
    return s.add(const Duration(days: 1));
  }

  Future<void> _collectPayment() async {
    // Ek güvenlik: son bakiyeyi oku, 0 ise engelle
    try {
      final balSnap = await db.collection('customer_credits').doc(widget.userId).get();
      final balNow = (balSnap.data()?['balance'] as num?)?.toDouble() ?? 0.0;
      if (balNow <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Veresiye bakiyesi yok")),
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bakiye okunamadı. Daha sonra yeniden deneyin.")),
      );
      return;
    }

    final amountC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: gold)),
        title: const Text('Veresiye Tahsilat', style: TextStyle(color: gold)),
        content: TextField(
          controller: amountC,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Tahsil edilen tutar',
            labelStyle: TextStyle(color: Colors.white70),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kaydet', style: TextStyle(color: gold))),
        ],
      ),
    );
    if (ok != true) return;

    final val = double.tryParse(amountC.text.replaceAll(',', '.')) ?? 0;
    if (val <= 0) return;

    final todayKey = _dayKeyFrom(DateTime.now());
    final balRef = db.collection('customer_credits').doc(widget.userId);
    await db.runTransaction((tx) async {
      final balSnap = await tx.get(balRef);
      final current = (balSnap.data()?['balance'] as num?)?.toDouble() ?? 0;
      final newBal = (current - val).clamp(0, 1e12).toDouble();
      // ⚠️ Kurallar: sadece userId, customerName, balance, updatedAt
      tx.set(
        balRef,
        {
          'userId': widget.userId,
          'customerName': widget.customerName,
          'balance': newBal,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      // ⚠️ Kurallar: adjustments create → amount,type,createdAt,date,paymentId ZORUNLU ve SADECE bunlar
      final adjRef = balRef.collection('adjustments').doc();
      tx.set(adjRef, {
        'amount': -val,
        'type': 'payment',
        'createdAt': FieldValue.serverTimestamp(),
        'date': todayKey,
        'paymentId': 'manual_${DateTime.now().millisecondsSinceEpoch}',
      });
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tahsil edildi: ${_fmt(val)}')));
  }

  double _dayCardWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final target = w * 0.86; // ekranın ~%86'sı
    if (target < 220) return w - 24; // çok dar ekranlar
    if (target > 360) return 360;    // çok geniş olmasın
    return target;
  }

  @override
  Widget build(BuildContext context) {
    final start = _periodStart(_period);
    final end = _periodEnd(_period);

    final balDocStream = db.collection('customer_credits').doc(widget.userId).snapshots();

    // Dönem siparişleri: müşteri bazlı
    final ordersQuery = db
        .collection('customer_orders')
        .where('userId', isEqualTo: widget.userId)
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .orderBy('createdAt', descending: true)
        .snapshots();

    // Dönem adjustments (tahsilat/borç yazım)
    final adjQuery = db
        .collection('customer_credits')
        .doc(widget.userId)
        .collection('adjustments')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .orderBy('createdAt', descending: true)
        .snapshots();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.customerName, style: const TextStyle(color: gold)),
        actions: [
          // ✅ Bakiye 0 ise pasif buton
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: balDocStream,
            builder: (_, snap) {
              final bal = (snap.data?.data()?['balance'] as num?)?.toDouble() ?? 0.0;
              return IconButton(
                tooltip: bal > 0 ? 'Veresiye Tahsilat' : 'Bakiye yok',
                icon: Icon(Icons.payments, color: bal > 0 ? gold : Colors.white24),
                onPressed: bal > 0 ? _collectPayment : null,
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Üst bilgi: bakiye
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: balDocStream,
            builder: (_, snap) {
              final bal = (snap.data?.data()?['balance'] as num?)?.toDouble() ?? 0;
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0x33FFD700))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.email.isNotEmpty)
                      Text(widget.email, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                    const SizedBox(height: 4),
                    Text(
                      'Mevcut Veresiye: ${_fmt(bal)}',
                      style: TextStyle(
                        color: bal > 0 ? Colors.redAccent : Colors.white70,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Dönem seçicisi
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                _chip(0, 'Gün'),
                _chip(1, 'Hafta'),
                _chip(2, 'Ay'),
                _chip(3, 'Yıl'),
              ],
            ),
          ),

          // Dönem sipariş özetleri + (Hafta/Ay: gün kırılımı) + adjustments listesi
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: ordersQuery,
              builder: (_, orderSnap) {
                if (orderSnap.hasError) {
                  return Center(child: Text('Sipariş hatası: ${orderSnap.error}', style: const TextStyle(color: Colors.redAccent)));
                }
                if (!orderSnap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }

                // ---- DÖNEM SİPARİŞ ÖZET HESAPLAMA ----
                double sumCash = 0, sumCard = 0, sumCredit = 0;

                final Map<String, _DayAgg> dayAgg = {}; // dayKey -> agg (yalnız tutarlar)

                for (final d in orderSnap.data!.docs) {
                  final m = d.data();
                  final ts = (m['createdAt'] as Timestamp?);
                  final dt = ts?.toDate() ?? DateTime.now();
                  final dayKey = _dayKeyFrom(DateTime(dt.year, dt.month, dt.day));
                  final pay = (m['paymentType'] ?? '').toString();
                  final total = ((m['totalPrice'] as num?) ?? 0).toDouble();

                  // global
                  if (pay == 'Nakit') {
                    sumCash += total;
                  } else if (pay == 'Kart') {
                    sumCard += total;
                  } else if (pay == 'Veresiye') {
                    sumCredit += total;
                  }

                  // daily (yalnızca tutar)
                  final a = dayAgg.putIfAbsent(dayKey, () => _DayAgg());
                  if (pay == 'Nakit') { a.sumCash += total; }
                  else if (pay == 'Kart') { a.sumCard += total; }
                  else if (pay == 'Veresiye') { a.sumCredit += total; }
                }

                final totalOrders = orderSnap.data!.docs.length;

                // ---- UI ----
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: adjQuery,
                  builder: (_, adjSnap) {
                    if (adjSnap.hasError) {
                      return Center(child: Text('Hareket hatası: ${adjSnap.error}', style: const TextStyle(color: Colors.redAccent)));
                    }
                    if (!adjSnap.hasData) {
                      return const Center(child: CircularProgressIndicator(color: gold));
                    }

                    double payments = 0;  // tahsilatlar (negatif amount → pozitif topla)
                    double charges = 0;   // borç yazım (pozitif amount)
                    for (final d in adjSnap.data!.docs) {
                      final a = (d.data()['amount'] as num?)?.toDouble() ?? 0;
                      if (a < 0) payments += -a;
                      if (a > 0) charges += a;
                    }

                    // Gün kırılımı listesi sıralama (yakın tarih başta)
                    final dayKeys = dayAgg.keys.toList()
                      ..sort((a, b) => b.compareTo(a)); // desc

                    return Column(
                      children: [
                        // ---- DÖNEM SİPARİŞ ÖZETİ (Sadece tutarlar) ----
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(child: _summaryBox(
                                    title: 'Nakit',
                                    value: _fmt(sumCash),
                                    color: Colors.greenAccent,
                                  )),
                                  const SizedBox(width: 8),
                                  Expanded(child: _summaryBox(
                                    title: 'Kart',
                                    value: _fmt(sumCard),
                                    color: Colors.blueAccent,
                                  )),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(child: _summaryBox(
                                    title: 'Veresiye',
                                    value: _fmt(sumCredit),
                                    color: Colors.orangeAccent,
                                  )),
                                  const SizedBox(width: 8),
                                  Expanded(child: _summaryBox(
                                    title: 'Tahsilat (Dönem)',
                                    value: _fmt(payments),
                                    color: Colors.tealAccent,
                                  )),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'Toplam Sipariş: $totalOrders adet',
                                  style: const TextStyle(color: Colors.white54),
                                ),
                              )
                            ],
                          ),
                        ),

                        // ---- (Hafta/Ay) Gün Gün Kırılım (Sadece tutarlar) ----
                        if (_period == 1 || _period == 2) ...[
                          const Divider(color: Colors.white24, height: 1),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                            child: Row(
                              children: const [
                                Text('Gün Gün Kırılım', style: TextStyle(color: gold, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                          if (dayKeys.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Bu dönemde sipariş yok', style: TextStyle(color: gold)),
                            )
                          else
                            SizedBox(
                              height: 170,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                scrollDirection: Axis.horizontal,
                                itemCount: dayKeys.length,
                                separatorBuilder: (_, __) => const SizedBox(width: 10),
                                itemBuilder: (_, i) {
                                  final k = dayKeys[i];
                                  final a = dayAgg[k]!;
                                  return _dayCard(context, k, a);
                                },
                              ),
                            ),
                        ],

                        const Divider(color: Colors.white24, height: 1),

                        // ---- HAREKETLER (adjustments) ----
                        Expanded(
                          child: adjSnap.data!.docs.isEmpty
                              ? const Center(child: Text('Bu dönemde hareket yok', style: TextStyle(color: gold)))
                              : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: adjSnap.data!.docs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final m = adjSnap.data!.docs[i].data();
                              final double amt = (m['amount'] as num?)?.toDouble() ?? 0;
                              final ts = (m['createdAt'] as Timestamp?);
                              final dt = ts?.toDate();
                              final type = (m['type'] ?? (amt < 0 ? 'payment' : 'charge')).toString();
                              final isPay = amt < 0 || type == 'payment';
                              return ListTile(
                                tileColor: Colors.grey[900],
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(color: isPay ? Colors.greenAccent : Colors.orangeAccent, width: .7),
                                ),
                                leading: Icon(isPay ? Icons.south_west : Icons.north_east,
                                    color: isPay ? Colors.greenAccent : Colors.orangeAccent),
                                title: Text(
                                  isPay ? 'Tahsilat' : 'Borç Yazım',
                                  style: const TextStyle(color: gold, fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  dt != null ? dt.toString() : '-',
                                  style: const TextStyle(color: Colors.white54),
                                ),
                                trailing: Text(
                                  _fmt(amt.abs()),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isPay ? Colors.greenAccent : Colors.orangeAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      // ✅ Bakiye 0 ise FAB gizleniyor
      floatingActionButton: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: balDocStream,
        builder: (_, snap) {
          final bal = (snap.data?.data()?['balance'] as num?)?.toDouble() ?? 0.0;
          if (bal <= 0) return const SizedBox.shrink();
          return FloatingActionButton.extended(
            backgroundColor: gold,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.payments),
            label: const Text('Veresiye Tahsil'),
            onPressed: _collectPayment,
          );
        },
      ),
    );
  }

  Widget _chip(int id, String label) {
    final selected = _period == id;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _period = id),
      backgroundColor: Colors.grey[850],
      selectedColor: gold.withOpacity(.15),
      labelStyle: TextStyle(color: selected ? gold : Colors.white70, fontWeight: FontWeight.w600),
      side: BorderSide(color: selected ? gold : const Color(0x33FFFFFF)),
    );
  }

  // Sadece tutar gösteren özet kutusu
  Widget _summaryBox({required String title, required String value, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(color: gold, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // Gün kartı (yalnızca tutarlar) — responsive genişlik
  Widget _dayCard(BuildContext context, String dayKey, _DayAgg a) {
    final w = _dayCardWidth(context);
    return Container(
      width: w,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dayKey, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _rowEntry('Nakit', a.sumCash, Colors.greenAccent),
          const SizedBox(height: 4),
          _rowEntry('Kart', a.sumCard, Colors.blueAccent),
          const SizedBox(height: 4),
          _rowEntry('Veresiye', a.sumCredit, Colors.orangeAccent),
          const SizedBox(height: 6),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 6),
          _rowEntry('Gün Toplamı', a.sumCash + a.sumCard + a.sumCredit, Colors.purpleAccent),
        ],
      ),
    );
  }


  // Esnek satır: küçük ekranlarda taşma yapmaz (yalnızca tutar)
  Widget _rowEntry(String title, double sum, Color color) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _fmt(sum),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

// Günlük agregasyon modeli (yalnızca tutarlar)
class _DayAgg {
  double sumCash = 0;
  double sumCard = 0;
  double sumCredit = 0;
}
