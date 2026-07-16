# gunluoglu

Günlüoğlu için hazırlanmış Flutter ve Firebase tabanlı bir işletme yönetim uygulamasıdır. Uygulama; giriş, rol bazlı erişim, satış takibi, üretim takibi, stok yönetimi, müşteri siparişleri ve gelir özetlerini tek yerde toplar.

## Proje Amacı

Bu proje bir pastane ya da benzeri bir üretim işletmesinin günlük operasyonlarını dijital olarak yönetmek için tasarlanmıştır. Kullanıcı giriş yaptıktan sonra sistem, Firestore üzerindeki role göre ilgili ekranı açar. Admin kullanıcılar yönetim ve raporlama ekranlarını görürken, üretim ve satış kullanıcıları kendi operasyon alanlarına yönlendirilir.

## Temel Özellikler

Admin için kullanıcı yönetimi, satış yarışması, genel gelir özetleri ve ürün yönetimi bulunur. Satış tarafında POS ekranı ile ürün seçimi ve işlem akışı yönetilir. Üretim tarafında tava ve adet takibi yapılır, günlük üretim kayıtları Firestore'a yazılır. Stok ekranları, müşteri sipariş özetleri ve kullanıcı bazlı gelir detayları da uygulamanın ana parçalarıdır.

## Kullanılan Teknolojiler

Flutter, Dart, Firebase Authentication, Cloud Firestore, Firebase App Check ve SharedPreferences kullanılır.

## Ana Ekranlar

Projede yer alan başlıca ekranlar login, register, POS satış, kullanıcı yönetimi, ürün yönetimi, üretim yönetimi, üretici tava ekranı, günlük stok ekranı, müşteri sipariş özeti, kullanıcı gelir detayı, müşteri gelir özeti, satış yarışması ve admin gün seçme ekranıdır.

## Çalıştırma

Önce Flutter bağımlılıklarını yükleyin. Ardından Firebase yapılandırmasını kendi projenize göre ayarlayıp aşağıdaki komutlarla çalıştırın:

```bash
flutter pub get
flutter run
```

## Notlar

Uygulama Firebase servislerine bağlıdır ve `firebase_options.dart` dosyası proje ayarlarını içerir. Bazı ekranlar için Firestore rules ve index tanımları gerekebilir. Bu proje operasyon ve satış takibini tek merkezden yürütmek amacıyla hazırlanmıştır.
