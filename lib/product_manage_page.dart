import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProductManagePage extends StatefulWidget {
  const ProductManagePage({
    super.key,
    required this.currentUid,
  });

  final String currentUid;

  @override
  State<ProductManagePage> createState() => _ProductManagePageState();
}

class _ProductManagePageState extends State<ProductManagePage> {
  final db = FirebaseFirestore.instance;

  bool _loadingRole = true;
  bool _isAdmin = false;
  bool _isBaker = false;

  @override
  void initState() {
    super.initState();
    _fetchRole();
  }

  Future<void> _fetchRole() async {
    try {
      final u = await db.collection('users').doc(widget.currentUid).get();
      final role = (u.data()?['role'] as String?) ?? 'user';
      setState(() {
        _isAdmin = role == 'admin';
        _isBaker = role == 'baker';
        _loadingRole = false;
      });
    } catch (_) {
      setState(() => _loadingRole = false);
    }
  }

  // Küçük yardımcılar
  String _slugify(String s) {
    final trMap = {
      'İ':'I','I':'I','Ş':'S','Ğ':'G','Ü':'U','Ö':'O','Ç':'C',
      'ı':'i','ş':'s','ğ':'g','ü':'u','ö':'o','ç':'c',
    };
    final replaced = s.trim().split('').map((c) => trMap[c] ?? c).join();
    final lower = replaced.toLowerCase();
    final keep = RegExp(r'[a-z0-9]+');
    final parts = keep.allMatches(lower).map((m) => m.group(0)!).toList();
    final slug = parts.join('_');
    return slug.isEmpty ? 'urun_${DateTime.now().millisecondsSinceEpoch}' : slug;
  }

  Future<void> _openNewProductDialog() async {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sadece admin yeni ürün ekleyebilir.')),
      );
      return;
    }
    await _openEditDialog();
  }

  Future<void> _openEditDialog({DocumentSnapshot<Map<String,dynamic>>? doc}) async {
    final isEditing = doc != null;
    final data = doc?.data();

    final nameC = TextEditingController(text: (data?['name'] ?? '') as String);
    final priceC = TextEditingController(
      text: (data?['price'] as num?)?.toString() ?? '',
    );
    final pricePerKgC = TextEditingController(
      text: (data?['pricePerKg'] as num?)?.toString() ?? '',
    );
    bool isWeighted = (data?['isWeighted'] as bool?) ?? false;

    // 🔹 YENİ: productionName (tek stok bağlantısı için)
    // Mevcutta yoksa ürün adıyla dolduruyoruz (örn: "Simit" -> production.productName "Simit")
    final productionNameC = TextEditingController(
      text: (data?['productionName'] as String?) ??
          (data?['name'] as String?) ??
          '',
    );

    // Baker ise bazı alanları kilitle (kurallarda create yok, delete yok)
    final canEditAll = _isAdmin;
    final canEditPriceOnly = _isBaker && !_isAdmin;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        const gold = Color(0xFFFFD700);
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: gold),
              ),
              title: Text(
                isEditing ? 'Ürün Düzenle' : 'Yeni Ürün',
                style: const TextStyle(color: gold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Ürün adı
                    TextField(
                      controller: nameC,
                      enabled: canEditAll && !isEditing, // admin: eklerken isim serbest, düzenlerken id bozmasın
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Ürün adı',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: Simit',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 🔹 YENİ: productionName (stok bağlama anahtarı)
                    // production.productName ile bire bir aynı olmalı (örn: "Simit", "Kaşarlı Börek")
                    TextField(
                      controller: productionNameC,
                      enabled: canEditAll, // sadece admin değiştirir
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Stok Adı (productionName)',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: Simit — production.productName ile aynı yaz',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),

                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Satış Tipi: ${isWeighted ? "Kg" : "Adet"}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                        Switch(
                          value: isWeighted,
                          onChanged: canEditAll
                              ? (v) => setLocal(() => isWeighted = v)
                              : null, // baker değiştiremez
                          activeColor: gold,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (!isWeighted) ...[
                      TextField(
                        controller: priceC,
                        enabled: canEditAll || canEditPriceOnly,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Fiyat (adet)',
                          labelStyle: TextStyle(color: Colors.white70),
                          hintText: 'Örn: 15',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ] else ...[
                      TextField(
                        controller: pricePerKgC,
                        enabled: canEditAll || canEditPriceOnly,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Fiyat / kg',
                          labelStyle: TextStyle(color: Colors.white70),
                          hintText: 'Örn: 120',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ],
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
                    final name = nameC.text.trim();
                    final price = double.tryParse(priceC.text.replaceAll(',', '.'));
                    final ppk = double.tryParse(pricePerKgC.text.replaceAll(',', '.'));
                    final productionName = productionNameC.text.trim().isEmpty
                        ? name
                        : productionNameC.text.trim();

                    // Doğrulamalar
                    if (!isEditing && name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('İsim boş olamaz')),
                      );
                      return;
                    }
                    if (!isWeighted && (price == null || price <= 0)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Geçerli bir adet fiyatı girin')),
                      );
                      return;
                    }
                    if (isWeighted && (ppk == null || ppk <= 0)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Geçerli bir kg fiyatı girin')),
                      );
                      return;
                    }

                    try {
                      if (isEditing) {
                        // UPDATE
                        final Map<String, dynamic> upd = {
                          'updatedAt': FieldValue.serverTimestamp(),
                        };

                        if (canEditAll) {
                          upd['isWeighted'] = isWeighted;

                          // adı güvenli güncelle (id bozulmasın diye düzenlemede genelde sabit)
                          final String oldName = data != null ? (data['name'] as String? ?? '') : '';
                          upd['name'] = (oldName == name) ? oldName : name;

                          // 🔹 stok eşleşmesi (sadece admin değiştirir)
                          upd['productionName'] = productionName;
                        }

                        if (isWeighted) {
                          upd['pricePerKg'] = ppk;
                          upd['price'] = null;
                        } else {
                          upd['price'] = price;
                          upd['pricePerKg'] = null;
                        }

                        await doc!.reference.set(upd, SetOptions(merge: true));
                      } else {
                        // CREATE (sadece admin)
                        final id = _slugify(name);
                        final ref = db.collection('products').doc(id);
                        await ref.set({
                          'name': name,
                          'isWeighted': isWeighted,
                          'price': isWeighted ? null : price,
                          'pricePerKg': isWeighted ? ppk : null,
                          // 🔹 stok bağlantısı
                          'productionName': productionName,
                          'createdAt': FieldValue.serverTimestamp(),
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: false));
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
                  child: const Text('Kaydet', style: TextStyle(color: Color(0xFFFFD700))),
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

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final productsQuery = db.collection('products');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text('Pos Ürün Yönetimi', style: TextStyle(color: gold)),
        actions: [
          if (_isAdmin)
            IconButton(
              tooltip: 'Yeni Ürün',
              onPressed: _openNewProductDialog,
              icon: const Icon(Icons.add_box, color: gold),
            ),
        ],
      ),
      body: _loadingRole
          ? const Center(child: CircularProgressIndicator(color: gold))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: productsQuery.snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Hata: ${snap.error}',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: gold));
          }

          var docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Ürün yok', style: TextStyle(color: gold)),
            );
          }

          // İsimle basit sıralama
          docs.sort((a, b) {
            final na = ((a.data()['name'] ?? '') as String).toLowerCase();
            final nb = ((b.data()['name'] ?? '') as String).toLowerCase();
            return na.compareTo(nb);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final d = docs[i].data();
              final name = (d['name'] ?? '-') as String;
              final isWeighted = (d['isWeighted'] ?? false) as bool;
              final price = (d['price'] as num?)?.toDouble();
              final pricePerKg = (d['pricePerKg'] as num?)?.toDouble();
              final productionName = (d['productionName'] as String?) ?? ''; // 🔹 gösterim için okuyalım

              final subtitlePrice = isWeighted
                  ? '₺${(pricePerKg ?? 0).toStringAsFixed(2)} / kg'
                  : '₺${(price ?? 0).toStringAsFixed(2)}';

              return Card(
                color: Colors.grey[900],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: gold),
                ),
                child: ListTile(
                  title: Text(
                    name,
                    style: const TextStyle(
                      color: gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(subtitlePrice, style: const TextStyle(color: Colors.white70)),
                      if (productionName.isNotEmpty)
                        Text(
                          'Stok: $productionName',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit, color: gold),
                    tooltip: _isAdmin
                        ? 'Düzenle/Sil'
                        : (_isBaker ? 'Fiyatı Düzenle' : 'Görüntüle'),
                    onPressed: () => _openEditDialog(doc: docs[i]),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
