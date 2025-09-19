// ===================================
// FILE: admin_daily_picker_page.dart
// ===================================

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ✅ kalıcılık
import 'package:gunluogluproje/baker_stock_page.dart';

class AdminDailyPickerPage extends StatefulWidget {
  const AdminDailyPickerPage({super.key, required this.userId});
  final String userId;

  @override
  State<AdminDailyPickerPage> createState() => _AdminDailyPickerPageState();
}

class _AdminDailyPickerPageState extends State<AdminDailyPickerPage> {
  final db = FirebaseFirestore.instance;
  static const gold = Color(0xFFFFD700);

  static const _prefsKeySelectedDay = 'admin_daily_picker_selected_day';

  // Son N gün listesi
  late final List<String> _last3 = _computeLastNDays(3);

  // Ekran seçimi
  String _selectedDay = '';

  @override
  void initState() {
    super.initState();
    _selectedDay = _last3.first; // varsayılan bugün
    _loadSelectedDayFromPrefs(); // ✅ varsa önceki seçimi yükle
  }

  List<String> _computeLastNDays(int n) {
    final now = DateTime.now();
    return List.generate(n, (i) {
      final d = DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
    });
  }

  Future<void> _loadSelectedDayFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKeySelectedDay);
    if (!mounted) return;
    if (saved != null && _last3.contains(saved)) {
      setState(() => _selectedDay = saved);
    }
  }

  Future<void> _saveSelectedDayToPrefs(String day) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeySelectedDay, day);
  }

  List<Map<String, dynamic>> _aggregateDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) {
    final Map<String, Map<String, dynamic>> agg = {};
    for (final d in docs) {
      final m = d.data();
      final name = (m['productName'] as String?)?.trim();
      if (name == null || name.isEmpty) continue;

      final perTray = (m['perTray'] as num?)?.toInt() ?? 1;
      final trays   = (m['trays']   as num?)?.toInt() ?? 0;
      final units   = (m['units']   as num?)?.toInt() ?? 0;

      final rec = agg[name] ?? {
        'productName': name,
        'perTray': perTray,
        'trays': 0,
        'units': 0,
      };

      rec['trays'] = (rec['trays'] as int) + trays;
      rec['units'] = (rec['units'] as int) + units;
      agg[name] = rec;
    }

    final list = agg.values.toList()
      ..sort((a, b) => (a['productName'] as String).compareTo(b['productName'] as String));
    return list;
  }

  void _gotoBakerStock(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu günde veri yok.')),
      );
      return;
    }

    // ✅ çıkmadan kaydet
    await _saveSelectedDayToPrefs(_selectedDay);

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BakerStockPage(
          userId: widget.userId,
          day: _selectedDay,          // <- SEÇTİĞİN GÜN ZORUNLU GÖNDERİLİYOR
          initialItems: items,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chips = _last3.map((d) {
      final sel = d == _selectedDay;
      return ChoiceChip(
        label: Text(d, style: const TextStyle(fontSize: 12)),
        selected: sel,
        onSelected: (_) async {
          setState(() => _selectedDay = d);
          await _saveSelectedDayToPrefs(_selectedDay); // ✅ her seçimde kaydet
        },
        selectedColor: gold.withOpacity(0.25),
        backgroundColor: const Color(0xFF1A1A1A),
        labelStyle: const TextStyle(color: Colors.white),
        side: const BorderSide(color: Color(0x33FFD700)),
      );
    }).toList();

    // 🔑 GÜNLÜK veriler production_daily'de
    final dayStream = db
        .collection('production_daily')
        .where('date', isEqualTo: _selectedDay)
        .snapshots();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text(
          'Gün Seç • Son 3 Gün',
          style: TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
      ),

      body: Column(
        children: [
          // gün çipleri
          Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Wrap(spacing: 8, children: chips),
          ),

          // canlı içerik
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              key: ValueKey(_selectedDay),
              stream: dayStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Hata: ${snap.error}',
                          style: const TextStyle(color: Colors.redAccent)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: gold),
                  );
                }

                final docs = snap.data!.docs;
                final items = _aggregateDocs(docs);

                int totalTrays = 0, totalUnits = 0;
                for (final m in items) {
                  totalTrays += (m['trays'] as int?) ?? 0;
                  totalUnits += (m['units'] as int?) ?? 0;
                }

                if (items.isEmpty) {
                  return const Center(
                    child: Text('Veri yok', style: TextStyle(color: gold)),
                  );
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
                          Expanded(
                            child: Text('Toplam Tava: $totalTrays',
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                          Expanded(
                            child: Text('Toplam Adet: $totalUnits',
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),

                    // Liste
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final m = items[i];
                          final name  = m['productName'] as String;
                          final trays = (m['trays'] as int?) ?? 0;
                          final units = (m['units'] as int?) ?? 0;
                          final pt    = (m['perTray'] as int?) ?? 1;

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: gold, width: 1),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(name,
                                          style: const TextStyle(
                                              color: gold, fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 4),
                                      Text("1 tava = $pt adet",
                                          style: const TextStyle(
                                              color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                _pill('Tava', trays.toString()),
                                const SizedBox(width: 8),
                                _pill('Adet', units.toString()),
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
          ),
        ],
      ),

      // Alt bar
      bottomNavigationBar: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          key: ValueKey("bottom-$_selectedDay"),
          stream: dayStream,
          builder: (context, snap) {
            final hasData = snap.hasData && snap.data!.docs.isNotEmpty;
            final items = hasData
                ? _aggregateDocs(snap.data!.docs)
                : const <Map<String, dynamic>>[];

            return Container(
              padding: const EdgeInsets.all(12),
              color: Colors.grey[900],
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: items.isEmpty ? null : () => _gotoBakerStock(items),
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Seçilen Günü Baker Stok’a Gönder'),
              ),
            );
          },
        ),
      ),
    );
  }

  // küçük pill
  Widget _pill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: gold),
        color: Colors.black,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(value, style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }
}
