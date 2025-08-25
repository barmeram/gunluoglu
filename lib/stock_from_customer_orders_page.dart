// stock_from_customer_orders_page.dart
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// 🔹 Stok azaltma helper'ını kullanmak için eklendi
import 'package:gunluogluproje/baker_stock_page.dart';
import 'package:gunluogluproje/production_recycle_page.dart';

class StockFromCustomerOrdersPage extends StatefulWidget {
  const StockFromCustomerOrdersPage({
    super.key,
    required this.userId,
    this.showAll = false,
  });

  final String userId; // showAll=false iken kendi siparişleri için kullanılır
  final bool showAll;

  @override
  State<StockFromCustomerOrdersPage> createState() => _StockFromCustomerOrdersPageState();
}

class _StockFromCustomerOrdersPageState extends State<StockFromCustomerOrdersPage> {
  final db = FirebaseFirestore.instance;

  DateTime _selectedDay = DateTime.now();
  String? _selectedUserId; // showAll=true iken seçili kullanıcı (null = hepsi)

  /// Solda görünen HEDEF teslim sayısı: productId -> count
  /// Varsayılan: o günün SİPARİŞ adedi
  final Map<String, int> _target = {};

  /// Son “Stoğu Onayla”da gerçekten yazılan **pozitif** delta (ödemede kullanılır)
  Map<String, int>? _lastDeltaPos;

  bool _applying = false;

  DateTime get _dayStart => DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
  DateTime get _dayEnd => _dayStart.add(const Duration(days: 1));
  String get _dayKey =>
      "${_dayStart.year}-${_dayStart.month.toString().padLeft(2, '0')}-${_dayStart.day.toString().padLeft(2, '0')}";

  String? get _targetUserId => widget.showAll ? _selectedUserId : widget.userId;

  String _shortUid(String uid) {
    if (uid.length <= 6) return uid;
    return '${uid.substring(0, 2)}…${uid.substring(uid.length - 4)}';
  }

  String _cur(num v) => '₺${v.toStringAsFixed(2)}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: DateTime(2023, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFFFD700),
              surface: Colors.black,
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: Colors.black,
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _selectedDay = picked;
        _target.clear();
        _lastDeltaPos = null;
      });
    }
  }

  // ---------------------------
  // Queries
  // ---------------------------

  Query<Map<String, dynamic>> _ordersQ({bool filtered = true}) {
    var q = db
        .collection('customer_orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(_dayStart))
        .where('createdAt', isLessThan: Timestamp.fromDate(_dayEnd));
    if (filtered) {
      if (widget.showAll) {
        if (_selectedUserId != null) q = q.where('userId', isEqualTo: _selectedUserId);
      } else {
        q = q.where('userId', isEqualTo: widget.userId);
      }
    }
    return q.orderBy('createdAt', descending: true);
  }

  Query<Map<String, dynamic>> _ordersQUnfiltered() => _ordersQ(filtered: false);

  Query<Map<String, dynamic>> _deliveriesQ() {
    var q = db.collection('customer_deliveries').where('date', isEqualTo: _dayKey);
    if (widget.showAll) {
      if (_selectedUserId != null) q = q.where('userId', isEqualTo: _selectedUserId);
    } else {
      q = q.where('userId', isEqualTo: widget.userId);
    }
    return q;
  }

  Query<Map<String, dynamic>> _paymentsQ() {
    var q = db.collection('customer_payment_summaries').where('date', isEqualTo: _dayKey);
    if (widget.showAll) {
      if (_selectedUserId != null) q = q.where('userId', isEqualTo: _selectedUserId);
    } else {
      q = q.where('userId', isEqualTo: widget.userId);
    }
    return q;
  }

  // ---------------------------
  // Aggregations
  // ---------------------------

  /// Ürün bazında SIPARIŞ toplamı: pid -> {qty, amount}
  Stream<Map<String, Map<String, num>>> orderAggStream() async* {
    await for (final snap in _ordersQ().snapshots()) {
      final m = <String, Map<String, num>>{};
      for (final d in snap.docs) {
        final items = (d.data()['items'] as List?) ?? const [];
        for (final it in items) {
          if (it is! Map) continue;
          final pid = (it['productId'] as String?) ?? '';
          if (pid.isEmpty) continue;
          final q = (it['qty'] as num?) ?? 0;
          final up = (it['unitPrice'] as num?) ?? 0;
          final lt = (it['lineTotal'] as num?) ?? (up * q);
          final cur = m[pid] ?? {'qty': 0, 'amount': 0};
          m[pid] = {
            'qty': (cur['qty'] ?? 0) + q,
            'amount': (cur['amount'] ?? 0) + lt,
          };
        }
      }
      yield m;
    }
  }

  /// Ürün bazında bugüne kadar YAZILMIŞ teslim toplamı: pid -> qty
  Stream<Map<String, int>> deliveryQtyStream() async* {
    await for (final snap in _deliveriesQ().snapshots()) {
      final m = <String, int>{};
      for (final d in snap.docs) {
        final data = d.data();
        final pid = (data['productId'] as String?) ?? '';
        if (pid.isEmpty) continue;
        final q = ((data['qty'] as num?) ?? 0).toInt(); // negatif düzeltme olabilir
        m[pid] = (m[pid] ?? 0) + q;
      }
      yield m;
    }
  }

  /// Teslimlerden günlük hasılat (lineTotal toplamı; negatif düzeltmeler düşer)
  Stream<num> deliveryRevenueStream() async* {
    await for (final snap in _deliveriesQ().snapshots()) {
      num sum = 0;
      for (final d in snap.docs) {
        final data = d.data();
        final q = (data['qty'] as num?) ?? 0;
        final up = (data['unitPrice'] as num?) ?? 0;
        final lt = (data['lineTotal'] as num?) ?? (q * up);
        sum += lt;
      }
      yield sum;
    }
  }

  /// Günlük tahsilat (nakit/veresiye/total) — ödemelerden
  Stream<Map<String, num>> paymentAggStream() async* {
    await for (final snap in _paymentsQ().snapshots()) {
      num cash = 0, credit = 0, total = 0;
      for (final d in snap.docs) {
        final data = d.data();
        cash += (data['cash'] as num?) ?? 0;
        credit += (data['credit'] as num?) ?? 0;
        total += (data['total'] as num?) ?? 0;
      }
      yield {'cash': cash, 'credit': credit, 'total': total};
    }
  }

  /// Apply için yardımcı veriler (unit, isim vs)
  Future<Map<String, dynamic>> _fetchOrderMapsForApply(String targetUid) async {
    final oq = db
        .collection('customer_orders')
        .where('userId', isEqualTo: targetUid)
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(_dayStart))
        .where('createdAt', isLessThan: Timestamp.fromDate(_dayEnd));
    final oSnap = await oq.get();

    final orderQty = <String, int>{}; // pid -> qty
    final orderAmt = <String, num>{}; // pid -> amount
    final names = <String, String>{}; // pid -> last name

    for (final d in oSnap.docs) {
      for (final it in (d.data()['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final pid = (it['productId'] as String?) ?? '';
        if (pid.isEmpty) continue;
        final name = (it['name'] as String?) ?? pid;
        final q = ((it['qty'] as num?) ?? 0).toInt();
        final up = (it['unitPrice'] as num?) ?? 0;
        final lt = (it['lineTotal'] as num?) ?? (up * q);
        names[pid] = name;
        orderQty[pid] = (orderQty[pid] ?? 0) + q;
        orderAmt[pid] = (orderAmt[pid] ?? 0) + lt;
      }
    }

    final dq = db
        .collection('customer_deliveries')
        .where('userId', isEqualTo: targetUid)
        .where('date', isEqualTo: _dayKey);
    final dSnap = await dq.get();
    final delivered = <String, int>{};
    for (final d in dSnap.docs) {
      final data = d.data();
      final pid = (data['productId'] as String?) ?? '';
      if (pid.isEmpty) continue;
      final q = ((data['qty'] as num?) ?? 0).toInt();
      delivered[pid] = (delivered[pid] ?? 0) + q;
    }

    return {'orderQty': orderQty, 'orderAmt': orderAmt, 'names': names, 'delivered': delivered};
  }

  // ---------------------------
  // Production name eşleştirme
  // ---------------------------

  /// Sipariş/ürün adını production.productName ile eşleştir.
  /// Gerekirse genişlet: soldaki POS/sipariş adı -> sağdaki production adı
  String _mapToProductionName(String orderName) {
    const aliases = <String, String>{
      // POS/Order -> Production
      'Kaşarlı': 'Kaşarlı Poğaça',
      'Üçgen': 'Üçgen Peynir',
      'Tereyağlı': 'Tereyağlı Simit',
      'Simit': 'Beyaz Simit',
      'Sosisli': 'Sosisli Poğaça',
      'Zeytinli': 'Zeytinli Poğaça',
      'Patatesli': 'Patatesli Poğaça',
      'Çikolatalı': 'Çikolatalı',
      'Labneli': 'Labneli',
      'Tahinli': 'Tahinli',
      'Sandviç': 'Sandviç',
      'Acılı': 'Salçalı Poğaça',
      'K.Simit': 'Küçük Poğaça',
      // zaten aynı olanlar için yazmaya gerek yok
    };
    return aliases[orderName] ?? orderName;
  }

  // ---------------------------
  // Apply
  // ---------------------------

  /// Stoğu Onayla: HEDEF − MevcutTeslim delta’sını (negatif/pozitif) yazar.
  /// Pozitif delta `_lastDeltaPos`’a kaydedilir (ödemede kullanılır).
  Future<void> _applyDeliveriesOnly() async {
    if (_applying) return;

    final targetUid = _targetUserId;
    if (targetUid == null || targetUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Önce kullanıcı seçin')));
      return;
    }

    setState(() => _applying = true);
    try {
      final maps = await _fetchOrderMapsForApply(targetUid);
      final orderQty = (maps['orderQty'] as Map<String, int>);
      final orderAmt = (maps['orderAmt'] as Map<String, num>);
      final names = (maps['names'] as Map<String, String>);
      final delivered = (maps['delivered'] as Map<String, int>);

      final pids = orderQty.keys.toList(); // Sadece sipariş edilmiş ürünler
      final batch = db.batch();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      int i = 0;
      num amountAbs = 0;
      int countAbs = 0;

      final appliedPositives = <String, int>{};

      for (final pid in pids) {
        final ordQ = orderQty[pid] ?? 0;
        final targetCount = _target[pid] ?? ordQ;
        final cur = delivered[pid] ?? 0;
        final delta = targetCount - cur;
        if (delta == 0) continue;

        final safeDelta = max(-cur, delta); // final < 0 olmasın
        if (safeDelta == 0) continue;

        final unit = ordQ > 0 ? (orderAmt[pid] ?? 0) / ordQ : 0;
        final name = names[pid] ?? pid;
        final line = unit * safeDelta;

        final docId = "${targetUid}_${_dayKey}_${pid}_${nowMs}_${i++}";
        batch.set(db.collection('customer_deliveries').doc(docId), {
          'userId': targetUid,
          'date': _dayKey,
          'productId': pid,
          'name': name,
          'qty': safeDelta,
          'unitPrice': unit,
          'lineTotal': line,
          'createdBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
          'createdAt': FieldValue.serverTimestamp(),
        });

        if (safeDelta > 0) appliedPositives[pid] = safeDelta;

        amountAbs += line.abs();
        countAbs += safeDelta.abs();

        // Ekranı güncel teslimle eşitle
        _target[pid] = max(0, cur + safeDelta);
      }

      if (i == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Değişiklik yok')));
      } else {
        await batch.commit();
        setState(() {
          _lastDeltaPos = appliedPositives.isEmpty ? null : appliedPositives;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stok güncellendi • Değişen adet: $countAbs • ~${_cur(amountAbs)}')),
        );
        // Aynı sayfada kalıyoruz.
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// Ödemeyi Onayla: Son stoğu onayladığın **pozitif delta** kadar (yoksa
  /// mevcut pozitif fark kadar) tahsilat kaydı. “Veresiye”yi girince nakit
  /// otomatik `toplam - veresiye` olur (ve tersi).
  Future<void> _applyPaymentOnly() async {
    if (_applying) return;

    final targetUid = _targetUserId;
    if (targetUid == null || targetUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Önce kullanıcı seçin')));
      return;
    }

    setState(() => _applying = true);
    try {
      final maps = await _fetchOrderMapsForApply(targetUid);
      final orderQty = (maps['orderQty'] as Map<String, int>);
      final orderAmt = (maps['orderAmt'] as Map<String, num>);
      final delivered = (maps['delivered'] as Map<String, int>);
      final names = (maps['names'] as Map<String, String>); // 🔹 ürün adları

      Map<String, int> payMap = _lastDeltaPos ?? <String, int>{};
      if (payMap.isEmpty) {
        for (final pid in orderQty.keys) {
          final ordQ = orderQty[pid] ?? 0;
          final targetCount = _target[pid] ?? ordQ;
          final cur = delivered[pid] ?? 0;
          final delta = targetCount - cur;
          final add = max(0, delta);
          if (add > 0) payMap[pid] = add;
        }
      }

      if (payMap.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ödenecek pozitif artış yok')));
        setState(() => _applying = false);
        return;
      }

      num totalAmount = 0;
      payMap.forEach((pid, add) {
        final oq = orderQty[pid] ?? 0;
        final unit = oq > 0 ? (orderAmt[pid] ?? 0) / oq : 0;
        totalAmount += unit * add;
      });

      final split = await showModalBottomSheet<_PaySplit>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.black,
        builder: (_) => _PaymentSplitSheet(total: totalAmount),
      );
      if (split == null) {
        setState(() => _applying = false);
        return;
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final payId = "${targetUid}_${_dayKey}_$nowMs";

      // 1) Önce ödeme kaydı (izin hatasında stok düşmeyelim)
      try {
        await db.collection('customer_payment_summaries').doc(payId).set({
          'userId': targetUid,
          'date': _dayKey,
          'cash': split.cash,
          'credit': split.credit,
          'total': split.total,
          'items': payMap, // {pid: +qty}
          'createdBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'İzin reddedildi. Firestore kurallarında customer_payment_summaries için "create" iznini ver.'
                    '\n(Örn: request.auth != null ve createdBy == request.auth.uid)',
                maxLines: 4,
              ),
            ),
          );
          setState(() => _applying = false);
          return;
        } else {
          rethrow;
        }
      }

      // 2) Ödeme başarılı -> ÜRETİM stoklarını düş (sadece pozitif adetler)
      final decFutures = <Future>[];
      payMap.forEach((pid, addQty) {
        if (addQty > 0) {
          final orderName = names[pid] ?? pid;
          final productionName = _mapToProductionName(orderName);
          decFutures.add(
            decrementProductionUnitsByName(productName: productionName, minusUnits: addQty),
          );
        }
      });
      await Future.wait(decFutures);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ödeme kaydedildi • Nakit: ${_cur(split.cash)} • Veresiye: ${_cur(split.credit)}')),
      );

      setState(() {
        _lastDeltaPos = null; // ödendi
      });
      // Aynı sayfada kalıyoruz.
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  // ---------------------------
  // UI
  // ---------------------------

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: Text(
          widget.showAll ? 'Günlük Stok (Tüm Siparişler)' : 'Günlük Stok (Benim Siparişlerim)',
          style: const TextStyle(color: gold, fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month, color: gold),
            tooltip: 'Tarih Seç',
          ),
          // 🔹 YENİ: Geri Dönüşüm sayfasına git (ProductionRecyclePage)
          IconButton(
            tooltip: 'Geri Dönüşüm (G)',
            icon: const Icon(Icons.recycling, color: gold),
            onPressed: () {
              // showAll + Tümü ise seçili yoksa kendi userId'yi gönderiyoruz.
              final navUserId = widget.showAll ? (_selectedUserId ?? widget.userId) : widget.userId;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProductionRecyclePage(
                    userId: navUserId,
                  ),
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_dayKey, style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ),
      ),

      body: Column(
        children: [
          // ÜST: Kullanıcı Chip'leri (sadece showAll=true iken)
          if (widget.showAll)
            StreamBuilder<Map<String, Map<String, dynamic>>>(
              stream: userAggStream(),
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(color: gold, minHeight: 2),
                  );
                }
                final entries = snap.data!.entries.toList()
                  ..sort((a, b) => (b.value['qty'] as num).compareTo(a.value['qty'] as num));

                num allQty = 0, allAmt = 0;
                for (final e in entries) {
                  allQty += (e.value['qty'] as num);
                  allAmt += (e.value['amount'] as num);
                }

                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('Tümü (${allQty.toInt()} • ${_cur(allAmt)})', style: const TextStyle(fontSize: 12)),
                        selected: _selectedUserId == null,
                        onSelected: (_) {
                          setState(() {
                            _selectedUserId = null;
                            _target.clear();
                            _lastDeltaPos = null;
                          });
                        },
                        selectedColor: gold.withOpacity(0.2),
                        backgroundColor: const Color(0xFF1A1A1A),
                        labelStyle: const TextStyle(color: Colors.white),
                        side: const BorderSide(color: Color(0x33FFD700)),
                      ),
                      const SizedBox(width: 8),
                      ...entries.map((e) {
                        final uid = e.key;
                        final name = (e.value['name'] as String?) ?? _shortUid(uid);
                        final q = (e.value['qty'] as num).toInt();
                        final a = (e.value['amount'] as num);
                        final orders = (e.value['orders'] as num?)?.toInt() ?? 0;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('$name ($q • ${_cur(a)})', style: const TextStyle(fontSize: 12)),
                            selected: _selectedUserId == uid,
                            onSelected: (_) {
                              setState(() {
                                _selectedUserId = uid;
                                _target.clear();
                                _lastDeltaPos = null;
                              });
                            },
                            selectedColor: gold.withOpacity(0.25),
                            backgroundColor: const Color(0xFF1A1A1A),
                            labelStyle: const TextStyle(color: Colors.white),
                            avatar: CircleAvatar(
                              backgroundColor: Colors.black,
                              foregroundColor: gold,
                              radius: 10,
                              child: Text(orders.toString(),
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                            side: const BorderSide(color: Color(0x33FFD700)),
                          ),
                        );
                      })
                    ],
                  ),
                );
              },
            ),

          // ORTA: Ürün listesi — HEDEF (varsayılan sipariş adedi)
          Expanded(
            child: StreamBuilder<Map<String, Map<String, num>>>(
              stream: orderAggStream(),
              builder: (_, orderSnap) {
                if (!orderSnap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }
                final orderAgg = orderSnap.data!;
                return StreamBuilder<Map<String, int>>(
                  stream: deliveryQtyStream(),
                  builder: (_, delSnap) {
                    final delivered = delSnap.data ?? <String, int>{};

                    // SADECE SİPARİŞ EDİLEN ÜRÜNLER — 0’lar listelenmez
                    final pids = orderAgg.keys.toList()..sort();
                    if (pids.isEmpty) {
                      return const Center(child: Text('Sipariş yok', style: TextStyle(color: gold)));
                    }

                    final canSelect = (_targetUserId != null && _targetUserId!.isNotEmpty);

                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 120),
                      itemCount: pids.length,
                      separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 8),
                      itemBuilder: (_, i) {
                        final pid = pids[i];
                        final ord = orderAgg[pid] ?? {'qty': 0, 'amount': 0};
                        final ordQ = (ord['qty'] ?? 0).toInt();
                        final ordA = (ord['amount'] ?? 0);
                        // unit hesaplanıyor; gerekirse kullanılır
                        // final unit = ordQ > 0 ? (ordA / ordQ) : 0;

                        final curDelivered = (delivered[pid] ?? 0);

                        // Ekrandaki HEDEF: set edilmişse o; yoksa SİPARİŞ adedi
                        final targetCount = _target[pid] ?? ordQ;

                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          leading: CircleAvatar(
                            backgroundColor: Colors.black,
                            foregroundColor: gold,
                            radius: 14,
                            child: Text(
                              targetCount.toString(),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ),
                          title: Text(
                            pid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: gold, fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                          subtitle: Text(
                            'Sipariş: $ordQ  •  Mevcut Teslim: $curDelivered',
                            style: const TextStyle(color: Colors.white60, fontSize: 11),
                          ),
                          trailing: !canSelect
                              ? null
                              : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Azalt',
                                onPressed: targetCount > 0
                                    ? () => setState(() => _target[pid] = max(0, targetCount - 1))
                                    : null,
                                icon: const Icon(Icons.remove_circle_outline, color: gold),
                              ),
                              IconButton(
                                tooltip: 'Arttır',
                                onPressed: () => setState(() => _target[pid] = targetCount + 1),
                                icon: const Icon(Icons.add_circle_outline, color: gold),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),

          // ALT: Günlük Hasılat (TESLİM bazlı) + Tahsilat bilgisi + Aksiyonlar
          Container(
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(top: BorderSide(color: Color(0x33FFD700))),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Hasılat (teslimlerden)
                StreamBuilder<num>(
                  stream: deliveryRevenueStream(),
                  builder: (_, revSnap) {
                    final rev = revSnap.data ?? 0;
                    return Text(
                      'Günlük Hasılat: ${_cur(rev)}',
                      style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.w700),
                    );
                  },
                ),
                const SizedBox(height: 4),
                // Tahsilatlar
                StreamBuilder<Map<String, num>>(
                  stream: paymentAggStream(),
                  builder: (_, pSnap) {
                    final cash = pSnap.data?['cash'] ?? 0;
                    final cred = pSnap.data?['credit'] ?? 0;
                    final total = pSnap.data?['total'] ?? 0;
                    return Text(
                      'Tahsilat • Toplam: ${_cur(total)}   Nakit: ${_cur(cash)}   Veresiye: ${_cur(cred)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (_targetUserId != null && !_applying) ? _applyDeliveriesOnly : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD700),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: _applying
                            ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Text('Stoğu Onayla', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (_targetUserId != null && !_applying) ? _applyPaymentOnly : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD700),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: _applying
                            ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Text('Ödemeyi Onayla', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Kullanıcı chip'leri (tüm siparişler)
  Stream<Map<String, Map<String, dynamic>>> userAggStream() async* {
    await for (final snap in _ordersQUnfiltered().snapshots()) {
      final agg = <String, Map<String, dynamic>>{};
      for (final d in snap.docs) {
        final data = d.data();
        final uid = (data['userId'] as String?) ?? '';
        if (uid.isEmpty) continue;
        final uname = (data['userName'] as String?)?.trim();
        final name = (uname == null || uname.isEmpty) ? _shortUid(uid) : uname;

        num qty = 0, amt = 0;
        for (final it in (data['items'] as List? ?? const [])) {
          if (it is! Map) continue;
          final q = (it['qty'] as num?) ?? 0;
          final up = (it['unitPrice'] as num?) ?? 0;
          final lt = (it['lineTotal'] as num?) ?? (up * q);
          qty += q;
          amt += lt;
        }

        final cur = agg[uid];
        if (cur == null) {
          agg[uid] = {'name': name, 'qty': qty, 'amount': amt, 'orders': 1};
        } else {
          cur['name'] = name;
          cur['qty'] = (cur['qty'] as num) + qty;
          cur['amount'] = (cur['amount'] as num) + amt;
          cur['orders'] = (cur['orders'] as num) + 1;
        }
      }
      yield agg;
    }
  }
}

// ------------------------------
// Nakit / Veresiye Sheet
// ------------------------------
class _PaySplit {
  final num cash;
  final num credit;
  num get total => cash + credit;
  _PaySplit(this.cash, this.credit);
}

class _PaymentSplitSheet extends StatefulWidget {
  const _PaymentSplitSheet({required this.total, super.key});
  final num total;

  @override
  State<_PaymentSplitSheet> createState() => _PaymentSplitSheetState();
}

class _PaymentSplitSheetState extends State<_PaymentSplitSheet> {
  final cashCtrl = TextEditingController();
  final credCtrl = TextEditingController();
  bool _updatingPeer = false; // onChanged içinde döngüyü engellemek için

  num _parse(String s) => num.tryParse(s.trim().replaceAll(',', '.')) ?? 0;

  void _syncFromCash() {
    if (_updatingPeer) return;
    _updatingPeer = true;
    final cash = _parse(cashCtrl.text);
    final newCred = max(0, widget.total - cash);
    final txt = newCred.toStringAsFixed(2);
    if (credCtrl.text != txt) credCtrl.text = txt;
    _updatingPeer = false;
  }

  void _syncFromCredit() {
    if (_updatingPeer) return;
    _updatingPeer = true;
    final cred = _parse(credCtrl.text);
    final newCash = max(0, widget.total - cred);
    final txt = newCash.toStringAsFixed(2);
    if (cashCtrl.text != txt) cashCtrl.text = txt;
    _updatingPeer = false;
  }

  @override
  void initState() {
    super.initState();
    // varsayılan: hepsi nakit
    cashCtrl.text = widget.total.toStringAsFixed(2);
    credCtrl.text = '0';
    // alanlar birbirini otomatik dengelesin
    cashCtrl.addListener(_syncFromCash);
    credCtrl.addListener(_syncFromCredit);
  }

  @override
  void dispose() {
    cashCtrl.removeListener(_syncFromCash);
    credCtrl.removeListener(_syncFromCredit);
    cashCtrl.dispose();
    credCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Ödeme Paylaşımı', style: TextStyle(color: gold, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Toplam: ₺${widget.total.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            TextField(
              controller: credCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Veresiye (₺)',
                labelStyle: TextStyle(color: gold),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: gold)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.amberAccent, width: 2)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: cashCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nakit (₺) — otomatik',
                labelStyle: TextStyle(color: gold),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: gold)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.amberAccent, width: 2)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
                onPressed: () {
                  final cash = _parse(cashCtrl.text);
                  final cred = _parse(credCtrl.text);
                  final sum = cash + cred;
                  if (cash < 0 || cred < 0) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Tutarlar negatif olamaz')));
                    return;
                  }
                  // Otomatik senkron zaten toplamı tutuyor; yine de tolerans kontrolü:
                  if ((sum - widget.total).abs() > 0.01) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Nakit + Veresiye toplamı ile seçilen toplam eşleşmiyor')));
                    return;
                  }
                  Navigator.pop(context, _PaySplit(cash, cred));
                },
                icon: const Icon(Icons.save),
                label: const Text('Kaydet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
