// lib/production_recycle_page.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ProductionRecyclePage extends StatefulWidget {
  const ProductionRecyclePage({
    super.key,
    required this.userId,
    this.dateKey, // Opsiyonel: dışarıdan YYYY-MM-DD gelirse onu kullan
  });

  final String userId;
  final String? dateKey;

  @override
  State<ProductionRecyclePage> createState() => _ProductionRecyclePageState();
}

class _ProductionRecyclePageState extends State<ProductionRecyclePage> {
  final db = FirebaseFirestore.instance;

  DateTime _selectedDay = DateTime.now();
  bool _saving = false;

  /// Seçimler: docId -> { 'trays': int, 'units': int }
  final Map<String, Map<String, int>> _sel = {};

  DateTime get _dayStart =>
      DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
  DateTime get _dayEnd => _dayStart.add(const Duration(days: 1));

  // Eğer widget.dateKey verilmişse onu kullan; yoksa seçili günden üret
  String get _computedDayKey =>
      "${_dayStart.year}-${_dayStart.month.toString().padLeft(2, '0')}-${_dayStart.day.toString().padLeft(2, '0')}";
  String get _dayKey => widget.dateKey ?? _computedDayKey;

  String _shortNum(int v) => v.toString();

  Future<void> _pickDate() async {
    // Dışarıdan dateKey geldiyse bile kullanıcı tarih seçebilir; o zaman seçilen gün geçerli olur
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
      });
    }
  }

  // production listesini dinle
  Stream<QuerySnapshot<Map<String, dynamic>>> _productionStream() {
    return db.collection('production').orderBy('productName').snapshots();
  }

  // Bugünkü geri dönüşüm toplamlari: productId -> {trays, units}
  Stream<Map<String, Map<String, int>>> _recycleAggStream() async* {
    final q = db
        .collection('production_recycles')
        .where('date', isEqualTo: _dayKey);

    await for (final snap in q.snapshots()) {
      final m = <String, Map<String, int>>{};
      for (final d in snap.docs) {
        final data = d.data();
        final pid = (data['productId'] as String?) ?? '';
        if (pid.isEmpty) continue;
        final t = ((data['trays'] as num?) ?? 0).toInt();
        final u = ((data['units'] as num?) ?? 0).toInt();
        final cur = m[pid] ?? {'trays': 0, 'units': 0};
        m[pid] = {
          'trays': (cur['trays'] ?? 0) + t,
          'units': (cur['units'] ?? 0) + u,
        };
      }
      yield m;
    }
  }

  // Bir dokümanın tava/adetini güvenli şekilde azalt (negatif olmaz)
  Future<void> _decrementProductionByRef({
    required DocumentReference<Map<String, dynamic>> ref,
    int minusTrays = 0,
    int minusUnits = 0,
  }) async {
    if (minusTrays <= 0 && minusUnits <= 0) return;

    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';

    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data() ?? {};
      final curTrays = (data['trays'] as num?)?.toInt() ?? 0;
      final curUnits = (data['units'] as num?)?.toInt() ?? 0;

      final newTrays = max(0, curTrays - max(0, minusTrays));
      final newUnits = max(0, curUnits - max(0, minusUnits));

      tx.set(
        ref,
        {
          'trays': newTrays,
          'units': newUnits,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': uid,
        },
        SetOptions(merge: true),
      );
    });
  }

  // Seçimleri kaydet: production_recycles + production decrement
  Future<void> _saveSelections(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) async {
    if (_saving) return;

    // Toplam seçili var mı?
    final hasAny =
    _sel.values.any((m) => (m['trays'] ?? 0) > 0 || (m['units'] ?? 0) > 0);
    if (!hasAny) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('G için bir değer girilmedi')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      // 1) Logları batch ile yaz
      final batch = db.batch();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      int i = 0;

      // docId -> doc
      final byId = {for (final d in docs) d.id: d};
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';

      _sel.forEach((docId, vals) {
        final t = (vals['trays'] ?? 0);
        final u = (vals['units'] ?? 0);
        if (t <= 0 && u <= 0) return;

        final doc = byId[docId];
        if (doc == null) return;
        final name = (doc.data()['productName'] as String?) ?? '-';

        final rid = "${docId}_${_dayKey}_${nowMs}_${i++}";
        batch.set(db.collection('production_recycles').doc(rid), {
          'productId': docId,
          'productName': name,
          'trays': t,
          'units': u,
          'date': _dayKey,
          // 🔐 Oturumdaki kullanıcıyı yaz
          'createdBy': uid,
          'createdAt': FieldValue.serverTimestamp(),
          'tag': 'G',
        });
      });

      try {
        await batch.commit();
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'İzin reddedildi (production_recycles • create). '
                  'Kurallarda: request.auth != null ve createdBy == request.auth.uid şartlarını doğrulayın.',
              maxLines: 4,
            ),
          ));
          setState(() => _saving = false);
          return;
        } else {
          rethrow;
        }
      }

      // 2) Stokları transaction ile düş (negatife izin yok)
      for (final entry in _sel.entries) {
        final docId = entry.key;
        final t = (entry.value['trays'] ?? 0);
        final u = (entry.value['units'] ?? 0);
        if (t <= 0 && u <= 0) continue;

        final ref = byId[docId]?.reference;
        if (ref != null) {
          try {
            await _decrementProductionByRef(
              ref: ref,
              minusTrays: t,
              minusUnits: u,
            );
          } on FirebaseException catch (e) {
            if (e.code == 'permission-denied') {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                  'İzin reddedildi (production • update). '
                      'Kurallarda: request.auth != null, updatedBy == request.auth.uid '
                      've değerlerin arttırılmaması (ör. trays/units azalmalı) koşullarını kontrol edin.',
                  maxLines: 5,
                ),
              ));
              // Not: log kaydı başarılı oldu; stok düşürme yetkisi yoksa burada duruyoruz.
              setState(() => _saving = false);
              return;
            } else {
              rethrow;
            }
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Geri dönüşüm (G) kaydedildi ve stok düşüldü'),
      ));
      setState(() {
        _sel.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Hata: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Ürün başına "1 tava = X adet" dönüşümü.
  /// 1) 'unitsPerTray' alanı varsa onu kullanır
  /// 2) Yoksa mevcut stoktan yaklaşık değer: units ~/ max(trays,1)  (en az 1)
  int _unitsPerTrayFor(Map<String, dynamic> productData) {
    final fromField = (productData['unitsPerTray'] as num?)?.toInt();
    if (fromField != null && fromField > 0) return fromField;
    final trays = (productData['trays'] as num? ?? 0).toInt();
    final units = (productData['units'] as num? ?? 0).toInt();
    if (trays > 0 && units >= trays) {
      final approx = units ~/ trays;
      return max(1, approx);
    }
    return 1; // fallback
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text('Geri Dönüşüm (G)',
            style: TextStyle(color: gold, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            onPressed: _pickDate,
            tooltip: 'Gün seç',
            icon: const Icon(Icons.calendar_month, color: gold),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_dayKey,
                style: const TextStyle(
                    color: gold, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _productionStream(),
        builder: (ctx, prodSnap) {
          if (prodSnap.hasError) {
            return const Center(
                child:
                Text('Hata oluştu', style: TextStyle(color: Colors.red)));
          }
          if (!prodSnap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: Color(0xFFFFD700)));
          }

          final docs = prodSnap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Üretimde kayıt yok',
                  style: TextStyle(color: Color(0xFFFFD700))),
            );
          }

          return StreamBuilder<Map<String, Map<String, int>>>(
            stream: _recycleAggStream(),
            builder: (ctx, recSnap) {
              final todayG = recSnap.data ?? <String, Map<String, int>>{};

              return Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final d = docs[i];
                        final id = d.id;
                        final m = d.data();
                        final name = (m['productName'] as String?) ?? '-';
                        final trays = (m['trays'] as num? ?? 0).toInt();
                        final units = (m['units'] as num? ?? 0).toInt();

                        final perTray = _unitsPerTrayFor(m);

                        final gToday =
                            todayG[id] ?? {'trays': 0, 'units': 0};
                        final gTrays = (gToday['trays'] ?? 0);
                        final gUnits = (gToday['units'] ?? 0);

                        final sel = _sel[id] ?? {'trays': 0, 'units': 0};
                        final sTrays = sel['trays'] ?? 0;
                        final sUnits = sel['units'] ?? 0;

                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey[900],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: gold, width: 1),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        color: gold,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  _pill('Tava', _shortNum(trays)),
                                  const SizedBox(width: 8),
                                  _pill('Adet', _shortNum(units)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '1 tava ≈ $perTray adet',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'G (bugün): ${_shortNum(gTrays)} tava • ${_shortNum(gUnits)} adet',
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 11),
                              ),
                              const SizedBox(height: 8),

                              // Seçim stepleri
                              Row(
                                children: [
                                  // G Tava (adet otomatik ± perTray)
                                  Expanded(
                                    child: _stepper(
                                      label: 'G Tava',
                                      value: sTrays,
                                      onDec: sTrays > 0
                                          ? () => setState(() {
                                        final nextTrays = max(0, sTrays - 1);
                                        // adet de otomatik perTray azalır
                                        final nextUnits =
                                        max(0, sUnits - perTray);
                                        _sel[id] = {
                                          'trays':
                                          min(trays, nextTrays),
                                          'units':
                                          min(units, nextUnits),
                                        };
                                      })
                                          : null,
                                      onInc: () => setState(() {
                                        // tava +1, adet + perTray
                                        final nextTrays = min(trays, sTrays + 1);
                                        final nextUnits =
                                        min(units, sUnits + perTray);
                                        _sel[id] = {
                                          'trays': nextTrays,
                                          'units': nextUnits,
                                        };
                                      }),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // G Adet (bağımsız, sınırları stok ile kırpılır)
                                  Expanded(
                                    child: _stepper(
                                      label: 'G Adet',
                                      value: sUnits,
                                      onDec: sUnits > 0
                                          ? () => setState(() {
                                        _sel[id] = {
                                          'trays': sTrays,
                                          'units':
                                          max(0, sUnits - 1),
                                        };
                                      })
                                          : null,
                                      onInc: () => setState(() {
                                        _sel[id] = {
                                          'trays': sTrays,
                                          'units':
                                          min(units, sUnits + 1),
                                        };
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // Alt aksiyon bar
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      border:
                      Border(top: BorderSide(color: Color(0x33FFD700))),
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed:
                            _saving ? null : () => _saveSelections(docs),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFFD700),
                              foregroundColor: Colors.black,
                              padding:
                              const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: _saving
                                ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                                : const Icon(Icons.save),
                            label: const Text('Kaydet (G) — stoktan düş'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
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
          Text('$label: ',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(
            value,
            style: const TextStyle(
                color: gold, fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _stepper({
    required String label,
    required int value,
    VoidCallback? onDec,
    VoidCallback? onInc,
  }) {
    const gold = Color(0xFFFFD700);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF101010),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33FFD700)),
      ),
      child: Row(
        children: [
          Expanded(
              child:
              Text(label, style: const TextStyle(color: Colors.white70))),
          IconButton(
            onPressed: onDec,
            icon: const Icon(Icons.remove_circle_outline, color: gold),
          ),
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33FFD700)),
            ),
            child: Text(value.toString(),
                style: const TextStyle(color: Colors.white)),
          ),
          IconButton(
            onPressed: onInc,
            icon: const Icon(Icons.add_circle_outline, color: gold),
          ),
        ],
      ),
    );
  }
}
