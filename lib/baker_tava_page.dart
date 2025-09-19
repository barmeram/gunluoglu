// ============================
// FILE: baker_tava_page.dart
// ============================
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BakerTavaPage extends StatefulWidget {
  const BakerTavaPage({super.key, required this.userId});
  final String userId;

  @override
  State<BakerTavaPage> createState() => _BakerTavaPageState();
}

class _BakerTavaPageState extends State<BakerTavaPage> {
  final db = FirebaseFirestore.instance;
  final auth = FirebaseAuth.instance;

  // --- Rol / erişim ---
  bool _loadingRole = true;
  bool _hasAccess = false; // only producer || admin
  String? _roleText;

  // --- Geçici seçimler (alt bar) ---
  final Map<String, int> _pendingTrays = {}; // productName -> delta trays
  final Map<String, int> _pendingUnits = {}; // productName -> delta units
  bool _saving = false;

  // --- Katalog metası (sabit ürünlerden) ---
  // productName -> meta (ref, perTray, slug)
  Map<String, _ProdMeta> _metaByName = {};

  @override
  void initState() {
    super.initState();
    _checkRole();
  }

  Future<void> _checkRole() async {
    setState(() {
      _loadingRole = true;
      _hasAccess = false;
      _roleText = null;
    });

    final user = auth.currentUser;
    if (user == null) {
      setState(() {
        _loadingRole = false;
        _hasAccess = false;
        _roleText = 'no-auth';
      });
      return;
    }

    try {
      final doc = await db.collection('users').doc(user.uid).get();
      final role = (doc.data()?['role'] as String?)?.toLowerCase();
      setState(() {
        _roleText = role ?? '(yok)';
        _hasAccess = role == 'producer' || role == 'admin';
        _loadingRole = false;
      });
    } catch (e) {
      setState(() {
        _loadingRole = false;
        _hasAccess = false;
        _roleText = 'error';
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rol okunamadı: $e')),
      );
    }
  }

  // ---- Helpers ----
  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  // Kataloğun slug'ı yoksa güvenli fallback
  String _slugifyFallback(String s) {
    const trMap = {
      'İ': 'I', 'I': 'I', 'Ş': 'S', 'Ğ': 'G', 'Ü': 'U', 'Ö': 'O', 'Ç': 'C',
      'ı': 'i', 'ş': 's', 'ğ': 'g', 'ü': 'u', 'ö': 'o', 'ç': 'c',
    };
    final replaced = s.trim().split('').map((c) => trMap[c] ?? c).join();
    final lower = replaced.toLowerCase();
    final keep = RegExp(r'[a-z0-9]+');
    final parts = keep.allMatches(lower).map((m) => m.group(0)!).toList();
    final slug = parts.join('_');
    return slug.isEmpty ? 'urun_${DateTime.now().millisecondsSinceEpoch}' : slug;
  }

  void _setPending(String name, int trays, int units) {
    setState(() {
      if (trays <= 0 && units <= 0) {
        _pendingTrays.remove(name);
        _pendingUnits.remove(name);
      } else {
        _pendingTrays[name] = trays;
        _pendingUnits[name] = units;
      }
    });
  }

  void _updateTrays({_ProdMeta? meta, required int delta}) {
    if (meta == null || delta == 0) return;
    final name = meta.productName;
    final perTray = meta.perTray;

    final curTrays = _pendingTrays[name] ?? 0;
    final curUnits = _pendingUnits[name] ?? 0;

    var newTrays = curTrays + delta;
    if (newTrays < 0) newTrays = 0;

    var newUnits = curUnits + delta * perTray;
    if (newUnits < 0) newUnits = 0;

    _setPending(name, newTrays, newUnits);
  }

  void _updateUnits({_ProdMeta? meta, required int delta}) {
    if (meta == null || delta == 0) return;
    final name = meta.productName;

    final curTrays = _pendingTrays[name] ?? 0;
    final curUnits = _pendingUnits[name] ?? 0;

    var newUnits = curUnits + delta;
    if (newUnits < 0) newUnits = 0;

    _setPending(name, curTrays, newUnits);
  }

  int get _totalTrays => _pendingTrays.values.fold(0, (a, b) => a + b);
  int get _totalUnits => _pendingUnits.values.fold(0, (a, b) => a + b);

  void _clearAll() {
    setState(() {
      _pendingTrays.clear();
      _pendingUnits.clear();
    });
  }

  // ---- Firestore yaz (GÜNLÜK kayıtlar → production_daily) ----
  Future<void> _commitToFirestore() async {
    if (!_hasAccess) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yetki yok: Producer veya Admin hesabıyla giriş yapın.')),
      );
      return;
    }
    if (_pendingTrays.isEmpty && _pendingUnits.isEmpty) return;
    if (_saving) return;

    final user = auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Oturum bulunamadı.')),
      );
      return;
    }

    setState(() => _saving = true);

    final today = _todayKey();
    final batch = db.batch();

    final allNames = <String>{..._pendingTrays.keys, ..._pendingUnits.keys};
    for (final name in allNames) {
      final traysDelta = _pendingTrays[name] ?? 0;
      final unitsDelta = _pendingUnits[name] ?? 0;
      if (traysDelta <= 0 && unitsDelta <= 0) continue;

      final meta = _metaByName[name];
      final perTray = meta?.perTray ?? 1;
      final slug = (meta?.productSlug?.isNotEmpty ?? false)
          ? meta!.productSlug
          : _slugifyFallback(name);

      // 🔑 Günlük kayıt ayrı koleksiyona gider
      final ref = db.collection('production_daily').doc("${today}__${slug}");

      batch.set(
        ref,
        {
          'date': today,
          'productName': name,
          'productSlug': slug,
          'perTray': perTray,
          'trays': FieldValue.increment(traysDelta),
          'units': FieldValue.increment(unitsDelta),
          'updatedAt': FieldValue.serverTimestamp(),
          'createdBy': user.uid,
        },
        SetOptions(merge: true),
      );
    }

    try {
      await batch.commit();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Günlük veriler kaydedildi ✅')),
      );
      _clearAll();
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kaydetme hatası: ${e.code} — ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kaydetme hatası: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);

    // 🔑 Ürünleri sabit KATALOĞUN kendisinden çekiyoruz (tarih filtresi yok)
    final q = db.collection('production').orderBy('productName');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: Text(
          _loadingRole
              ? 'Üretici • Tava'
              : _hasAccess
              ? 'Üretici • Tava'
              : 'Erişim yok (${_roleText ?? "?"})',
          style: const TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Rolü yenile',
            onPressed: _checkRole,
            icon: const Icon(Icons.refresh, color: gold),
          ),
        ],
      ),
      body: _loadingRole
          ? const Center(child: CircularProgressIndicator(color: gold))
          : !_hasAccess
          ? const _LockedView()
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('Hata: ${snap.error}', style: const TextStyle(color: Colors.redAccent)),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: gold));
          }

          final docs = snap.data!.docs;

          final newMeta = <String, _ProdMeta>{};
          for (final d in docs) {
            final m = d.data();
            final name = (m['productName'] as String?)?.trim() ?? '';
            if (name.isEmpty) continue;
            final perTray = ((m['perTray'] as num?) ?? 1).toInt();
            final slugRaw = (m['productSlug'] as String?)?.trim() ?? '';
            final slug = slugRaw.isEmpty ? _slugifyFallback(name) : slugRaw;
            newMeta[name] = _ProdMeta(
              productName: name,
              productSlug: slug,
              perTray: perTray,
              ref: d.reference,
            );
          }
          _metaByName = newMeta;

          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Henüz ürün yok. ProductionManagePage’den ekleyin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFFFD700)),
                ),
              ),
            );
          }

          final all = _metaByName.values.toList()
            ..sort((a, b) => a.productName.compareTo(b.productName));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: all.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final meta = all[i];
              final name = meta.productName;
              final trays = _pendingTrays[name] ?? 0;
              final units = _pendingUnits[name] ?? 0;

              return _productRow(
                meta: meta,
                trays: trays,
                units: units,
                onTrayMinus: () => _updateTrays(meta: meta, delta: -1),
                onTrayPlus: () => _updateTrays(meta: meta, delta: 1),
                onUnitMinus: () => _updateUnits(meta: meta, delta: -1),
                onUnitPlus: () => _updateUnits(meta: meta, delta: 1),
                onClear: () => _setPending(name, 0, 0),
              );
            },
          );
        },
      ),
      bottomNavigationBar: (!_hasAccess || (_pendingTrays.isEmpty && _pendingUnits.isEmpty))
          ? null
          : SafeArea(
        child: Container(
          color: Colors.grey[900],
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "Toplam: $_totalTrays tava • $_totalUnits adet",
                  style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              TextButton(
                onPressed: _saving ? null : _clearAll,
                child: const Text("Temizle", style: TextStyle(color: Colors.white70)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: gold,
                  foregroundColor: Colors.black,
                ),
                onPressed: _saving ? null : _commitToFirestore,
                icon: _saving
                    ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                )
                    : const Icon(Icons.check),
                label: Text(_saving ? "Kaydediliyor..." : "Onayla"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _productRow({
    required _ProdMeta meta,
    required int trays,
    required int units,
    required VoidCallback onTrayMinus,
    required VoidCallback onTrayPlus,
    required VoidCallback onUnitMinus,
    required VoidCallback onUnitPlus,
    required VoidCallback onClear,
  }) {
    const gold = Color(0xFFFFD700);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: gold, width: 1),
      ),
      child: Row(
        children: [
          // Sol: ürün adı + perTray
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(meta.productName, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text("1 tava = ${meta.perTray} adet", style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          // Orta: TAVA - [tava sayısı] +
          Flexible(
            flex: 5,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                children: [
                  _roundBtn(icon: Icons.remove, onTap: onTrayMinus),
                  const SizedBox(width: 6),
                  Text("$trays tava", style: const TextStyle(color: Colors.white)),
                  const SizedBox(width: 6),
                  _roundBtn(icon: Icons.add, onTap: onTrayPlus),
                ],
              ),
            ),
          ),
          // Sağ: adet + sil
          Expanded(
            flex: 6,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                children: [
                  const Text("Adet ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  _roundBtn(icon: Icons.remove, onTap: onUnitMinus),
                  const SizedBox(width: 6),
                  Text("$units", style: const TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(width: 6),
                  _roundBtn(icon: Icons.add, onTap: onUnitPlus),
                  const SizedBox(width: 10),
                  InkWell(onTap: onClear, child: const Icon(Icons.delete_outline, color: Colors.white70)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundBtn({required IconData icon, required VoidCallback onTap}) {
    const gold = Color(0xFFFFD700);
    return Ink(
      decoration: const ShapeDecoration(
        color: Colors.black,
        shape: CircleBorder(side: BorderSide(color: gold)),
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: gold),
        splashRadius: 18,
        iconSize: 18,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

// ---- İç meta modeli ----
class _ProdMeta {
  final String productName;
  final String productSlug;
  final int perTray;
  final DocumentReference<Map<String, dynamic>> ref;

  _ProdMeta({
    required this.productName,
    required this.productSlug,
    required this.perTray,
    required this.ref,
  });
}

class _LockedView extends StatelessWidget {
  const _LockedView({super.key});
  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.lock_outline, color: gold, size: 40),
            SizedBox(height: 12),
            Text(
              "Bu sayfayı sadece 'producer' rolündeki kullanıcılar (ve admin) kullanabilir.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
