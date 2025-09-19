// customer_revenue_summary_page.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CustomerRevenueSummaryPage extends StatefulWidget {
  const CustomerRevenueSummaryPage({super.key, this.showAll = true, required this.defaultUserId});
  final bool showAll;        // true: tüm kullanıcılar; false: sadece defaultUserId
  final String defaultUserId;

  @override
  State<CustomerRevenueSummaryPage> createState() => _CustomerRevenueSummaryPageState();
}

class _CustomerRevenueSummaryPageState extends State<CustomerRevenueSummaryPage> {
  final db = FirebaseFirestore.instance;
  DateTime _selectedDay = DateTime.now();
  String? _selectedUserId; // showAll=true iken chip'ten seçilecek

  DateTime get _dayStart => DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
  DateTime get _dayEnd   => _dayStart.add(const Duration(days: 1));
  String get _dayKey     => _dateKey(_dayStart);

  // 🔹 HAFTA / AY / YIL aralıkları (sağ uç "exclusive")
  DateTime get _weekStart        => _dayStart.subtract(Duration(days: _dayStart.weekday - 1)); // Pazartesi
  DateTime get _weekEndExclusive => _weekStart.add(const Duration(days: 7));

  DateTime get _monthStart        => DateTime(_selectedDay.year, _selectedDay.month, 1);
  DateTime get _monthEndExclusive => DateTime(_selectedDay.year, _selectedDay.month + 1, 1);

  DateTime get _yearStart        => DateTime(_selectedDay.year, 1, 1);
  DateTime get _yearEndExclusive => DateTime(_selectedDay.year + 1, 1, 1);

  // Kullanıcı filtresi bilgisi
  String? get _activeUserId => widget.showAll ? _selectedUserId : widget.defaultUserId;
  bool   get _shouldFilterByUser => !widget.showAll || _selectedUserId != null;

  String _cur(num v) => "₺${v.toStringAsFixed(2)}";
  String _dateKey(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}";

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: DateTime(2023,1,1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
                primary: Color(0xFFFFD700), surface: Colors.black, onSurface: Colors.white),
            dialogBackgroundColor: Colors.black,
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _selectedDay = picked);
  }

  Query<Map<String, dynamic>> _ordersQ({bool filtered = true}) {
    var q = db.collection('customer_orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(_dayStart))
        .where('createdAt', isLessThan: Timestamp.fromDate(_dayEnd));
    if (filtered) {
      if (widget.showAll) {
        if (_selectedUserId != null) q = q.where('userId', isEqualTo: _selectedUserId);
      } else {
        q = q.where('userId', isEqualTo: widget.defaultUserId);
      }
    }
    return q.orderBy('createdAt', descending: true);
  }

  Query<Map<String, dynamic>> _ordersQUnfiltered() {
    return _ordersQ(filtered: false);
  }

  Query<Map<String, dynamic>> _deliveriesQ() {
    var q = db.collection('customer_deliveries')
        .where('date', isEqualTo: _dayKey);
    if (widget.showAll) {
      if (_selectedUserId != null) q = q.where('userId', isEqualTo: _selectedUserId);
    } else {
      q = q.where('userId', isEqualTo: widget.defaultUserId);
    }
    return q;
  }

  // ======== Tahsilat sorguları: Gün / Hafta / Ay / Yıl / Tüm Zaman ========

  // 🔸 Tek gün için (isim aynı kalsın)
  Query<Map<String, dynamic>> _paymentsQ() => _paymentsRangeQ(_dayStart, _dayEnd);

  // 🔸 Genel aralık sorgusu (date: 'YYYY-MM-DD' string). SADECE TARİH filtresi!
  Query<Map<String, dynamic>> _paymentsRangeQ(DateTime from, DateTime toExclusive) {
    // 👉 orderBy('date') YOK, userId filtresi YOK — composite index istemesin diye
    return db.collection('customer_payment_summaries')
        .where('date', isGreaterThanOrEqualTo: _dateKey(from))
        .where('date', isLessThan: _dateKey(toExclusive));
  }

  // 🔸 Tüm zaman (mümkünse userId ile tek alan filtresi; yoksa hepsi)
  Query<Map<String, dynamic>> _paymentsAllTimeQ() {
    Query<Map<String, dynamic>> q = db.collection('customer_payment_summaries');
    if (_shouldFilterByUser && (_activeUserId ?? '').isNotEmpty) {
      q = q.where('userId', isEqualTo: _activeUserId);
    }
    return q;
  }

  // Kullanıcı chip'leri
  Stream<Map<String, Map<String, dynamic>>> userAggStream() async* {
    await for (final snap in _ordersQUnfiltered().snapshots()) {
      final agg = <String, Map<String, dynamic>>{};
      for (final d in snap.docs) {
        final data = d.data();
        final uid = (data['userId'] as String?) ?? '';
        if (uid.isEmpty) continue;
        final uname = (data['userName'] as String?)?.trim();
        final name = (uname == null || uname.isEmpty) ? "${uid.substring(0,2)}…${uid.substring(max(0, uid.length-4))}" : uname;

        num sum = 0; num qty = 0;
        for (final it in (data['items'] as List? ?? const [])) {
          if (it is! Map) continue;
          final q = (it['qty'] as num?) ?? 0;
          final up = (it['unitPrice'] as num?) ?? 0;
          final lt = (it['lineTotal'] as num?) ?? (up*q);
          qty += q; sum += lt;
        }
        final cur = agg[uid];
        if (cur == null) {
          agg[uid] = {'name': name, 'qty': qty, 'amount': sum, 'orders': 1};
        } else {
          cur['name']   = name;
          cur['qty']    = (cur['qty'] as num) + qty;
          cur['amount'] = (cur['amount'] as num) + sum;
          cur['orders'] = (cur['orders'] as num) + 1;
        }
      }
      yield agg;
    }
  }

  // Ürün bazında SIPARIŞ agregasyonu
  Stream<Map<String, Map<String, num>>> orderAggStream() async* {
    await for (final snap in _ordersQ(filtered: true).snapshots()) {
      final m = <String, Map<String, num>>{};
      for (final d in snap.docs) {
        final items = (d.data()['items'] as List?) ?? const [];
        for (final it in items) {
          if (it is! Map) continue;
          final pid = (it['productId'] as String?) ?? '';
          if (pid.isEmpty) continue;
          final q = (it['qty'] as num?) ?? 0;
          final up = (it['unitPrice'] as num?) ?? 0;
          final lt = (it['lineTotal'] as num?) ?? (up*q);
          final cur = m[pid] ?? {'qty': 0, 'amount': 0, 'unit': up};
          m[pid] = {
            'qty': (cur['qty'] ?? 0) + q,
            'amount': (cur['amount'] ?? 0) + lt,
            'unit': up > 0 ? up : (cur['unit'] ?? 0),
          };
        }
      }
      yield m;
    }
  }

  // Ürün bazında TESLİM agregasyonu (negatif düzeltmeleri de toplar)
  Stream<Map<String, Map<String, num>>> deliveryAggStream() async* {
    await for (final snap in _deliveriesQ().snapshots()) {
      final m = <String, Map<String, num>>{};
      for (final d in snap.docs) {
        final data = d.data();
        final pid = (data['productId'] as String?) ?? '';
        if (pid.isEmpty) continue;
        final q = (data['qty'] as num?) ?? 0;          // negatif olabilir
        final up = (data['unitPrice'] as num?) ?? 0;
        final lt = (data['lineTotal'] as num?) ?? (up*q);
        final cur = m[pid] ?? {'qty': 0, 'amount': 0, 'unit': up};
        m[pid] = {
          'qty': (cur['qty'] ?? 0) + q,
          'amount': (cur['amount'] ?? 0) + lt,
          'unit': up > 0 ? up : (cur['unit'] ?? 0),
        };
      }
      yield m;
    }
  }

  // ======== Tahsilat Akışları: Gün / Hafta / Ay / Yıl / Tüm Zaman ========

  // Ortak toplayıcı — kullanıcıyı burada filtreliyoruz (sorguda değil!)
  Stream<Map<String, num>> _sumPaymentsFromQuery(Query<Map<String, dynamic>> q) async* {
    await for (final snap in q.snapshots()) {
      num cash = 0, credit = 0, total = 0;
      for (final d in snap.docs) {
        final data = d.data();
        // İstemci tarafı user filtresi:
        if (_shouldFilterByUser && (_activeUserId ?? '').isNotEmpty) {
          final uid = (data['userId'] as String?) ?? '';
          if (uid != _activeUserId) continue;
        }
        cash   += (data['cash']   as num?) ?? 0;
        credit += (data['credit'] as num?) ?? 0;
        total  += (data['total']  as num?) ?? 0;
      }
      yield {'cash': cash, 'credit': credit, 'total': total};
    }
  }

  Stream<Map<String, num>> paymentAggStream() =>
      _sumPaymentsFromQuery(_paymentsRangeQ(_dayStart, _dayEnd));

  Stream<Map<String, num>> paymentAggWeeklyStream() =>
      _sumPaymentsFromQuery(_paymentsRangeQ(_weekStart, _weekEndExclusive));

  Stream<Map<String, num>> paymentAggMonthlyStream() =>
      _sumPaymentsFromQuery(_paymentsRangeQ(_monthStart, _monthEndExclusive));

  Stream<Map<String, num>> paymentAggYearlyStream() =>
      _sumPaymentsFromQuery(_paymentsRangeQ(_yearStart, _yearEndExclusive));

  // Tüm zaman (mümkünse userId ile tek alan filtresi; yine de güvenli)
  Stream<Map<String, num>> paymentAggAllTimeStream() async* {
    await for (final snap in _paymentsAllTimeQ().snapshots()) {
      num cash = 0, credit = 0, total = 0;
      for (final d in snap.docs) {
        final data = d.data();
        // _paymentsAllTimeQ zaten userId’i filtreleyebilir; ekstra kontrol zarar vermez
        if (_shouldFilterByUser && (_activeUserId ?? '').isNotEmpty) {
          final uid = (data['userId'] as String?) ?? '';
          if (uid != _activeUserId) continue;
        }
        cash   += (data['cash']   as num?) ?? 0;
        credit += (data['credit'] as num?) ?? 0;
        total  += (data['total']  as num?) ?? 0;
      }
      yield {'cash': cash, 'credit': credit, 'total': total};
    }
  }

  // ---------- Veresiye Azalt (toplam değişmeden) ----------
  Future<void> _applyCreditDecrease(num amount) async {
    final uid = _activeUserId;
    if (uid == null || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Önce kullanıcı seçin')));
      return;
    }
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tutar 0’dan büyük olmalı')));
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final payId = "${uid}_${_dayKey}_adj_$nowMs";

    await db.collection('customer_payment_summaries').doc(payId).set({
      'userId'    : uid,
      'date'      : _dayKey,
      'cash'      : amount,   // +X nakit
      'credit'    : -amount,  // -X veresiye
      'total'     : 0,        // toplam değişmesin
      'reason'    : 'credit_adjustment',
      'createdBy' : FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
      'createdAt' : FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Veresiye ${_cur(amount)} azaltıldı (toplam değişmedi)')),
    );
  }

  Future<num?> _openCreditDecreaseSheet(num maxCredit) async {
    return await showModalBottomSheet<num>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (_) => _CreditDecreaseSheet(maxCredit: maxCredit),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    Widget _err(String? m) => m == null ? const SizedBox.shrink()
        : Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text('⚠️ $m', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text('Teslim/Hasılat Özeti', style: TextStyle(color: gold)),
        actions: [
          IconButton(onPressed: _pickDate, tooltip: 'Tarih Seç', icon: const Icon(Icons.calendar_month, color: gold)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_dayKey, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
          ),
        ),
      ),

      body: Column(
        children: [
          if (widget.showAll)
            StreamBuilder<Map<String, Map<String, dynamic>>>(
              stream: userAggStream(),
              builder: (_, snap) {
                if (snap.hasError) {
                  return _err('Kullanıcı listesi okunamadı');
                }
                if (!snap.hasData) return const SizedBox(height: 4, child: LinearProgressIndicator(color: gold));
                final entries = snap.data!.entries.toList()
                  ..sort((a,b) => (b.value['qty'] as num).compareTo(a.value['qty'] as num));
                num allQty = 0, allAmt = 0;
                for (final e in entries) { allQty += (e.value['qty'] as num); allAmt += (e.value['amount'] as num); }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('Tümü (${allQty.toInt()} • ${_cur(allAmt)})', style: const TextStyle(fontSize: 12)),
                        selected: _selectedUserId == null,
                        onSelected: (_) => setState(() => _selectedUserId = null),
                        selectedColor: gold.withOpacity(0.2),
                        backgroundColor: const Color(0xFF1A1A1A),
                        labelStyle: const TextStyle(color: Colors.white),
                        side: const BorderSide(color: Color(0x33FFD700)),
                      ),
                      const SizedBox(width: 8),
                      ...entries.map((e) {
                        final uid = e.key; final name = e.value['name'] as String;
                        final q = (e.value['qty'] as num).toInt(); final a = (e.value['amount'] as num);
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('$name ($q • ${_cur(a)})', style: const TextStyle(fontSize: 12)),
                            selected: _selectedUserId == uid,
                            onSelected: (_) => setState(() => _selectedUserId = uid),
                            selectedColor: gold.withOpacity(0.25),
                            backgroundColor: const Color(0xFF1A1A1A),
                            labelStyle: const TextStyle(color: Colors.white),
                            side: const BorderSide(color: Color(0x33FFD700)),
                          ),
                        );
                      })
                    ],
                  ),
                );
              },
            ),

          // Sipariş & Teslim birleştirilmiş liste
          Expanded(
            child: StreamBuilder<Map<String, Map<String, num>>>(
              stream: orderAggStream(),
              builder: (_, orderSnap) {
                if (orderSnap.hasError) {
                  return Center(child: _err('Siparişler okunamadı'));
                }
                if (!orderSnap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: gold));
                }
                final orderAgg = orderSnap.data!;
                return StreamBuilder<Map<String, Map<String, num>>>(
                  stream: deliveryAggStream(),
                  builder: (_, delSnap) {
                    if (delSnap.hasError) {
                      return Center(child: _err('Teslimler okunamadı'));
                    }
                    final delAgg = delSnap.data ?? <String, Map<String, num>>{};

                    final pids = {...orderAgg.keys, ...delAgg.keys}.toList()..sort();
                    if (pids.isEmpty) {
                      return const Center(child: Text('Kayıt yok', style: TextStyle(color: gold)));
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 120),
                      itemCount: pids.length,
                      separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 8),
                      itemBuilder: (_, i) {
                        final pid = pids[i];
                        final o = orderAgg[pid] ?? {'qty': 0, 'amount': 0, 'unit': 0};
                        final d = delAgg[pid] ?? {'qty': 0, 'amount': 0, 'unit': 0};
                        final ordQ = (o['qty'] ?? 0).toInt();
                        final ordA = (o['amount'] ?? 0);
                        final delQ = (d['qty'] ?? 0).toInt();   // negatif düzeltmeler dahil
                        final delA = (d['amount'] ?? 0);
                        final unit = (o['unit'] ?? 0) > 0 ? (o['unit'] ?? 0) : (d['unit'] ?? 0);
                        final diffQ = max(0, ordQ - delQ);

                        return ListTile(
                          dense: true,
                          title: Text(pid, style: const TextStyle(color: gold, fontWeight: FontWeight.w600)),
                          subtitle: Text('Birim ~ ${unit.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          trailing: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Sipariş: $ordQ  •  Teslim: $delQ  •  Bekleyen: $diffQ',
                                  style: const TextStyle(color: Colors.white)),
                              Text('₺ Sipariş: ${_cur(ordA)}   ₺ Teslim: ${_cur(delA)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
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

          // Alt toplamlar + Tahsilat (Gün/Hafta/Ay/Yıl) + Veresiye Azalt + Tüm Zaman Veresiye
          Container(
            decoration: const BoxDecoration(
              color: Colors.black, border: Border(top: BorderSide(color: Color(0x33FFD700))),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              children: [
                StreamBuilder<Map<String, Map<String, num>>>(
                  stream: orderAggStream(),
                  builder: (_, oSnap) {
                    if (oSnap.hasError) return _err('Sipariş toplamları okunamadı');
                    final o = oSnap.data ?? {};
                    num ordA = 0; int ordQ = 0;
                    o.values.forEach((v) { ordA += (v['amount'] ?? 0); ordQ += (v['qty'] ?? 0).toInt(); });

                    return StreamBuilder<Map<String, Map<String, num>>>(
                      stream: deliveryAggStream(),
                      builder: (_, dSnap) {
                        if (dSnap.hasError) return _err('Teslim toplamları okunamadı');
                        final d = dSnap.data ?? {};
                        num delA = 0; int delQ = 0;
                        d.values.forEach((v) { delA += (v['amount'] ?? 0); delQ += (v['qty'] ?? 0).toInt(); });

                        final diffQ = max(0, ordQ - delQ);
                        return Row(
                          children: [
                            Expanded(child: Text('Sipariş: $ordQ • ${_cur(ordA)}', style: const TextStyle(color: Colors.white))),
                            Expanded(child: Text('Teslim: $delQ • ${_cur(delA)}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))),
                            Expanded(child: Text('Bekleyen: $diffQ', textAlign: TextAlign.end, style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.w700))),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 10),

                // ==== GÜNLÜK ====
                StreamBuilder<Map<String, num>>(
                  stream: paymentAggStream(),
                  builder: (_, pSnapDay) {
                    if (pSnapDay.hasError) return _err('Günlük hasılat okunamadı');
                    final cashD = pSnapDay.data?['cash'] ?? 0;
                    final credD = pSnapDay.data?['credit'] ?? 0;
                    final totalD = pSnapDay.data?['total'] ?? 0;

                    final hasUser = (_activeUserId != null && _activeUserId!.isNotEmpty);
                    final canAdjust = hasUser && credD > 0;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text('Günlük Hasılat: ${_cur(totalD)}', style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.w700))),
                            Expanded(child: Text('Nakit: ${_cur(cashD)}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))),
                            Expanded(child: Text('Veresiye: ${_cur(credD)}', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white70))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.swap_horiz),
                            label: const Text('Veresiyeyi Azalt (Toplam Değişmeden)'),
                            onPressed: canAdjust ? () async {
                              final val = await _openCreditDecreaseSheet(credD);
                              if (val == null) return;
                              final amt = val;
                              if (amt <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tutar 0’dan büyük olmalı')));
                                return;
                              }
                              if (amt > credD + 0.001) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tutar mevcut veresiye tutarından büyük olamaz')));
                                return;
                              }
                              await _applyCreditDecrease(amt);
                            } : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFFD700),
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: Colors.white12,
                              disabledForegroundColor: Colors.white38,
                            ),
                          ),
                        ),
                        if (!hasUser)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text('Not: Veresiyeyi azaltmak için önce bir kullanıcı seçin.', style: TextStyle(color: Colors.white54, fontSize: 12)),
                          ),

                        const SizedBox(height: 12),

                        // ==== HAFTALIK ====
                        StreamBuilder<Map<String, num>>(
                          stream: paymentAggWeeklyStream(),
                          builder: (_, pSnapW) {
                            if (pSnapW.hasError) return _err('Haftalık tahsilat okunamadı');
                            final totalW = pSnapW.data?['total'] ?? 0;
                            final creditW = pSnapW.data?['credit'] ?? 0;
                            return Row(
                              children: [
                                Expanded(child: Text('Haftalık Hasılat: ${_cur(totalW)}', style: const TextStyle(color: Colors.white))),
                                Expanded(child: Text('Veresiye: ${_cur(creditW)}', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white70))),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 6),

                        // ==== AYLIK ====
                        StreamBuilder<Map<String, num>>(
                          stream: paymentAggMonthlyStream(),
                          builder: (_, pSnapM) {
                            if (pSnapM.hasError) return _err('Aylık tahsilat okunamadı');
                            final totalM = pSnapM.data?['total'] ?? 0;
                            final creditM = pSnapM.data?['credit'] ?? 0;
                            return Row(
                              children: [
                                Expanded(child: Text('Aylık Hasılat: ${_cur(totalM)}', style: const TextStyle(color: Colors.white))),
                                Expanded(child: Text('Veresiye: ${_cur(creditM)}', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white70))),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 6),

                        // ==== YILLIK ====
                        StreamBuilder<Map<String, num>>(
                          stream: paymentAggYearlyStream(),
                          builder: (_, pSnapY) {
                            if (pSnapY.hasError) return _err('Yıllık tahsilat okunamadı');
                            final totalY = pSnapY.data?['total'] ?? 0;
                            final creditY = pSnapY.data?['credit'] ?? 0;
                            return Row(
                              children: [
                                Expanded(child: Text('Yıllık Hasılat: ${_cur(totalY)}', style: const TextStyle(color: Colors.white))),
                                Expanded(child: Text('Veresiye: ${_cur(creditY)}', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white70))),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 10),

                        // ==== TÜM ZAMAN VERESİYE BAKİYESİ ====
                        StreamBuilder<Map<String, num>>(
                          stream: paymentAggAllTimeStream(),
                          builder: (_, pAll) {
                            if (pAll.hasError) return _err('Tüm zaman veresiye okunamadı');
                            final allCred = pAll.data?['credit'] ?? 0;
                            return Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Tüm Zaman Veresiye (Bakiye): ${_cur(allCred)}',
                                    style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------
// Veresiye Azaltım Sheet
// ------------------------------
class _CreditDecreaseSheet extends StatefulWidget {
  const _CreditDecreaseSheet({required this.maxCredit, super.key});
  final num maxCredit;

  @override
  State<_CreditDecreaseSheet> createState() => _CreditDecreaseSheetState();
}

class _CreditDecreaseSheetState extends State<_CreditDecreaseSheet> {
  final ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    ctrl.text = '0';
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Veresiyeyi Azalt', style: TextStyle(color: gold, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Mevcut Veresiye Üst Sınır: ₺${widget.maxCredit.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Azaltma Tutarı (₺)',
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
                  final v = num.tryParse(ctrl.text.trim().replaceAll(',', '.')) ?? 0;
                  Navigator.pop<num>(context, v);
                },
                icon: const Icon(Icons.check),
                label: const Text('Onayla'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
