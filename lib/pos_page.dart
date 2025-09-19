// ========================
// FILE: pos_sales_page.dart
// ========================
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ✅ seçilen gün için
import 'package:gunluogluproje/sales_history_page.dart';
import 'package:gunluogluproje/users_page.dart';

// Stok azaltma helper (decrementProductionUnitsByName burada)
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

  // Seçilen gün key'i (AdminDailyPicker ile ortak)
  static const _prefsKeySelectedDay = 'admin_daily_picker_selected_day';

  // Sepet (pid -> data)
  final Map<String, Map<String, dynamic>> cart = {};

  // Son eklenenlerin sırası (reverse:true olduğu için solda görünür)
  final List<String> _cartOrder = [];

  // Alt sepet scroll (son ekleneni göstermek için)
  final ScrollController _cartScroll = ScrollController();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // ❌ Otomatik seed KAPALI
  }

  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  /// BakerStockPage’de seçilmiş gün varsa onu kullan; yoksa bugün.
  Future<String> _resolveStockDay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKeySelectedDay);
      if (saved != null && saved.trim().isNotEmpty) {
        return saved;
      }
    } catch (_) {
      // yoksay
    }
    return _todayKey();
  }

  // ------------------------- HESAPLAR -------------------------

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
    _cartOrder.add(id); // en yeni en sonda: reverse:true ile solda görünür
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_cartScroll.hasClients) return;
      // reverse:true olduğundan en yeni için minScrollExtent'e kaydır
      _cartScroll.animateTo(
        _cartScroll.position.minScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  // ------------------------- SEPET İŞLEMLERİ -------------------------

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

  // ------------------------- ÖDEME -------------------------

  Future<Map<String, dynamic>?> _choosePaymentDialog(num total) async {
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String selected = 'Nakit';
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
                    Text(label, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('₺$value', style: TextStyle(color: color, fontSize: 30, fontWeight: FontWeight.w800)),
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
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.amber.shade700)),
                      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFD700), width: 2)),
                    ),
                    onChanged: (s) {
                      final v = double.tryParse(s.replaceAll(',', '.')) ?? 0.0;
                      setLocal(() => paid = v);
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
                  onPressed: () => setLocal(() => selected = type),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: active ? const Color(0xFFFFD700) : Colors.grey[800],
                    foregroundColor: active ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('$emoji  $label', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
                  Text('Toplam: ₺${total.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70, fontSize: 16)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    bigMoneyText(),
                    cashInput(),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal', style: TextStyle(color: Colors.redAccent, fontSize: 16))),
                ElevatedButton(
                  onPressed: () {
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

  // POS adını üretime dönüştür (production_daily.productName ile eşleşmeli)
  String _mapToProductionName(String posName) {
    const aliases = <String, String>{
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

    final payment = await _choosePaymentDialog(total);
    if (payment == null) return;

    final String paymentType = payment['type'] as String;
    final num? paidAmount = payment['paid'] as num?;
    final num? change = payment['change'] as num?;

    setState(() => _saving = true);

    try {
      // 1) Siparişi kaydet
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

      // 2) Hasılatı güncelle
      await _incrementRevenueSafely(total);

      // 3) Seçilen günün stokunu düş
      final targetDay = await _resolveStockDay(); // ✅ BakerStock’taki gün
      final futures = <Future>[];
      cart.forEach((pid, v) {
        if (v['isWeighted'] == true) return; // kg ile satılanlar stok düşmüyor
        final posName = (v['name'] as String?) ?? pid;
        final productionName = _mapToProductionName(posName);
        final qty = (v['qty'] as num?)?.toInt() ?? 0;
        if (qty > 0) {
          futures.add(
            decrementProductionUnitsByName(
              productName: productionName,
              minusUnits: qty,
              day: targetDay, // ✅ kritik: seçili gün
            ),
          );
        }
      });
      try {
        await Future.wait(futures);
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Stok düşümü reddedildi (permission-denied).')),
          );
        } else {
          rethrow;
        }
      }

      // 4) Sepeti temizle
      setState(() {
        cart.clear();
        _cartOrder.clear();
      });

      final extra = paymentType == 'Nakit' ? ' • Para Üstü: ₺${(change ?? 0).toStringAsFixed(2)}' : '';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Onaylandı ✅ $paymentType • ₺${total.toStringAsFixed(2)} • Gün: $targetDay$extra')),
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

  // Kelimenin sadece ilk harfini büyüt (TR duyarlı), kalan harfler küçük kalır
  String _upperFirstTr(String word) {
    if (word.isEmpty) return word;
    final lower = _lowerTr(word);
    const up = {'i': 'İ', 'ı': 'I', 'ş': 'Ş', 'ğ': 'Ğ', 'ç': 'Ç', 'ö': 'Ö', 'ü': 'Ü'};
    final first = lower[0];
    final rest = lower.substring(1);
    final firstUp = up[first] ?? first.toUpperCase();
    return firstUp + rest;
  }

  // Title-case (her kelimenin sadece ilk harfi büyük)
  String _titleCaseTr(String input) {
    final parts = input.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    return parts.map(_upperFirstTr).join(' ');
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
              Navigator.push(context, MaterialPageRoute(builder: (_) => SalesHistoryPage(userId: widget.userId)));
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
                child: Text('Bugünkü Hasılatım: ₺$v', style: const TextStyle(fontWeight: FontWeight.w600, color: gold)),
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

                // Ekranda TR'ye göre sırala
                final sorted = [...docs]..sort((a, b) {
                  final na = (a.data()['name'] ?? '-') as String;
                  final nb = (b.data()['name'] ?? '-') as String;
                  return _trCompare(na, nb);
                });

                return GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 0,
                    mainAxisSpacing: 0,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: sorted.length,
                  itemBuilder: (_, i) {
                    final p = sorted[i];
                    final d = p.data();
                    final name = (d['name'] ?? '-') as String;
                    final isWeighted = (d['isWeighted'] ?? false) as bool;
                    final price = isWeighted ? (d['pricePerKg'] as num? ?? 0) : (d['price'] as num? ?? 0);

                    // --- Yalnızca "Sosyete" için hızlı ekleme rozetleri ---
                    final isSosyete = (!isWeighted) &&
                        (name.trim().toLowerCase() == 'sosyete' || p.id.trim().toLowerCase() == 'sosyete');

                    // Sadece ilk harfler büyük (TR title-case) + 1.5× büyük başlık
                    final displayName = _titleCaseTr(name);

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
                                    displayName,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFFFD700),
                                      fontSize: 20, // 12 → 18 (1.5×)
                                      height: 1.05,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    isWeighted ? '₺$price / kg' : '₺$price',
                                    style: const TextStyle(
                                      color: Color(0xFFFFD700),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
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

          // ALT SEPET BAR — yatay scroll, kutucuk içinde AD (üstte) ve ADET/KG (dipte)
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
                          final isWeighted = v['isWeighted'] == true;
                          return _cartChip(
                            id: id,
                            name: (v['name'] ?? '-') as String,
                            isWeighted: isWeighted,
                            qty: isWeighted ? null : (v['qty'] as num?),
                            kg: isWeighted ? (v['kg'] as num?) : null,
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
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFFFD700)),
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

  // 🔽 Sepet kutucuğu: minimum genişlikte, isim fade ile kesilsin (… yok), miktar clip
  // IntrinsicWidth + ConstrainedBox => içerik kadar dar, ama [56..120] aralığında.
  Widget _cartChip({
    required String id,
    required String name,
    required bool isWeighted,
    required num? qty,
    required num? kg,
  }) {
    final qtyText = isWeighted ? '${(kg ?? 0).toStringAsFixed(2)} kg' : '${(qty ?? 0)} adet';

    // Sadece ilk harfler büyük; sonra kelimeleri alt alta yaz
    final displayName = _titleCaseTr(name).split(RegExp(r'\s+')).join('\n');

    return GestureDetector(
      onTap: () {
        if (!isWeighted) _removeOne(id); // adetli üründe 1 azalt
      },
      child: SizedBox(
        height: double.infinity, // ListView item yüksekliğini doldur
        child: IntrinsicWidth( // << minimum gerekli genişlik
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 56,  // daha dar olmasın
              maxWidth: 120, // çok genişlemesin
            ),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFFFD700)),
                borderRadius: BorderRadius.circular(8),
                color: Colors.transparent,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // İsim alanı (baş harfler büyük) — ellipsis yerine fade
                  Expanded(
                    child: Text(
                      displayName,
                      textAlign: TextAlign.start,
                      softWrap: true,
                      maxLines: 3,
                      overflow: TextOverflow.fade, // <<< … yok
                      style: const TextStyle(
                        color: Color(0xFFFFD700),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.05,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Miktar dipte sabit — ellipsis yok, clip
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      qtyText,
                      maxLines: 1,
                      overflow: TextOverflow.clip, // <<< … yok
                      style: const TextStyle(
                        color: Color(0xFFFFD700),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Küçük 5x/10x rozetleri
  Widget _quickAdd(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: const TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}
