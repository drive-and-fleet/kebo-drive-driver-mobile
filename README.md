# Fleet Driver Flutter App

Egyszerű, offline-first Flutter alkalmazás a flottakezelő / sofőrszolgálat platform sofőrjeinek. A megvalósítás a HLD Driver API határát követi: a mobilapp kizárólag a külön Driver API-val kommunikál, a Fleet/Admin API-t nem hívja.

## Fő funkciók

- **Alapértelmezett belépés: e-mail + jelszó**, natívan a Driver API-n (bcrypt), Firebase nélkül. A regisztráció során a sofőr kiválasztja a sofőrszolgálatát; a kapcsolat azonnal létrejön, de a sofőr `PENDING` marad, amíg a szolgálat ügyintézője jóvá nem hagyja (Törzsadatok → Sofőrök → „Kapcsolás a szolgálathoz” a management webről).
- Google, Facebook, Apple és Firebase e-mail/jelszó login is megvan a kódban, de alapból **ki van kapcsolva** (`SOCIAL_LOGIN_ENABLED=false`) — ezekkel Firebase projekt kell, e nélkül az app nem indul. Lásd a „Social login (opcionális)” szakaszt.
- A backend minden kérésnél ellenőrzi a sofőr és sofőrszolgálati tagság aktív állapotát; a kliens nem jogosultsági forrás, és a token élettartama emiatt biztonságosan hosszú lehet jelszavas munkamenetnél (lásd `DRIVER_ACCESS_TOKEN_TTL_SECONDS`).
- Saját kiosztott fuvarok (LEG-ek) letöltése.
- **Böngészhető szabad fuvarok lista** (nem csak rendszám alapú keresés): ha a sofőrszolgálatnál engedélyezett a sofőr önkiosztás, minden szabad, PLANNED, hozzá nem rendelt LEG megjelenik; a rendszám mező csak opcionális szűrő.
- A fuvar felvétele előtt letölti az űrlap-konfigurációt és korábbi jegyzőkönyv snapshotokat; sikeres felvétel után a helyszíni munka internet nélkül is folytatható.
- Offline átvételi és leadási jegyzőkönyv.
- Dinamikus form: TEXT, NUMBER, BOOLEAN, DATE, DATETIME, SINGLE_SELECT, MULTI_SELECT. Új/eltérő formhoz nem kell app-kódot módosítani.
- Kötelező formmezők és kötelező fotótípusok lokális ellenőrzése; a backend ugyanezt szerveroldalon is validálja.
- Sérülések 0..N, sérülésenként 0..N fotó; általános fotók sérüléstől függetlenül.
- Korábbi jegyzőkönyv másolása ugyanazon megrendelés/autó esetén. A kézi szignó nem másolódik.
- Mobilon rajzolt kézi szignó.
- „Fuvar indítása” / „Fuvar lezárása”: egyetlen gomb nyitja meg a szükséges (átvételi/leadási) jegyzőkönyvet, és annak lezárása után automatikusan indítja/zárja a fuvart is — a sofőrnek nem kell tudnia, hogy ez a rendszerben két lépés.
- Sofőr -> sofőr átadási kérés, kétoldalú szerveroldali jóváhagyással (online funkció).
- Automatikus (csatlakozás-változásra és 60 másodpercenként) és kézi szinkron, exponenciális backoff-fal a hibázó műveleteken. 409 konfliktus nem íródik felül csendben; `CONFLICT` állapotban látható.
- SQLite lokális adattárolás, normalizált táblákkal; nincs általános JSON blob adatbázis.
- „Menetrend” design rendszer (a management web admin felületének vizuális nyelve), kesztyűben/napfényben is olvasható, nagyobb betűmérettel.

## Mi működik offline?

A self-assignment (fuvar felvétele) maga online művelet, mert tranzakciósan a szerveren kell eldőlni, hogy ki kapta meg a fuvart. A `Felveszem` gomb csak akkor jelez sikert, ha:

1. az aktuális form-konfiguráció le lett töltve;
2. a másoláshoz használható korábbi inspection snapshotok le lettek töltve;
3. a backend sikeresen a sofőrhöz rendelte a fuvart;
4. a munkacsomag lokálisan el lett mentve.

Ezután internet nélkül elvégezhető:

- a letöltött fuvar megnyitása;
- átvételi jegyzőkönyv;
- dinamikus mezők kitöltése;
- fotózás;
- sérülés rögzítése;
- kézi szignó;
- fuvar indítása;
- leadási jegyzőkönyv;
- fuvar lezárása.

A lokális műveletek sorrendben kerülnek a `sync_operation` queue-ba. Hálózat visszatérésekor a kliens megpróbálja szinkronizálni őket. A `connectivity_plus` csak trigger: tényleges internetelérést mindig a HTTP kérés sikere határoz meg.

## Projektstruktúra

```text
lib/
  api/                  # vékony HTTP és Driver API kliens
  auth/                 # Firebase login + platform JWT exchange
  config/               # build-time konfiguráció
  local/                # SQLite és lokális médiafájlok
  models/               # API/lokális modellek
  services/             # work package, validáció, sync
  ui/screens/           # egyszerű képernyők
  ui/widgets/           # dinamikus form mezők, fuvar kártya
  ui/theme.dart         # "Menetrend" design tokenek és ThemeData
config/                  # dev/prod dart-define példák
tool/                    # android/ios scaffold bootstrap
native-config/           # Google/Facebook/Apple natív setup
```

Nincs repository/service/interface rétegek egymásra halmozása. A `LocalRepository` a SQLite műveletek, a `DriverApi` a HTTP, a `WorkService` a helyszíni use-case-ek, a `SyncService` az offline queue felelőse.

## Előfeltételek

- Flutter >= 3.38 (aktuális stable ajánlott), Dart >= 3.12.
- Android Studio/Android SDK Android buildhez.
- Xcode + Apple Developer signing iOS buildhez.
- futó Driver API. Firebase projekt **csak akkor kell**, ha a social login be van kapcsolva (`SOCIAL_LOGIN_ENABLED=true`) — alapból nem szükséges.

Ellenőrzés:

```bash
flutter doctor
flutter --version
```

## 1. Android/iOS platform scaffold

A generált forrás szándékosan nem tartalmaz kézzel rögzített, Flutter-verzióhoz kötött Gradle/Xcode boilerplate-et. Generáld a telepített Flutter SDK-ddal:

```bash
./tool/bootstrap_platforms.sh
```

Alapértelmezett org: `hu.fleetplatform`. Másik org:

```bash
FLUTTER_ORG=hu.sajatceg ./tool/bootstrap_platforms.sh
```

A script csak a hiányzó `android/` és `ios/` mappát hozza létre, a `lib/` és `pubspec.yaml` fájlokat nem írja felül.

## 2. Social login (opcionális)

Alapból nem kell semmit tenned itt — az app e-mail/jelszóval fut. Ha mégis szeretnéd a Google/Facebook/Apple bejelentkezést, olvasd el:

```text
native-config/README.md
```

és kapcsold be `config/dev.json`-ban: `"SOCIAL_LOGIN_ENABLED": "true"`, majd töltsd ki a Firebase/Google mezőket. A Google/Facebook/Apple providerhez a saját Firebase, Meta és Apple alkalmazásod azonosítói szükségesek; ezeket nem lehet helyesen kitalálni vagy a forráskódba előre beégetni.

## 3. Local konfiguráció

```bash
cp config/dev.json.example config/dev.json
```

Alapból csak a `DRIVER_API_BASE_URL`-t kell ellenőrizni; a `SOCIAL_LOGIN_ENABLED` marad `"false"`, a Firebase mezőket üresen/placeholderként hagyhatod.

Android emulator esetén a host gép `localhost` címe:

```json
"DRIVER_API_BASE_URL": "http://10.0.2.2:3002"
```

iOS Simulatoron jellemzően:

```json
"DRIVER_API_BASE_URL": "http://127.0.0.1:3002"
```

Fizikai telefonon a géped hálózati IP-je vagy HTTPS fejlesztői endpoint szükséges.

### Fontos: az objektumtár címe is a készülékről kell elérhető legyen

A fotókat és szignókat az app **nem** az API-n keresztül tölti fel, hanem presigned URL-lel közvetlenül a MinIO-ra. Ennek a címét a Driver API `S3_PUBLIC_ENDPOINT` env-je adja, és ugyanazt a hoszt-aliast kell tartalmaznia, amit a `DRIVER_API_BASE_URL` használ:

| Futtatás | `DRIVER_API_BASE_URL` | `S3_PUBLIC_ENDPOINT` (Driver API `.env.local`) |
|---|---|---|
| Android emulátor | `http://10.0.2.2:3002` | `http://10.0.2.2:9000` |
| iOS szimulátor | `http://127.0.0.1:3002` | `http://127.0.0.1:9000` |
| fizikai eszköz | `http://<LAN IP>:3002` | `http://<LAN IP>:9000` |

Ha `S3_PUBLIC_ENDPOINT=http://localhost:9000` marad, a jegyzőkönyv szinkronizálása **végtelen ciklusban elbukik**, méghozzá nehezen észrevehetően: az emulátoron a `localhost` magát az emulátort jelenti, a feltöltés tehát sehova nem jut el. A driver-api logjában ilyenkor csak ennyi látszik, újra és újra:

```text
LOG [HTTP] PUT  /api/v1/driver/inspections/2/values 200
LOG [HTTP] POST /api/v1/driver/inspections/2/uploads/presign 201
```

— a feltöltés maga sosem jelenik meg, mert nem az API-hoz megy. Az appban a Szinkron nézet ilyenkor a konkrét hosztot írja ki („A tárhely nem érhető el: localhost:9000”).

## 4. Dependency install

```bash
flutter pub get
```

## 5. Indítás local környezetben

```bash
flutter run --dart-define-from-file=config/dev.json
```

Konkrét device:

```bash
flutter devices
flutter run -d <DEVICE_ID> --dart-define-from-file=config/dev.json
```

## Indítás telefonon, a VPS-en futó rendszerrel

A `config/vps.json` a https://app.flottafuvar.hu-n futó Driver API-ra mutat (a Caddy
a `/driver-api/` útvonalat adja tovább). Emulátor nem kell, a telefonon valódi
internetkapcsolattal megy; a fotók a https://app.flottafuvar.hu/fleet-private/... címre
töltődnek fel.

```bash
flutter devices                                   # USB-n csatlakoztatott telefon
flutter run -d <DEVICE_ID> --dart-define-from-file=config/vps.json

# telepíthető APK a VPS-hez (pl. tesztelőknek):
flutter build apk --release --dart-define-from-file=config/vps.json
# eredmény: build/app/outputs/flutter-apk/app-release.apk
```

Android telefonon előbb kapcsold be a Fejlesztői beállítások → USB-hibakeresés
opciót; iPhone-on Xcode-ban kell egyszer aláírni az alkalmazást (Signing & Capabilities).

## Alkalmazás neve és ikonja

- Név: **Drive and Fleet Sofőr** (`android/app/src/main/AndroidManifest.xml` → `android:label`,
  `ios/Runner/Info.plist` → `CFBundleDisplayName`, `lib/app.dart` → `title`).
- Ikon: a forrás az `assets/icon/` mappában (`icon.svg` → `icon.png` a teljes ikon,
  `icon_foreground.*` az Android adaptív ikon előtere, háttérszín `#0C1820`).
  Módosítás után az összes méret újragenerálása:

  ```bash
  flutter pub add --dev flutter_launcher_icons
  cat >> pubspec.yaml <<'YAML'
  flutter_launcher_icons:
    android: "ic_launcher"
    ios: true
    image_path: "assets/icon/icon.png"
    adaptive_icon_background: "#0C1820"
    adaptive_icon_foreground: "assets/icon/icon_foreground.png"
    remove_alpha_ios: true
  YAML
  dart run flutter_launcher_icons
  ```

## Production build

```bash
cp config/prod.json.example config/prod.json
# töltsd ki
flutter build apk --release --dart-define-from-file=config/prod.json
flutter build appbundle --release --dart-define-from-file=config/prod.json
flutter build ipa --release --dart-define-from-file=config/prod.json
```

## Backend — e-mail/jelszó (alapértelmezett)

A Driver API-n szükséges env (lásd `.env.example`):

```dotenv
JWT_ISSUER=fleet-platform
JWT_AUDIENCE=fleet-platform-clients
JWT_SECRET=replace-in-production
# vagy RS256 esetén:
JWT_PRIVATE_KEY_BASE64=
JWT_PUBLIC_KEY_BASE64=
DRIVER_ACCESS_TOKEN_TTL_SECONDS=2592000
```

Végpontok:

- `GET /api/v1/driver/service-organizations` — aktív sofőrszolgálatok, a regisztrációs dropdownhoz. Nem igényel bejelentkezést.
- `POST /api/v1/driver/auth/register-password` — e-mail, jelszó, alapadatok és a választott `serviceOrgId`. Azonnal létrehoz egy `DRIVER_SERVICE_HISTORY` kapcsolatot a választott szolgálathoz, de a sofőr `PENDING` marad.
- `POST /api/v1/driver/auth/login` — e-mail + jelszó, válaszul platform-JWT (csak `ACTIVE`/`ACTIVE` sofőrnek).

A jóváhagyás a management weben történik: Törzsadatok → Sofőrök → a jelentkező sofőr (a választott szolgálatnál már látszik) → „Kapcsolás a szolgálathoz”. Ez egyszerre aktiválja a `USER` és a `DRIVER_PROFILE` rekordot.

## Backend — social login (opcionális)

Csak akkor kell, ha `SOCIAL_LOGIN_ENABLED=true` a mobilon:

```dotenv
FIREBASE_PROJECT_ID=your-firebase-project
FIREBASE_SERVICE_ACCOUNT_BASE64=<base64 encoded service-account JSON>
PLATFORM_ACCESS_TOKEN_TTL_SECONDS=1800
```

A mobilappban Firebase service account / private key NINCS és nem is lehet.

Új social user első belépésekor az app a `/api/v1/driver/auth/register` végponttal PENDING sofőrprofilt hoz létre — ez a régi út nem választ sofőrszolgálatot, a jóváhagyó ügyintéző utólag kapcsolja a szolgálathoz. A system admin/szolgálat admin jóváhagyása után az `/auth/exchange` platform-JWT-t ad. A backend API-k ezt a platform-JWT-t validálják, nem a nyers Google/Facebook/Apple tokent.

## Dinamikus űrlap

A mobil nem ismer olyan kódot, hogy „ez az egyszerűsített form” vagy „ez a részletes form”. Az aktív formot a Driver API adja vissza:

- field definition;
- data type;
- kötelező/opcionális;
- PICKUP/DROPOFF/BOTH phase;
- sorrend;
- select optionök;
- kötelező fotótípus + minimum darabszám.

A konfiguráció SQLite cache-be kerül. Emiatt a szerveren új form vagy mezőösszeállítás készíthető app release nélkül. A backend csak olyan formot enged ACTIVE állapotba, amely tartalmazza a kötelező minimumot: üzemanyagszint, kulcsok száma, forgalmi és km-állás. A rendszám a VEHICLE adatból jelenik meg, nem duplikált inspection mező.

## Offline adatvédelem

- A platform JWT a secure storage-ban van.
- Fotók/szignók az app saját dokumentumterületén maradnak a sikeres syncig.
- Függő sync művelet mellett a UI nem enged kijelentkezni, hogy másik sofőr ne láthassa/folytathassa az előző sofőr lokális munkáját.
- Sikeres és teljes szinkron után kijelentkezéskor a sofőrhöz tartozó lokális cache törlődik.

## Amit online kell tartani

- regisztráció (a sofőrszolgálatok listájának betöltése) és minden bejelentkezés/token-csere;
- szabad fuvarok listája és felvétele (self-assignment);
- két sofőr közötti átadás/jóváhagyás;
- első work package letöltés;
- szinkron.

Ezek közül egyik sem blokkolja a már lokálisan letöltött és felvett fuvar helyszíni dokumentálását.
