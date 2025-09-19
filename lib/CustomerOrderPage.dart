import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CustomerOrderPage extends StatefulWidget {
  const CustomerOrderPage({super.key, required this.userId});

  final String userId;

  @override
  State<CustomerOrderPage> createState() => _CustomerOrderPageState();
}

class _CustomerOrderPageState extends State<CustomerOrderPage> {
  final db = FirebaseFirestore.instance;

  static const gold = Color(0xFFFFD700);
  static const String kCustomerProducts = 'customer_products';

  /// Sepet: productId -> { name, qty, price }  // price = ALIŞ birim fiyatı
  final Map<String, Map<String, dynamic>> cart = {};
  bool _saving = false;

  // =========================
  // Helpers
  // =========================

  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  num _cartTotal() {
    num t = 0;
    for (final it in cart.values) {
      t += (it['qty'] as num? ?? 0) * (it['price'] as num? ?? 0); // ALIŞ fiyatıyla hesap
    }
    return t;
  }

  void _addOne(String id, String name, num buyPrice) {
    setState(() {
      final cur = cart[id];
      if (cur == null) {
        cart[id] = {'name': name, 'qty': 1, 'price': buyPrice};
      } else {
        cart[id]!['qty'] = (cur['qty'] as int) + 1;
      }
    });
  }

  void _removeOne(String id) {
    final cur = cart[id];
    if (cur == null) return;
    final q = cur['qty'] as int;
    setState(() {
      if (q <= 1) {
        cart.remove(id);
      } else {
        cart[id]!['qty'] = q - 1;
      }
    });
  }

  List<Map<String, dynamic>> _cartToItemsArray() {
    return cart.entries.map((e) {
      final v = e.value;
      return {
        'productId': e.key,
        'name': v['name'],
        'qty': v['qty'],
        'unitPrice': v['price'], // ALIŞ fiyatı
        'lineTotal': (v['qty'] as num) * (v['price'] as num),
      };
    }).toList();
  }

  /// Ad soyad çözümleme
  Future<String> _resolveCurrentUserName() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();
      final name = (data?['name'] ?? data?['fullName'] ?? data?['displayName']) as String?;
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } catch (_) {}
    final user = FirebaseAuth.instance.currentUser!;
    if ((user.displayName ?? '').trim().isNotEmpty) return user.displayName!.trim();
    if ((user.email ?? '').trim().isNotEmpty) return user.email!.split('@').first;
    final uid = user.uid;
    return uid.length <= 6 ? uid : '${uid.substring(0,2)}…${uid.substring(uid.length-4)}';
  }

  Future<void> _incrementCustomerRevenue(num amount) async {
    final key = _todayKey();
    final uid = FirebaseAuth.instance.currentUser!.uid; // rules için auth uid
    final revRef = db.collection('customer_revenues').doc("${uid}_$key");
    await db.runTransaction((tx) async {
      final snap = await tx.get(revRef);
      final current = (snap.data()?['total'] as num?) ?? 0;
      final newTotal = current + amount;
      tx.set(
        revRef,
        {
          'userId': uid,
          'date': key,
          'total': newTotal,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  Stream<num> _todayCustomerRevenueStream() {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final revRef = db.collection('customer_revenues').doc("${uid}_${_todayKey()}");
    return revRef.snapshots().map((doc) {
      if (!doc.exists) return 0;
      return (doc.data()?['total'] as num?) ?? 0;
    });
  }

  // =========================
  // Adet girme diyaloğu (orta sayıya tıklanınca)
  // =========================
  Future<void> _promptQuantity({
    required String id,
    required String name,
    required num unitBuyPrice,
    required int currentQty,
  }) async {
    final c = TextEditingController(text: currentQty > 0 ? '$currentQty' : '');
    final result = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: gold),
          ),
          title: const Text('Adet Gir', style: TextStyle(color: gold)),
          content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Adet',
              labelStyle: TextStyle(color: Colors.white70),
              hintText: 'Örn: 12',
              hintStyle: TextStyle(color: Colors.white38),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('İptal', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () {
                final v = int.tryParse(c.text.trim());
                // 0 veya boş → kaldır; negatif/null → yok say
                if (v == null || v < 0) {
                  Navigator.pop(ctx, null);
                } else {
                  Navigator.pop(ctx, v);
                }
              },
              child: const Text('Tamam', style: TextStyle(color: gold)),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (result == null) return;

    setState(() {
      if (result == 0) {
        cart.remove(id);
      } else {
        cart[id] = {'name': name, 'qty': result, 'price': unitBuyPrice};
      }
    });
  }

  // =========================
  // Siparişi Kaydet → customer_orders.add(...)
  // =========================

  Future<void> _confirmOrder() async {
    if (_saving) return;
    if (cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sepet boş')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final total = _cartTotal();
      final userName = await _resolveCurrentUserName();

      await FirebaseFirestore.instance.collection("customer_orders").add({
        "userId": FirebaseAuth.instance.currentUser!.uid,
        "userName": userName,
        "createdAt": FieldValue.serverTimestamp(),
        "totalPrice": total, // ALIŞ toplamı
        "status": "pending",
        "items": _cartToItemsArray(),
      });

      await _incrementCustomerRevenue(total);

      setState(() => cart.clear());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sipariş onaylandı ✅  Toplam: ₺${total.toStringAsFixed(2)}')),
        );
      }
    } on FirebaseException catch (e) {
      if (mounted) {
        final msg = e.code == 'permission-denied'
            ? 'İzin reddedildi. (Rolünüz "order" olmalı ve Firestore kuralları güncel olmalı)'
            : 'Hata: ${e.message ?? e.code}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // =========================
  // UI (Sadece customer_products'tan okur)
  // =========================

  @override
  Widget build(BuildContext context) {
    // Müşteri tarafı: SADECE customer_products (read-only)
    final productsQuery = db.collection(kCustomerProducts).orderBy('name');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Sipariş Ver (Müşteri)', style: TextStyle(color: gold)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: StreamBuilder<num>(
            stream: _todayCustomerRevenueStream(),
            builder: (_, snap) {
              final v = (snap.data ?? 0).toStringAsFixed(2);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Bugünkü Sipariş Toplamım (alış): ₺$v',
                  style: const TextStyle(
                    color: gold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      body: Column(
        children: [
          // ÜRÜNLER
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: productsQuery.snapshots(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Text('Hata: ${snap.error}',
                        style: const TextStyle(color: Colors.redAccent)),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }

                // Şimdilik sadece adetlik ürünler (isWeighted == false)
                final docs = snap.data!.docs
                    .where((d) => (d['isWeighted'] ?? false) == false)
                    .toList();

                if (docs.isEmpty) {
                  return const Center(
                    child: Text('Ürün yok', style: TextStyle(color: gold)),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  separatorBuilder: (_, __) =>
                  const Divider(color: Colors.white12, height: 1),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final p = docs[i];
                    final data = p.data();

                    final String name = (data['name'] as String?)?.trim().isNotEmpty == true
                        ? (data['name'] as String).trim()
                        : '-';

                    // Alış (adet) ve satış (bilgi amaçlı) fiyatları
                    final num buy = (data['price'] as num?) ?? 0;              // ALIŞ → hesaplamada kullanılan
                    final num? sale = (data['salePrice'] as num?);             // SATIŞ → bilgi amaçlı

                    // Alış yoksa sepete ekleme kapalı
                    if (buy <= 0) {
                      return ListTile(
                        title: Text(name, style: const TextStyle(color: gold)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Alış: tanımsız',
                                style: TextStyle(color: Colors.orangeAccent)),
                            Text(
                              sale != null && sale > 0
                                  ? 'Satış: ₺${sale.toStringAsFixed(2)}'
                                  : 'Satış: tanımsız',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      );
                    }

                    final inCart = cart[p.id];
                    final int qty = (inCart?['qty'] as int?) ?? 0;

                    return ListTile(
                      title: Text(name, style: const TextStyle(color: gold)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Alış (hesap): ₺${buy.toStringAsFixed(2)}',
                              style: const TextStyle(color: gold, fontWeight: FontWeight.w600)),
                          Text(
                            sale != null && sale > 0
                                ? 'Satış (bilgi): ₺${sale.toStringAsFixed(2)}'
                                : 'Satış (bilgi): tanımsız',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '1 azalt',
                            icon: const Icon(Icons.remove, color: Colors.redAccent),
                            onPressed: () => _removeOne(p.id),
                          ),
                          // Orta alan: tıklanınca adet gir (klavye aç)
                          InkWell(
                            onTap: () => _promptQuantity(
                              id: p.id,
                              name: name,
                              unitBuyPrice: buy,
                              currentQty: qty,
                            ),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 46,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                border: Border.all(color: gold),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                qty > 0 ? '$qty' : '0',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '1 artır',
                            icon: const Icon(Icons.add, color: Colors.greenAccent),
                            onPressed: () => _addOne(p.id, name, buy),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // SEPET & ONAY
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(top: BorderSide(color: gold)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (cart.isEmpty)
                  const Text('Sepet boş', style: TextStyle(color: gold))
                else ...[
                  SizedBox(
                    height: 78,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: cart.entries.map((e) {
                        final v = e.value;
                        final label = '${v['name']} • ${v['qty']} adet';
                        return Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: gold),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Text(label, style: const TextStyle(color: gold)),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Toplam (alış): ₺${_cartTotal().toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: gold,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: gold,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: _saving ? null : _confirmOrder,
                        icon: const Icon(Icons.check),
                        label: Text(_saving ? 'Kaydediliyor...' : 'Onayla'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
