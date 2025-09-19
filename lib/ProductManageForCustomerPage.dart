import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProductManageForCustomerPage extends StatefulWidget {
  const ProductManageForCustomerPage({super.key});

  @override
  State<ProductManageForCustomerPage> createState() =>
      _ProductManageForCustomerPageState();
}

class _ProductManageForCustomerPageState
    extends State<ProductManageForCustomerPage> {
  final db = FirebaseFirestore.instance;

  static const gold = Color(0xFFFFD700);
  static const String kCustomerProducts = 'customer_products';

  // Slug helper
  String _slugify(String s) {
    final trMap = {
      'İ': 'I',
      'I': 'I',
      'Ş': 'S',
      'Ğ': 'G',
      'Ü': 'U',
      'Ö': 'O',
      'Ç': 'C',
      'ı': 'i',
      'ş': 's',
      'ğ': 'g',
      'ü': 'u',
      'ö': 'o',
      'ç': 'c',
    };
    final replaced =
    s.trim().split('').map((c) => trMap[c] ?? c).join();
    final lower = replaced.toLowerCase();
    final keep = RegExp(r'[a-z0-9]+');
    final parts =
    keep.allMatches(lower).map((m) => m.group(0)!).toList();
    final slug = parts.join('_');
    return slug.isEmpty
        ? 'urun_${DateTime.now().millisecondsSinceEpoch}'
        : slug;
  }

  // ============================================
  // Dialog (Ekle / Düzenle)
  // ============================================
  Future<void> _openProductDialog(
      {DocumentSnapshot<Map<String, dynamic>>? doc}) async {
    final isEditing = doc != null;
    final data = doc?.data();

    final nameC =
    TextEditingController(text: (data?['name'] ?? '') as String);
    final priceC = TextEditingController(
        text: (data?['price'] as num?)?.toString() ?? '');
    final pricePerKgC = TextEditingController(
        text: (data?['pricePerKg'] as num?)?.toString() ?? '');
    final salePriceC = TextEditingController(
        text: (data?['salePrice'] as num?)?.toString() ?? '');
    final productionNameC = TextEditingController(
      text: (data?['productionName'] as String?) ??
          (data?['name'] as String? ?? ''),
    );
    bool isWeighted = (data?['isWeighted'] as bool?) ?? false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: gold),
              ),
              title: Text(
                  isEditing ? 'Dışarı Ürün Düzenle' : 'Yeni Ürün',
                  style: const TextStyle(color: gold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameC,
                      enabled: !isEditing,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Ürün adı',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: Simit',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: productionNameC,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Stok Adı (productionName)',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: Simit — production.productName ile aynı',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                              'Satış Tipi: ${isWeighted ? "Kg" : "Adet"}',
                              style: const TextStyle(color: Colors.white70)),
                        ),
                        Switch(
                          value: isWeighted,
                          onChanged: isEditing
                              ? null
                              : (v) => setLocal(() => isWeighted = v),
                          activeColor: gold,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (!isWeighted)
                      TextField(
                        controller: priceC,
                        keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Alış Fiyatı (adet)',
                          labelStyle: TextStyle(color: Colors.white70),
                          hintText: 'Örn: 22',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
                      )
                    else
                      TextField(
                        controller: pricePerKgC,
                        keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Alış Fiyatı / kg',
                          labelStyle: TextStyle(color: Colors.white70),
                          hintText: 'Örn: 120',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: salePriceC,
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Satış Fiyatı',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Örn: 25',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (isEditing)
                  TextButton(
                    onPressed: () async {
                      try {
                        await doc!.reference.delete();
                        if (context.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Silinemedi: $e')));
                        }
                      }
                    },
                    child: const Text('Sil',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('İptal',
                      style: TextStyle(color: Colors.white70)),
                ),
                TextButton(
                  onPressed: () async {
                    final name = nameC.text.trim();
                    final price =
                    double.tryParse(priceC.text.replaceAll(',', '.'));
                    final ppk = double.tryParse(
                        pricePerKgC.text.replaceAll(',', '.'));
                    final salePrice =
                    double.tryParse(salePriceC.text.replaceAll(',', '.'));
                    final productionName = productionNameC.text.trim().isEmpty
                        ? name
                        : productionNameC.text.trim();

                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('İsim boş olamaz')));
                      return;
                    }
                    if (!isWeighted && (price == null || price <= 0)) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Geçerli bir adet alış fiyatı girin')));
                      return;
                    }
                    if (isWeighted && (ppk == null || ppk <= 0)) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Geçerli bir kg alış fiyatı girin')));
                      return;
                    }
                    if (salePrice == null || salePrice <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Geçerli bir satış fiyatı girin')));
                      return;
                    }

                    try {
                      if (isEditing) {
                        await doc!.reference.set({
                          'price': isWeighted ? null : price,
                          'pricePerKg': isWeighted ? ppk : null,
                          'salePrice': salePrice,
                          'productionName': productionName,
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));
                      } else {
                        final id = _slugify(name);
                        await db.collection(kCustomerProducts).doc(id).set({
                          'name': name,
                          'isWeighted': isWeighted,
                          'price': isWeighted ? null : price,
                          'pricePerKg': isWeighted ? ppk : null,
                          'salePrice': salePrice,
                          'productionName': productionName,
                          'createdAt': FieldValue.serverTimestamp(),
                          'updatedAt': FieldValue.serverTimestamp(),
                        });
                      }

                      if (context.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Kaydedilemedi: $e')));
                      }
                    }
                  },
                  child:
                  const Text('Kaydet', style: TextStyle(color: gold)),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isEditing ? 'Güncellendi' : 'Eklendi')));
    }
  }

  // ============================================
  // UI
  // ============================================
  @override
  Widget build(BuildContext context) {
    final productsQuery =
    db.collection(kCustomerProducts).orderBy('name');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Dışarı Ürün Yönetimi (Müşteri)',
            style: TextStyle(color: gold)),
        actions: [
          IconButton(
            tooltip: 'Yeni Ürün',
            onPressed: () => _openProductDialog(),
            icon: const Icon(Icons.add_box, color: gold),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: productsQuery.snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('Hata: ${snap.error}',
                  style: const TextStyle(color: Colors.redAccent)),
            );
          }
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: gold));
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
                child: Text('Ürün yok', style: TextStyle(color: gold)));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final d = docs[i].data();
              final name = (d['name'] ?? '-') as String;
              final salePrice =
                  (d['salePrice'] as num?)?.toDouble() ?? 0;
              final buyPrice =
                  (d['price'] as num?)?.toDouble() ??
                      (d['pricePerKg'] as num?)?.toDouble() ??
                      0;
              final productionName =
                  (d['productionName'] as String?) ?? '';

              final subtitle = [
                buyPrice > 0
                    ? 'Alış: ₺${buyPrice.toStringAsFixed(2)}'
                    : 'Alış: tanımsız',
                salePrice > 0
                    ? 'Satış: ₺${salePrice.toStringAsFixed(2)}'
                    : 'Satış: tanımsız',
              ].join('   |   ');

              return Card(
                color: Colors.grey[900],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: gold),
                ),
                child: ListTile(
                  title: Text(name,
                      style: const TextStyle(
                          color: gold, fontWeight: FontWeight.w600)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(subtitle,
                          style: const TextStyle(color: Colors.white70)),
                      if (productionName.isNotEmpty)
                        Text('Stok: $productionName',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit, color: gold),
                    tooltip: 'Düzenle/Sil',
                    onPressed: () =>
                        _openProductDialog(doc: docs[i]),
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
