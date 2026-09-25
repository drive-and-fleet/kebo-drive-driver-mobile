import '../api/driver_api.dart';
import '../api/http_api.dart';
import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../local/file_store.dart';
import '../local/local_database.dart';
import '../local/local_repository.dart';
import 'sync_service.dart';
import 'work_service.dart';

class AppServices {
  AppServices._({
    required this.local,
    required this.fileStore,
    required this.auth,
    required this.api,
    required this.sync,
    required this.work,
  });

  final LocalRepository local;
  final FileStore fileStore;
  final AuthService auth;
  final DriverApi api;
  final SyncService sync;
  final WorkService work;

  static Future<AppServices> create() async {
    final local = LocalRepository(LocalDatabase.instance);
    const fileStore = FileStore();
    final http = HttpApi(AppConfig.driverApiBaseUrl);
    final auth = AuthService(http);
    await auth.initialize();
    final api = DriverApi(http, auth);
    final sync = SyncService(api, local);
    await sync.initialize();
    final work = WorkService(api, local, sync)..startAutoRefresh(() => auth.isSignedIn);
    return AppServices._(
      local: local,
      fileStore: fileStore,
      auth: auth,
      api: api,
      sync: sync,
      work: work,
    );
  }
}
