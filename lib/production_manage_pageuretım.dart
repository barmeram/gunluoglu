import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ProductionManagePage extends StatefulWidget {
  const ProductionManagePage({super.key, required this.userId});
  final String userId;

  @override
  State<ProductionManagePage> createState() => _ProductionManagePageState();
}

class _ProductionManagePageState extends State<ProductionManagePage> {
  final db = FirebaseFirestore.instance;
  final auth = FirebaseAuth.instance;

  static const gold = Color(0xFFFFD700);

  bool _loadingRole = true;
  bool _isAdmin = false;
  bool _isProducer = false;

  @override
  void initState() {
    super.initState();
    _fetchRole();
  }

  Future<void> _fetchRole() async {
    setState(() => _loadingRole = true);
    try {
      final u = await db.collection('users').doc(widget.userId).get();
      final role = (u.data()?['role'] as String?)?.toLowerCase() ?? 'user';
      setState(() {
        _isAdmin = role == 'admin';
        _isProducer = role == 'producer';
        _loadingRole = false;
      });
    } catch (_) {
      setState(() => _loadingRole = false);
    }
  }

  // ---------- Helpers ----------
  String _slugify(String s) {
    const trMap = {
      'İ': 'I', 'I': 'I', 'Ş': 'S', 'Ğ': 'G', 'Ü': 'U', 'Ö': 'O', 'Ç': 'C',
      'ı': 'i', 'ş': 's', 'ğ': 'g', 'ü': 'u', 'ö': 'o', 'ç': 'c',
    };
    final replaced = s.trim().split('').map((c) => trMap[c] ?? c).join();
    final lower = replaced.toLowerCase();
    final keep = RegExp(r'[a-z0-9]+');
    final parts = keep.allMatches(lower).map((m) => m.group(0)!).toList();
    final slug = parts.join('_').replaceAll(RegExp(r'_+'), '_');
    return slug.isEmpty ? 'urun_${DateTime.now().millisecondsSinceEpoch}' : slug;
  }

  // ---------- Dialog (Ekle / Düzenle) ----------
  Future<void> _openEditDialog({DocumentSnapshot<Map<String, dynamic>>? doc}) async {
    final isEditing = doc != null;
    final data = doc?.data();

    final nameC    = TextEditingController(text: (data?['productName'] ?? '') as String);
    final perTrayC = TextEditingController(text: ((data?['perTray'] as num?)?.toInt() ?? 12).toString());
    final traysC   = TextEditingController(text: ((data?['trays']   as num?)?.toInt() ?? 0).toString());
    final unitsC   = TextEditingController(text: ((data?['units']   as num?)?.toInt() ?? 0).toString());

    bool autoCalcUnits = true; // trays/perTray değişince units = trays * perTray

    int _toInt(TextEditingController c, {int def = 0}) => int.tryParse(c.text.trim()) ?? def;

    void _recalcUnitsIfNeeded() {
      if (!autoCalcUnits) return;
      final perTray = max(0, _toInt(perTrayC, def: 0));
      final trays   = max(0, _toInt(traysC, def: 0));
      unitsC.text   = (perTray * trays).toString();
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            void recalc() => setLocal(_recalcUnitsIfNeeded);

            return AlertDialog(
              backgroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: gold),
              ),
              title: Text(
                isEditing ? 'Ürünü Düzenle' : 'Yeni Ürün',
                style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // productName
                    TextField(
                      controller: nameC,
                      enabled: !isEditing, // doc id = slug sabit kalsın, rename ayrı iş
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Ürün Adı',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: Simit',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // perTray
                    TextField(
                      controller: perTrayC,
                      onChanged: (_) => recalc(),
                      keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '1 tava = kaç adet? (perTray)',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: 12',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // trays + units row
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: traysC,
                            onChanged: (_) => recalc(),
                            keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Tava (trays)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: 'Örn: 3',
                              hintStyle: TextStyle(color: Colors.white38),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: unitsC,
                            enabled: !autoCalcUnits, // auto açıkken elle oynatma
                            keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Adet (units)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: 'Örn: 36',
                              hintStyle: TextStyle(color: Colors.white38),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(
                          child: Text('Adet = Tava × perTray', style: TextStyle(color: Colors.white70)),
                        ),
                        Switch(
                          value: autoCalcUnits,
                          onChanged: (v) {
                            setLocal(() {
                              autoCalcUnits = v;
                              _recalcUnitsIfNeeded();
                            });
                          },
                          activeColor: gold,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                if (isEditing && _isAdmin)
                  TextButton(
                    onPressed: () async {
                      try {
                        await doc!.reference.delete();
                        if (context.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Silinemedi: $e')),
                          );
                        }
                      }
                    },
                    child: const Text('Sil', style: TextStyle(color: Colors.redAccent)),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('İptal', style: TextStyle(color: Colors.white70)),
                ),
                TextButton(
                  onPressed: () async {
                    final name    = nameC.text.trim();
                    final perTray = max(0, int.tryParse(perTrayC.text.trim()) ?? 0);
                    final trays   = max(0, int.tryParse(traysC.text.trim()) ?? 0);
                    final units   = max(0, int.tryParse(unitsC.text.trim()) ?? 0);

                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ürün adı boş olamaz')),
                      );
                      return;
                    }
                    if (perTray <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('perTray 1 veya daha büyük olmalı')),
                      );
                      return;
                    }

                    final int finalUnits = autoCalcUnits ? perTray * trays : units;

                    try {
                      if (isEditing) {
                        // Var olan kalıcı dokümanı güncelle
                        await doc!.reference.set({
                          'perTray': perTray,
                          'trays': trays,
                          'units': max(0, finalUnits),
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));
                      } else {
                        // Yeni ürün: doc id = slug (GÜNLÜK DEĞİL)
                        final slug = _slugify(name);
                        final ref  = db.collection('production').doc(slug);
                        final exists = (await ref.get()).exists;

                        if (!exists) {
                          await ref.set({
                            'productName': name,
                            'productSlug': slug,
                            'perTray': perTray,
                            'trays': trays,
                            'units': max(0, finalUnits),
                            'createdAt': FieldValue.serverTimestamp(),
                            'updatedAt': FieldValue.serverTimestamp(),
                            'createdBy': auth.currentUser?.uid,
                          });
                        } else {
                          // Varsa üzerine güncelle (createdAt’i bozma)
                          await ref.set({
                            'productName': name,
                            'productSlug': slug,
                            'perTray': perTray,
                            'trays': trays,
                            'units': max(0, finalUnits),
                            'updatedAt': FieldValue.serverTimestamp(),
                          }, SetOptions(merge: true));
                        }
                      }
                      if (context.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Kaydedilemedi: $e')),
                        );
                      }
                    }
                  },
                  child: const Text('Kaydet', style: TextStyle(color: gold)),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isEditing ? 'Güncellendi' : 'Eklendi')),
      );
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final q = db
        .collection('production')
        .orderBy('productName'); // günlük filtre YOK → kalıcı liste

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text('Üretim Yönetimi', style: TextStyle(color: gold, fontWeight: FontWeight.bold)),
        actions: [
          if (_isAdmin || _isProducer)
            IconButton(
              tooltip: 'Yeni Ürün',
              onPressed: () => _openEditDialog(),
              icon: const Icon(Icons.add_box, color: gold),
            ),
          IconButton(
            tooltip: 'Rolü yenile',
            onPressed: _fetchRole,
            icon: const Icon(Icons.refresh, color: gold),
          ),
        ],
      ),
      body: _loadingRole
          ? const Center(child: CircularProgressIndicator(color: gold))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Hata: ${snap.error}', style: const TextStyle(color: Colors.redAccent)),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: gold));
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Henüz ürün eklenmemiş', style: TextStyle(color: gold)),
            );
          }

          // Toplamlar
          int totalTrays = 0;
          int totalUnits = 0;
          for (final d in docs) {
            final m = d.data();
            totalTrays += (m['trays'] as num? ?? 0).toInt();
            totalUnits += (m['units'] as num? ?? 0).toInt();
          }

          return Column(
            children: [
              // Özet
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: gold),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Toplam Tava: $totalTrays',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Toplam Adet: $totalUnits',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),

              // Liste
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = docs[i].data();
                    final name   = (m['productName'] ?? '-') as String;
                    final perTray= (m['perTray'] as num? ?? 0).toInt();
                    final trays  = (m['trays']   as num? ?? 0).toInt();
                    final units  = (m['units']   as num? ?? 0).toInt();

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: gold, width: 1),
                      ),
                      child: Row(
                        children: [
                          // Sol
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: -8,
                                  children: [
                                    _chip('1 tava = $perTray'),
                                    _chip('Tava: $trays'),
                                    _chip('Adet: $units'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Sağ: Edit (sadece yetkililer)
                          if (_isAdmin || _isProducer)
                            IconButton(
                              tooltip: 'Düzenle',
                              icon: const Icon(Icons.edit, color: gold),
                              onPressed: () => _openEditDialog(doc: docs[i]),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: gold),
        color: Colors.black,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }
}
