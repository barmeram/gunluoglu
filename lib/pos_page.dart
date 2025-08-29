import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gunluogluproje/sales_history_page.dart';
import 'package:gunluogluproje/users_page.dart';
// Stok azaltma helper
import 'package:gunluogluproje/baker_stock_page.dart';
import 'package:gunluogluproje/product_manage_page.dart';

class PosSalesPage extends StatefulWidget {
  const PosSalesPage({
    super.key,
    required this.userId,
    this.isAdmin = false,
  });

  final String userId;
  final bool isAdmin;

  @override
  State<PosSalesPage> createState() => _PosSalesPageState();
}

class _PosSalesPageState extends State<PosSalesPage> {
  final db = FirebaseFirestore.instance;

  // Sepet (pid -> data)
  final Map<String, Map<String, dynamic>> cart = {};

  // Son eklenenlerin sırası (en sona eklenen en yeni). Altta reverse:true ile solda görünür.
  final List<String> _cartOrder = [];

  // Alt sepet scroll (son ekleneni göstermek için)
  final ScrollController _cartScroll = ScrollController();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // ❌ Otomatik seed KAPANDI — fiyatları bozmasın diye
    // _seedProductsUpsert();
  }

  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  /// İsteğe bağlı seed (kapalı):
  Future<void> _seedProductsUpsert() async {
    final col = db.collection('products');
    final now = Timestamp.fromDate(DateTime.now());

    final List<Map<String, dynamic>> items = [
      {'id': 'sosyete', 'data': {'name': 'Sosyete', 'isWeighted': false, 'price': 10, 'createdAt': now}},
      {'id': 'simit', 'data': {'name': 'Simit', 'isWeighted': false, 'price': 15, 'createdAt': now}},
      {'id': 'acma', 'data': {'name': 'Açma', 'isWeighted': false, 'price': 15, 'createdAt': now}},
      {'id': 'Kasarlı', 'data': {'name': 'Kaşarlı', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'b_peynırlı', 'data': {'name': 'Beyaz Peynirli', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'ucgen', 'data': {'name': 'Üçgen', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'tereyaglı', 'data': {'name': 'Tereyağlı', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'patatesli', 'data': {'name': 'Patatesli', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'zeytinli', 'data': {'name': 'Zeytinli', 'isWeighted': false, 'price': 25, 'createdAt': now}},
      {'id': 'Kasarli_sucuklu_borek', 'data': {'name': 'Kaşarlı Sucuklu Börek', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Gul_borek', 'data': {'name': 'Gül Böreği', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'K_simit', 'data': {'name': 'K.Simit', 'isWeighted': false, 'pricePerKg': 25, 'createdAt': now}},
      {'id': 'Kasarli_borek', 'data': {'name': 'Kaşarlı Börek', 'isWeighted': false, 'pricePerKg': 30, 'createdAt': now}},
      {'id': 'Tepsi_borek', 'data': {'name': 'Tepsi Böreği', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Pizza', 'data': {'name': 'Pizza', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Sandviç', 'data': {'name': 'Sandviç', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Cikolatali', 'data': {'name': 'Çikolatalı', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Labneli', 'data': {'name': 'Labneli', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Acılı', 'data': {'name': 'Acılı', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Sosisli', 'data': {'name': 'Sosisli', 'isWeighted': false, 'price': 30, 'createdAt': now}},
      {'id': 'Tahinli', 'data': {'name': 'Tahinli', 'isWeighted': false, 'price': 30, 'createdAt': now}},
    ];

    for (final it in items) {
      final id = it['id'] as String;
      final ref = col.doc(id);
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set(it['data'] as Map<String, dynamic>, SetOptions(merge: false));
      }
    }
  }

  num _cartTotal() {
    num t = 0;
    for (final it in cart.values) {
      if (it['isWeighted'] == true) {
        t += (it['kg'] as num? ?? 0) * (it['pricePerKg'] as num? ?? 0);
      } else {
        t += (it['qty'] as num? ?? 0) * (it['price'] as num? ?? 0);
      }
    }
    return t;
  }

  void _bumpOrder(String id) {
    _cartOrder.remove(id);
    _cartOrder.add(id);
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_cartScroll.hasClients) {
        _cartScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addPiece(String id, String name, num price, {int count = 1}) {
    setState(() {
      final cur = cart[id];
      if (cur == null) {
        cart[id] = {'name': name, 'isWeighted': false, 'qty': count, 'price': price};
      } else {
        cart[id]!['qty'] = (cur['qty'] as int) + count;
      }
      _bumpOrder(id);
    });
    _scrollToLatest();
  }

  void _removeOne(String id) {
    final cur = cart[id];
    if (cur == null || cur['isWeighted'] == true) return;
    final q = cur['qty'] as int;
    setState(() {
      if (q <= 1) {
        cart.remove(id);
        _cartOrder.remove(id);
      } else {
        cart[id]!['qty'] = q - 1;
      }
    });
  }

  Future<void> _addWeighted(String id, String name, num pricePerKg) async {
    final c = TextEditingController();
    final kg = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        title: Text('$name — Kg gir', style: const TextStyle(color: Color(0xFFFFD700))),
        content: TextField(
          controller: c,
          style: const TextStyle(color: Colors.white),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'Örn: 0.35',
            hintStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(c.text.replaceAll(',', '.')) ?? 0.0;
              Navigator.pop(ctx, v);
            },
            child: const Text('Ekle', style: TextStyle(color: Color(0xFFFFD700))),
          ),
        ],
      ),
    );
    if (kg == null || kg <= 0) return;

    setState(() {
      final cur = cart[id];
      if (cur == null) {
        cart[id] = {'name': name, 'isWeighted': true, 'kg': kg, 'pricePerKg': pricePerKg};
      } else {
        cart[id]!['kg'] = (cur['kg'] as num) + kg;
      }
      _bumpOrder(id);
    });
    _scrollToLatest();
  }

  Future<void> _incrementRevenueSafely(num amount) async {
    final key = _todayKey();
    final revRef = db.collection('revenues').doc("${widget.userId}_$key");
    await db.runTransaction((tx) async {
      final snap = await tx.get(revRef);
      final current = (snap.data()?['total'] as num?) ?? 0;
      final newTotal = current + amount;
      tx.set(
        revRef,
        {
          'userId': widget.userId,
          'date': key,
          'total': newTotal,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  // ---- ÖDEME SEÇ + (Nakit için) VERİLEN TUTAR & PARA ÜSTÜ ----
  Future<Map<String, dynamic>?> _choosePaymentDialog(num total) async {
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String selected = 'Nakit'; // varsayılan
        final amountCtrl = TextEditingController();
        double paid = 0.0;

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            double delta = paid - total;
            final bool isCash = selected == 'Nakit';

            Widget bigMoneyText() {
              if (!isCash) return const SizedBox.shrink();
              final bool ok = delta >= 0;
              final label = ok ? 'Para Üstü' : 'Eksik';
              final value = (ok ? delta : -delta).toStringAsFixed(2);
              final color = ok ? const Color(0xFFFFD700) : Colors.redAccent;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      '$label:',
                      style: TextStyle(
                        color: color,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '₺$value',
                      style: TextStyle(
                        color: color,
                        fontSize: 30, // ✅ büyük yazı
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            }

            Widget cashInput() {
              if (!isCash) return const SizedBox.shrink();
              return Column(
                children: [
                  TextField(
                    controller: amountCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 20),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Verilen Tutar (₺)',
                      labelStyle: const TextStyle(color: Color(0xFFFFD700)),
                      hintText: 'Örn: 200',
                      hintStyle: const TextStyle(color: Colors.grey),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber.shade700),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.amber.shade400, width: 2),
                      ),
                    ),
                    onChanged: (s) {
                      final v = double.tryParse(s.replaceAll(',', '.')) ?? 0.0;
                      setLocal(() {
                        paid = v;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              );
            }

            Widget bigPayButton(String label, String type, String emoji) {
              final bool active = selected == type;
              return Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    setLocal(() => selected = type);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: active ? const Color(0xFFFFD700) : Colors.grey[800],
                    foregroundColor: active ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    '$emoji  $label',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: Colors.black,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ödeme', style: TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    'Toplam: ₺${total.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Büyük seçenek butonları
                    Row(
                      children: [
                        bigPayButton('Nakit', 'Nakit', '💵'),
                        const SizedBox(width: 8),
                        bigPayButton('Kart', 'Kart', '💳'),
                        const SizedBox(width: 8),
                        bigPayButton('Veresiye', 'Veresiye', '📒'),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Nakit için "Para Üstü" büyük yazı + verilen tutar girişi
                    bigMoneyText(),
                    cashInput(),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx), // iptal
                  child: const Text('İptal', style: TextStyle(color: Colors.redAccent, fontSize: 16)),
                ),
                ElevatedButton(
                  onPressed: () {
                    // Nakitse amount al, değilse 0 olarak dön
                    final result = <String, dynamic>{
                      'type': selected,
                      'paid': selected == 'Nakit' ? paid : null,
                      'change': selected == 'Nakit' ? max(0.0, paid - total) : null,
                    };
                    Navigator.pop(ctx, result);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD700),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Onayla', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// POS ürün adını üretim (production) adlarına dönüştür.
  String _mapToProductionName(String posName) {
    const aliases = <String, String>{
      // POS -> Production
      'Kaşarlı': 'Kaşarlı Börek',
      'Kaşarlı Börek': 'Kaşarlı Börek',
      'K.Simit': 'Küçük Poğaça',
    };
    return aliases[posName] ?? posName;
  }

  Future<void> _confirmOrder() async {
    if (_saving) return;
    if (cart.isEmpty) return;

    final total = _cartTotal();

    // ✅ Yeni: ödeme diyaloğu (büyük butonlar + nakitte para üstü hesap)
    final payment = await _choosePaymentDialog(total);
    if (payment == null) return;

    final String paymentType = payment['type'] as String;
    final num? paidAmount = payment['paid'] as num?;
    final num? change = payment['change'] as num?;

    setState(() => _saving = true);

    try {
      final orderRef = db.collection('orders').doc();
      await orderRef.set({
        'userId': widget.userId,
        'totalPrice': total,
        'paymentType': paymentType,
        if (paymentType == 'Nakit') 'paidAmount': paidAmount,
        if (paymentType == 'Nakit') 'change': change,
        'createdAt': FieldValue.serverTimestamp(),
      });

      final itemsBatch = db.batch();
      cart.forEach((pid, v) {
        final itemRef = orderRef.collection('items').doc();
        itemsBatch.set(itemRef, {
          'productId': pid,
          'name': v['name'],
          'qty': v['isWeighted'] == true ? null : v['qty'],
          'kg': v['isWeighted'] == true ? v['kg'] : null,
          'price': v['isWeighted'] == true ? v['pricePerKg'] : v['price'],
        });
      });
      await itemsBatch.commit();

      // Hasılat
      await _incrementRevenueSafely(total);

      // Satış sonrası stok düş (sadece adetli ürünler)
      final futures = <Future>[];
      cart.forEach((pid, v) {
        final isWeighted = v['isWeighted'] == true;
        if (!isWeighted) {
          final posName = (v['name'] as String?) ?? pid;
          final productionName = _mapToProductionName(posName);
          final qty = (v['qty'] as num?)?.toInt() ?? 0;
          if (qty > 0) {
            futures.add(decrementProductionUnitsByName(
              productName: productionName,
              minusUnits: qty,
            ));
          }
        }
      });

      try {
        await Future.wait(futures);
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Stok düşümü reddedildi (permission-denied).'),
              ),
            );
          }
        } else {
          rethrow;
        }
      }

      setState(() {
        cart.clear();
        _cartOrder.clear();
      });

      // ✅ Snackbar: Para üstü bilgisi (nakit ise)
      final extra = paymentType == 'Nakit' ? ' • Para Üstü: ₺${(change ?? 0).toStringAsFixed(2)}' : '';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Onaylandı ✅ $paymentType • ₺${total.toStringAsFixed(2)}$extra')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Stream<num> _todayRevenueStream() {
    final revRef = db.collection('revenues').doc("${widget.userId}_${_todayKey()}");
    return revRef.snapshots().map((doc) {
      if (!doc.exists) return 0;
      return (doc.data()?['total'] as num?) ?? 0;
    });
  }

  // --- Türkçe alfabetik sıralama ---
  String _lowerTr(String input) {
    var s = input
        .replaceAll('I', 'ı')
        .replaceAll('İ', 'i')
        .replaceAll('Ç', 'ç')
        .replaceAll('Ğ', 'ğ')
        .replaceAll('Ö', 'ö')
        .replaceAll('Ş', 'ş')
        .replaceAll('Ü', 'ü');
    return s.toLowerCase();
  }

  static const List<String> _trOrder = [
    'a','b','c','ç','d','e','f','g','ğ','h','ı','i','j','k','l','m','n','o','ö','p','r','s','ş','t','u','ü','v','y','z'
  ];

  int _trWeight(String ch) {
    final i = _trOrder.indexOf(ch);
    if (i >= 0) return i;
    return 1000 + ch.codeUnitAt(0);
  }

  int _trCompare(String a, String b) {
    final sa = _lowerTr(a);
    final sb = _lowerTr(b);
    final la = sa.length, lb = sb.length;
    final len = la < lb ? la : lb;
    for (int i = 0; i < len; i++) {
      final wa = _trWeight(sa[i]);
      final wb = _trWeight(sb[i]);
      if (wa != wb) return wa - wb;
    }
    return la - lb;
  }

  @override
  Widget build(BuildContext context) {
    // Firestore'dan alıp ekranda TR'ye göre sıralayacağız
    final productsQuery = db.collection('products');

    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text('Satış (POS)', style: TextStyle(color: gold)),
        actions: [
          if (widget.isAdmin)
            IconButton(
              icon: const Icon(Icons.group, color: gold),
              tooltip: "Kullanıcılar",
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UsersPage(
                      currentUid: widget.userId,
                      currentRole: "admin",
                    ),
                  ),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.history, color: gold),
            tooltip: "Satış Geçmişi",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SalesHistoryPage(userId: widget.userId),
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: StreamBuilder<num>(
            stream: _todayRevenueStream(),
            builder: (_, snap) {
              final v = (snap.data ?? 0).toStringAsFixed(2);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Bugünkü Hasılatım: ₺$v',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: gold,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      body: Column(
        children: [
          // ÜRÜN GRIDİ
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: productsQuery.snapshots(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return const Center(child: Text('Hata', style: TextStyle(color: Colors.red)));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }
                var docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(child: Text('Ürün yok', style: TextStyle(color: gold)));
                }

                // Ekranda Türkçe alfabeye göre sırala
                final sorted = [...docs]..sort((a, b) {
                  final na = (a.data()['name'] ?? '-') as String;
                  final nb = (b.data()['name'] ?? '-') as String;
                  return _trCompare(na, nb);
                });

                // 4 sütun sabit — her cihazda eşit boy, %25 genişlik
                return GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,      // her zaman 4 sütun
                    crossAxisSpacing: 0,    // %25'i korumak için boşluk yok
                    mainAxisSpacing: 0,     // %25'i korumak için boşluk yok
                    childAspectRatio: 1.0,  // kare kutu
                  ),
                  itemCount: sorted.length,
                  itemBuilder: (_, i) {
                    final p = sorted[i];
                    final d = p.data();
                    final name = (d['name'] ?? '-') as String;
                    final isWeighted = (d['isWeighted'] ?? false) as bool;
                    final price = isWeighted
                        ? (d['pricePerKg'] as num? ?? 0)
                        : (d['price'] as num? ?? 0);

                    final inCart = cart[p.id];
                    final badge = inCart == null
                        ? ''
                        : (inCart['isWeighted'] == true
                        ? '${(inCart['kg'] as num).toStringAsFixed(2)} kg'
                        : '${inCart['qty']} adet');

                    // --- Yalnızca "Sosyete" için hızlı ekleme rozetleri ---
                    final isSosyete = (!isWeighted) &&
                        (name.trim().toLowerCase() == 'sosyete' || p.id.trim().toLowerCase() == 'sosyete');

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Card(
                          margin: EdgeInsets.zero,
                          color: Colors.grey[900],
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Color(0xFFFFD700), width: 0.8),
                          ),
                          child: InkWell(
                            onTap: () {
                              if (isWeighted) {
                                _addWeighted(p.id, name, price);
                              } else {
                                _addPiece(p.id, name, price, count: 1);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    name,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFFFD700),
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isWeighted ? '₺$price / kg' : '₺$price',
                                    style: const TextStyle(
                                      color: Color(0xFFFFD700),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  if (badge.isNotEmpty)
                                    Text(
                                      'Sepette: $badge',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFFFFD700),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // --- Hızlı ekleme rozetleri: SADECE Sosyete ---
                        if (isSosyete)
                          Positioned(
                            top: 2,
                            left: 2,
                            child: GestureDetector(
                              onTap: () => _addPiece(p.id, name, price, count: 5),
                              child: _quickAdd('5x'),
                            ),
                          ),
                        if (isSosyete)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () => _addPiece(p.id, name, price, count: 10),
                              child: _quickAdd('10x'),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          // ALT SEPET BAR
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(top: BorderSide(color: Color(0xFFFFD700))),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (cart.isEmpty)
                  const Text('Sepet boş', style: TextStyle(color: Color(0xFFFFD700)))
                else ...[
                  SizedBox(
                    height: 74,
                    child: ListView(
                      controller: _cartScroll,
                      scrollDirection: Axis.horizontal,
                      reverse: true, // son eklenen solda
                      children: () {
                        final ids = <String>[
                          ..._cartOrder,
                          ...cart.keys.where((k) => !_cartOrder.contains(k)),
                        ];
                        return ids.map((id) {
                          final v = cart[id]!;
                          final label = v['isWeighted'] == true
                              ? '${v['name']} • ${(v['kg'] as num).toStringAsFixed(2)} kg'
                              : '${v['name']} • ${v['qty']} adet';
                          return GestureDetector(
                            onTap: () => _removeOne(id), // çubukta tıklayınca 1 azalt
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFFFFD700)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Text(
                                  label,
                                  style: const TextStyle(color: Color(0xFFFFD700), fontSize: 12),
                                ),
                              ),
                            ),
                          );
                        }).toList();
                      }(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Toplam: ₺${_cartTotal().toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFFD700),
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD700),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                        onPressed: _saving ? null : _confirmOrder,
                        icon: const Icon(Icons.check),
                        label: Text(_saving ? 'Kaydediliyor...' : 'Onayla'),
                      ),
                    ],
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Küçük 5x/10x rozetleri
  Widget _quickAdd(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.amber,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
