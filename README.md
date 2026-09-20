# Fleet Driver Flutter App

Egyszerű, offline-first Flutter alkalmazás a flottakezelő / sofőrszolgálat platform sofőrjeinek. A megvalósítás a HLD Driver API határát követi: a mobilapp kizárólag a külön Driver API-val kommunikál, a Fleet/Admin API-t nem hívja.

## Fő funkciók

- Google, Facebook, Apple és opcionális Firebase e-mail/jelszó login. Facebook iOS Limited Login nonce-kezeléssel is támogatott.
- Firebase identity -> backend platform-JWT token exchange.
- A backend továbbra is ellenőrzi a sofőr és sofőrszolgálati tagság aktív állapotát; a kliens nem jogosultsági forrás.
- Saját kiosztott LEG-ek letöltése.
- Rendszám alapú, sofőrszolgálatra szűrt szabad LEG keresés és self-assignment.
- A LEG felvétele előtt letölti az űrlap-konfigurációt és korábbi jegyzőkönyv snapshotokat; sikeres felvétel után a helyszíni munka internet nélkül is folytatható.
- Offline átvételi és leadási jegyzőkönyv.
- Dinamikus form: TEXT, NUMBER, BOOLEAN, DATE, DATETIME, SINGLE_SELECT, MULTI_SELECT. Új/eltérő formhoz nem kell app-kódot módosítani.
- Kötelező formmezők és kötelező fotótípusok lokális ellenőrzése; a backend ugyanezt szerveroldalon is validálja.
- Sérülések 0..N, sérülésenként 0..N fotó; általános fotók sérüléstől függetlenül.
- Korábbi jegyzőkönyv másolása ugyanazon megrendelés/autó esetén. A kézi szignó nem másolódik.
- Mobilon rajzolt kézi szignó.
- LEG indítás és lezárás offline queue-val.
- Sofőr -> sofőr átadási kérés, kétoldalú szerveroldali jóváhagyással (online funkció).
- Automatikus és kézi szinkron. 409 konfliktus nem íródik felül csendben; `CONFLICT` állapotban látható.
- SQLite lokális adattárolás, normalizált táblákkal; nincs általános JSON blob adatbázis.

## Mi működik offline?

A self-assignment maga online művelet, mert tranzakciósan a szerveren kell eldőlni, hogy ki kapta meg a LEG-et. A `Felveszem` gomb csak akkor jelez sikert, ha:

1. az aktuális form-konfiguráció le lett töltve;
2. a másoláshoz használható korábbi inspection snapshotok le lettek töltve;
3. a backend sikeresen a sofőrhöz rendelte a LEG-et;
4. a LEG munkacsomag lokálisan el lett mentve.

Ezután internet nélkül elvégezhető:

- a letöltött fuvar megnyitása;
- átvételi jegyzőkönyv;
- dinamikus mezők kitöltése;
- fotózás;
- sérülés rögzítése;
- kézi szignó;
- LEG indítása;
- leadási jegyzőkönyv;
- LEG lezárása.

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
  ui/widgets/           # dinamikus form mezők, LEG kártya
config/                  # dev/prod dart-define példák
tool/                    # android/ios scaffold bootstrap
native-config/           # Google/Facebook/Apple natív setup
```

Nincs repository/service/interface rétegek egymásra halmozása. A `LocalRepository` a SQLite műveletek, a `DriverApi` a HTTP, a `WorkService` a helyszíni use-case-ek, a `SyncService` az offline queue felelőse.

## Előfeltételek

- Flutter >= 3.38 (aktuális stable ajánlott), Dart >= 3.12.
- Android Studio/Android SDK Android buildhez.
- Xcode + Apple Developer signing iOS buildhez.
- Firebase projekt a Google/Facebook/Apple Authentication providerekkel.
- futó Driver API (a mellékelt backend v3 tartalmazza a szükséges Firebase token exchange endpointot).

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

## 2. Firebase / social login

Olvasd el:

```text
native-config/README.md
```

A Google/Facebook/Apple providerhez a saját Firebase, Meta és Apple alkalmazásod azonosítói szükségesek. Ezeket nem lehet helyesen kitalálni vagy a forráskódba előre beégetni.

## 3. Local konfiguráció

```bash
cp config/dev.json.example config/dev.json
```

Töltsd ki a Firebase adatokat.

Android emulator esetén a host gép `localhost` címe:

```json
"DRIVER_API_BASE_URL": "http://10.0.2.2:3002"
```

iOS Simulatoron jellemzően:

```json
"DRIVER_API_BASE_URL": "http://127.0.0.1:3002"
```

Fizikai telefonon a géped hálózati IP-je vagy HTTPS fejlesztői endpoint szükséges.

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

## Production build

```bash
cp config/prod.json.example config/prod.json
# töltsd ki
flutter build apk --release --dart-define-from-file=config/prod.json
flutter build appbundle --release --dart-define-from-file=config/prod.json
flutter build ipa --release --dart-define-from-file=config/prod.json
```

## Backend v3 - social login

A Driver API-n szükséges env:

```dotenv
FIREBASE_PROJECT_ID=your-firebase-project
FIREBASE_SERVICE_ACCOUNT_BASE64=<base64 encoded service-account JSON>
PLATFORM_ACCESS_TOKEN_TTL_SECONDS=1800
JWT_ISSUER=fleet-platform
JWT_AUDIENCE=fleet-platform-clients
JWT_SECRET=replace-in-production
# vagy RS256 esetén:
JWT_PRIVATE_KEY_BASE64=
JWT_PUBLIC_KEY_BASE64=
```

A mobilappban Firebase service account / private key NINCS és nem is lehet.

Új social user első belépésekor az app a `/api/v1/driver/auth/register` végponttal PENDING sofőrprofilt hoz létre. A system admin jóváhagyása után az `/auth/exchange` platform-JWT-t ad. A backend API-k ezt a platform-JWT-t validálják, nem a nyers Google/Facebook/Apple tokent.

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

- első/social login és token exchange;
- rendszám alapú szabad LEG keresés;
- self-assignment;
- két sofőr közötti átadás/jóváhagyás;
- első work package letöltés;
- szinkron.

Ezek közül egyik sem blokkolja a már lokálisan letöltött és felvett fuvar helyszíni dokumentálását.
