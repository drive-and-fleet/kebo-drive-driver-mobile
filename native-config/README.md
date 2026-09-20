# Natív login konfiguráció

A Dart-kód a Firebase Authenticationt használja közös identitásrétegként. A Google, Facebook és Apple provider tokenjeit a Firebase hitelesíti, majd a mobilapp a Firebase ID tokent a Driver API `/api/v1/driver/auth/exchange` végpontján platform-JWT-re cseréli. A backend üzleti API-k kizárólag ezt a platform-JWT-t fogadják el.

## Firebase

1. Hozz létre Android és iOS alkalmazást ugyanabban a Firebase projektben.
2. Authentication -> Sign-in method alatt engedélyezd: Google, Facebook, Apple. Ha használni akarod, az Email/Password providert is.
3. A Firebase app adatait írd a `config/dev.json` és `config/prod.json` fájlba.
4. Androidnál add hozzá a debug/release SHA-1/SHA-256 fingerprintet a Firebase projekthez.
5. A backendnek add meg a `FIREBASE_PROJECT_ID` és `FIREBASE_SERVICE_ACCOUNT_BASE64` értékeket. A service account SOHA ne kerüljön a mobilappba.

## Google

- `GOOGLE_SERVER_CLIENT_ID`: a Firebase/Google Cloud Web OAuth client ID. Androidon ezt használja a plugin a megfelelő ID tokenhez.
- `GOOGLE_IOS_CLIENT_ID`: az iOS OAuth client ID.
- iOS esetén a Google Sign-In dokumentáció szerinti URL scheme-et is add hozzá az `ios/Runner/Info.plist` fájlhoz. Az értéket a saját iOS OAuth kliensedből vedd; ezt nem lehet helyesen előre generálni.

## Facebook

A `flutter_facebook_auth` natív Meta SDK-t használ, ezért a saját Meta Developer alkalmazásod adatait is be kell állítani.

Android:
- Facebook App ID és Client Token a plugin aktuális Android setupja szerint (`AndroidManifest.xml` / resources).
- A package name és key hash legyen regisztrálva a Meta Developer Console-ban.

IOS:
- Facebook App ID, Client Token, display name és URL scheme az `Info.plist`-ben a plugin setupja szerint.
- A bundle identifier egyezzen a Meta/Firebase beállítással.

A Meta app secret NEM kerül a mobilalkalmazásba; azt Firebase oldalon állítod be.

## Apple

1. Apple Developer portalon engedélyezd a Sign in with Apple capability-t az App ID-n.
2. Xcode -> Runner -> Signing & Capabilities alatt add hozzá a `Sign In with Apple` capability-t.
3. Firebase Authentication Apple providerében állítsd be az Apple Developer adatait.
4. Az iOS bundle ID pontosan egyezzen a Firebase és Apple konfigurációval.

Androidon az Apple provider OAuth/web flow-val használható, ha a Firebase Apple provider megfelelően konfigurált. iOS-en a natív capability kötelező.

## Kamera

A bootstrap script hozzáadja a kamera alap permissionöket. Az app csak kamerás felvételt használ; a jegyzőkönyv képeit az alkalmazás saját dokumentumterületére másolja, hogy az ideiglenes camera cache törlése ne okozzon adatvesztést offline módban.
