// users_page.dart (UsersPage)
// ✅ AppBar’dan “Ürün Yönetimi (POS)” ve “Dışarı Ürünler” ikonları kaldırıldı
// ✅ endDrawer menüsünde zaten her ikisi de mevcut
// ✅ Hızlı Menüye: “Üretimin Ürünü Düzenle” eklendi (ProductionManagePage’e gider)
// ✅ Kullanıcı listesinde durum göstergesi: yeşil=aktif, kırmızı=engelli (isActive)
// ✅ Admin: Kullanıcıyı engelle / engeli kaldır (isActive toggle)
// ✅ Hızlı Menüye: Stok (Gün Seç) eklendi → AdminDailyPickerPage
// Not: Dışarı Ürünler -> customer_products koleksiyonunu yönetir (ProductManageForCustomerPage)

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Sayfalar
import 'package:gunluogluproje/CompetitionPage.dart'; // Satış Yarışı sayfası
import 'baker_stock_page.dart';
import 'package:gunluogluproje/AdminDailyPickerPage.dart' hide BakerStockPage; // 🔹 Eklendi: Gün seçerek stok inceleme
import 'user_revenue_page.dart';
import 'pos_page.dart';
import 'all_revenue_page.dart';
import 'register_page.dart';
import 'stock_from_customer_orders_page.dart';
import 'customer_revenue_summary_page.dart'; // Teslim/Hasılat Özeti
import 'product_manage_page.dart'; // Ürün Yönetimi (POS/products)
import 'package:gunluogluproje/ProductManageForCustomerPage.dart'; // Dışarı Ürünler (customer_products)
import 'package:gunluogluproje/production_manage_pageuretım.dart'; // ✅ Üretimin Ürünü Düzenle (production)

// ----------------------------------------------------------------------

class UsersPage extends StatefulWidget {
  const UsersPage({
    super.key,
    required this.currentUid,
    required this.currentRole,
  });

  final String currentUid;   // giriş yapan kullanıcının uid
  final String currentRole;  // admin / user / baker / order / producer

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final db = FirebaseFirestore.instance;
  final _scaffoldKey = GlobalKey<ScaffoldState>(); // 🔑 endDrawer açmak için
  String _q = '';

  // Admin ise herkesi; değilse sadece kendi kaydını dinle (rules hatasını önler)
  Stream<QuerySnapshot<Map<String, dynamic>>> _usersStream() {
    if (widget.currentRole == "admin") {
      return db.collection('users').snapshots();
    }
    return db
        .collection('users')
        .where(FieldPath.documentId, isEqualTo: widget.currentUid)
        .snapshots();
  }

  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  // Bugünün toplam hasılatı (menü üst kısmında göstermek için)
  Stream<num> _todayRevenueStream() {
    final today = _todayKey();
    return db
        .collection('revenues')
        .where('date', isEqualTo: today)
        .snapshots()
        .map((snap) {
      num total = 0;
      for (final d in snap.docs) {
        total += (d.data()['total'] as num?) ?? 0;
      }
      return total;
    });
  }

  // ---------- UI yardımcıları ----------

  Widget _statusDot({required bool isActive}) {
    final color = isActive ? Colors.greenAccent : Colors.redAccent;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.5), blurRadius: 4, spreadRadius: 1),
        ],
      ),
    );
  }

  Widget _leadingAvatar({required String name, required bool isActive}) {
    final initial = (name.trim().isNotEmpty ? name.trim()[0] : '?').toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: Colors.grey[800],
          child: Text(initial, style: const TextStyle(color: Colors.white)),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: _statusDot(isActive: isActive),
        ),
      ],
    );
  }

  Future<void> _toggleBlockUser({
    required String uid,
    required bool isActive,
    required String nameForDialog,
  }) async {
    final wantDisable = isActive; // aktifse tıklayınca engelle
    final title = wantDisable ? "Hesabı Engelle" : "Engeli Kaldır";
    final msg = wantDisable
        ? "$nameForDialog kullanıcısını engellemek istiyor musun? (Giriş yapamaz)"
        : "$nameForDialog kullanıcısının engelini kaldırmak istiyor musun?";

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("İptal")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Tamam")),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await db.collection('users').doc(uid).update({
        'isActive': !wantDisable,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(wantDisable ? "Hesap engellendi" : "Engel kaldırıldı")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("İşlem başarısız: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFD700);
    final isAdmin = widget.currentRole == "admin";

    // 🔹 Yardımcı menü tile
    ListTile menuTile({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon, color: gold),
        title: Text(title, style: const TextStyle(color: gold, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white70)),
        onTap: onTap,
      );
    }

    // 🔹 Sağdan açılan yan menü (endDrawer, sadece admin)
    Widget? endDrawer;
    if (isAdmin) {
      endDrawer = Drawer(
        width: 320,
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              // Üst başlık (FIX: Row artık Container'ın child'ı)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0x33FFD700))),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.menu_open, color: gold),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Admin Hızlı Menü',
                        style: TextStyle(color: gold, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Kapat',
                      icon: const Icon(Icons.close, color: gold),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              // Bugünkü hasılat
              StreamBuilder<num>(
                stream: _todayRevenueStream(),
                builder: (_, snap) {
                  final t = (snap.data ?? 0);
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Row(
                      children: [
                        const Icon(Icons.today, color: gold, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Bugünkü Toplam Hasılat: ₺${t.toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),

              // Menü seçenekleri
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    menuTile(
                      icon: Icons.emoji_events,
                      title: 'Satış Yarışı',
                      subtitle: 'Kullanıcılar arası günlük/haftalık yarış ve sıralama',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const CompetitionPage()));
                      },
                    ),
                    menuTile(
                      icon: Icons.receipt_long,
                      title: 'Siparişten Stok',
                      subtitle: 'Müşteri siparişlerinden türetilmiş stok raporu',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => StockFromCustomerOrdersPage(
                              userId: widget.currentUid,
                              showAll: true,
                            ),
                          ),
                        );
                      },
                    ),
                    menuTile(
                      icon: Icons.summarize,
                      title: 'Teslim/Hasılat Özeti',
                      subtitle: 'Gün/hafta/ay/yıl tahsilat ve teslim özeti',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CustomerRevenueSummaryPage(
                              showAll: true,
                              defaultUserId: widget.currentUid,
                            ),
                          ),
                        );
                      },
                    ),
                    // 🔸 Stoklar (BUGÜN) → BakerStockPage (bugün)
                    menuTile(
                      icon: Icons.inventory,
                      title: 'Stoklar (Bugün)',
                      subtitle: 'Bugünkü fırın stokları ve ürünler',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BakerStockPage(
                              userId: widget.currentUid,
                              dayLabel: _todayKey(), // açıkça bugünü veriyoruz
                            ),
                          ),
                        );
                      },
                    ),
                    // 🔸 STOK (GÜN SEÇ) → AdminDailyPickerPage
                    menuTile(
                      icon: Icons.calendar_month_outlined,
                      title: 'Stok (Gün Seç)',
                      subtitle: 'Belirli bir günü incele / Baker Stok’a gönder',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AdminDailyPickerPage(userId: widget.currentUid),
                          ),
                        );
                      },
                    ),
                    // ✅ YENİ: Üretimin Ürünü Düzenle (production_manage_page.dart)
                    menuTile(
                      icon: Icons.factory_outlined,
                      title: 'Üretimin Ürünü Düzenle',
                      subtitle: 'Günlük üretim kayıtlarını ekle/düzenle/sil',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProductionManagePage(userId: widget.currentUid),
                          ),
                        );
                      },
                    ),
                    // POS/products ürün yönetimi
                    menuTile(
                      icon: Icons.store_mall_directory,
                      title: 'Ürün Yönetimi (POS)',
                      subtitle: 'POS’ta görünen ürünler (products) — fiyat/özellik',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProductManagePage(currentUid: widget.currentUid),
                          ),
                        );
                      },
                    ),
                    // customer_products ürün yönetimi
                    menuTile(
                      icon: Icons.shopping_bag_outlined,
                      title: 'Dışarı Ürünler',
                      subtitle: 'Müşteri tarafı ürünleri (customer_products) — fiyat/özellik',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ProductManageForCustomerPage(),
                          ),
                        );
                      },
                    ),
                    menuTile(
                      icon: Icons.app_registration,
                      title: 'Kayıt Oluştur',
                      subtitle: 'Yeni kullanıcı kaydı oluştur',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage()));
                      },
                    ),
                    menuTile(
                      icon: Icons.bar_chart_outlined,
                      title: 'Tüm Hasılat',
                      subtitle: 'Genel hasılat grafikleri ve özetler',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AllRevenuePage()));
                      },
                    ),
                    menuTile(
                      icon: Icons.point_of_sale,
                      title: 'POS',
                      subtitle: 'Tezgah POS satış ekranı',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => PosSalesPage(userId: widget.currentUid)),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: gold),
        title: const Text(
          'Kullanıcılar',
          style: TextStyle(color: gold, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: 'Hızlı Menü',
              icon: const Icon(Icons.menu_open, color: gold),
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'İsim veya e-posta ara',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: gold),
                filled: true,
                fillColor: Colors.grey[900],
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: gold),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: gold, width: 2),
                ),
              ),
            ),
          ),
        ),
      ),

      endDrawer: endDrawer,

      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _usersStream(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Hata (users): ${snap.error}',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: gold));
          }

          final all = snap.data!.docs;

          // Arama filtresi
          final q = _q.trim().toLowerCase();
          var filtered = all.where((d) {
            final m = d.data();
            final name = (m['name'] ?? '').toString().toLowerCase();
            final email = (m['email'] ?? '').toString().toLowerCase();
            if (q.isEmpty) return true;
            return name.contains(q) || email.contains(q);
          }).toList();

          // Sıralama (önce yeni oluşturulanlar)
          filtered.sort((a, b) {
            final ta = a.data()['createdAt'];
            final tb = b.data()['createdAt'];
            if (ta is Timestamp && tb is Timestamp) {
              return tb.toDate().compareTo(ta.toDate());
            }
            return (a.data()['name'] ?? 'Unknown')
                .toString()
                .toLowerCase()
                .compareTo((b.data()['name'] ?? 'Unknown').toString().toLowerCase());
          });

          if (filtered.isEmpty) {
            return const Center(
              child: Text('Kullanıcı yok', style: TextStyle(color: gold)),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final u = filtered[i];
              final m = u.data();
              final uid = u.id;
              final name = (m['name'] ?? '-').toString();
              final email = (m['email'] ?? '-').toString();
              final bool isActive = (m['isActive'] as bool?) ?? true;

              final canDelete = isAdmin && uid != widget.currentUid;

              return Container(
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isActive ? gold : Colors.redAccent, width: 1),
                ),
                child: ListTile(
                  leading: _leadingAvatar(name: name, isActive: isActive),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UserRevenuePage(uid: uid, name: name, email: email),
                      ),
                    );
                  },
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          name.isEmpty ? uid : name,
                          style: TextStyle(
                            color: isActive ? gold : Colors.redAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      // Küçük bir durum etiketi
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isActive ? Colors.green.withOpacity(0.15) : Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: isActive ? Colors.greenAccent : Colors.redAccent),
                        ),
                        child: Text(
                          isActive ? "AKTİF" : "ENGELLİ",
                          style: TextStyle(
                            color: isActive ? Colors.greenAccent : Colors.redAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(email, style: const TextStyle(color: Colors.white70)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isAdmin)
                        PopupMenuButton<String>(
                          tooltip: "İşlemler",
                          color: Colors.grey[900],
                          icon: const Icon(Icons.more_vert, color: Colors.white70),
                          onSelected: (value) async {
                            if (value == 'toggle') {
                              await _toggleBlockUser(
                                uid: uid,
                                isActive: isActive,
                                nameForDialog: name.isEmpty ? email : name,
                              );
                            } else if (value == 'delete') {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text("Kullanıcıyı Sil"),
                                  content: Text("${name.isEmpty ? email : name} kullanıcısını silmek istediğine emin misin?"),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("İptal")),
                                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Sil")),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await db.collection("users").doc(uid).delete();
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem<String>(
                              value: 'toggle',
                              child: Row(
                                children: [
                                  Icon(isActive ? Icons.block : Icons.check_circle, color: Colors.white70, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    isActive ? "Hesabı Engelle" : "Engeli Kaldır",
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            if (canDelete)
                              const PopupMenuItem<String>(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete, color: Colors.redAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text("Sil", style: TextStyle(color: Colors.redAccent)),
                                  ],
                                ),
                              ),
                          ],
                        ),
                    ],
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
