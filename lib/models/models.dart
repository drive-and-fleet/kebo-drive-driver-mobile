class DriverSession {
  const DriverSession({
    required this.driverId,
    required this.userId,
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final String driverId;
  final String userId;
  final String firstName;
  final String lastName;
  final String email;

  String get displayName => '$firstName $lastName'.trim();

  factory DriverSession.fromJson(Map<String, dynamic> json) => DriverSession(
        driverId: '${json['id'] ?? json['driverId']}',
        userId: '${json['userId']}',
        firstName: '${json['firstName'] ?? ''}',
        lastName: '${json['lastName'] ?? ''}',
        email: '${json['email'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': driverId,
        'userId': userId,
        'firstName': firstName,
        'lastName': lastName,
        'email': email,
      };
}

class ServiceOrgOption {
  const ServiceOrgOption({required this.id, required this.name});
  final String id;
  final String name;

  factory ServiceOrgOption.fromJson(Map<String, dynamic> json) =>
      ServiceOrgOption(id: '${json['id']}', name: '${json['name']}');
}

class DriverLeg {
  const DriverLeg({
    required this.legKey,
    required this.status,
    required this.sequenceNo,
    required this.orderVehicleId,
    required this.registrationNumber,
    required this.orderNo,
    required this.serviceOrgId,
    required this.fromAddress,
    required this.toAddress,
    this.legId,
    this.plannedStart,
    this.plannedEnd,
    this.make,
    this.model,
    this.color,
    this.vehicleUserName,
    this.vehicleUserEmail,
    this.vehicleUserPhone,
    this.fromContactName,
    this.fromContactPhone,
    this.toContactName,
    this.toContactPhone,
    this.legCount,
    this.fromStopType,
    this.toStopType,
    this.fromStopTypeName,
    this.toStopTypeName,
    this.fromStopWaits,
    this.toStopWaits,
    this.previousLegStatus,
    this.fromCompanyName,
    this.toCompanyName,
    this.fromStopNotes,
    this.toStopNotes,
    this.vehicleNotes,
    this.vehicleExtraEmail,
    this.locationSharing = false,
    this.formTypeId,
  });

  final String? legId;
  final String legKey;
  final String status;
  final int sequenceNo;
  final DateTime? plannedStart;
  final DateTime? plannedEnd;
  final String orderVehicleId;
  final String registrationNumber;
  final String? make;
  final String? model;
  final String? color;
  final String orderNo;
  final String serviceOrgId;
  final String fromAddress;
  final String toAddress;
  final String? vehicleUserName;
  final String? vehicleUserEmail;
  final String? vehicleUserPhone;
  final String? fromContactName;
  final String? fromContactPhone;
  final String? toContactName;
  final String? toContactPhone;

  /// Hány út tartozik ehhez a járműhöz az útvonalon. Csak a szabad fuvarok
  /// listájában jön a szervertől, a lokális cache-ben nincs eltárolva.
  final int? legCount;

  /// A két végpont megállótípusa (PICKUP, DROPOFF, WAIT, régi adatban INTERMEDIATE).
  final String? fromStopType;
  final String? toStopType;

  /// A megállótípus neve a Beállításokból (pl. „Szerviz (várakozással)”), ha van.
  final String? fromStopTypeName;
  final String? toStopTypeName;

  /// A megálló viselkedésének „a sofőr megvárja az autót” jelzője a Beállításokból
  /// (STOP_BEHAVIOR.driver_waits). Null a régi szervertől / régi gyorsítótárból.
  final bool? fromStopWaits;
  final bool? toStopWaits;

  /// A megállók cégneve (pl. a szerviz) és megjegyzése, az iroda rögzítéséből.
  final String? fromCompanyName;
  final String? toCompanyName;
  final String? fromStopNotes;
  final String? toStopNotes;

  /// Az autó megjegyzése a fuvarban (pl. engedélyszám) és a további cím, amelyre a jegyzőkönyvek is mennek.
  final String? vehicleNotes;
  final String? vehicleExtraEmail;

  /// Az iroda engedélyezte a helyzetmegosztást ennek a szolgálatnak az útjain:
  /// fuvar közben (átvételtől leadásig) a telefon akkukímélően küldi a helyzetét.
  final bool locationSharing;

  /// A megrendelés jegyzőkönyv-típusa (az iroda választja; üresen a szolgálat
  /// alapértelmezettje). Null a régi szervertől / régi gyorsítótárból.
  final String? formTypeId;

  /// A cím a cégnévvel együtt, ahogy a sofőrnek mutatjuk.
  String get fromPlace => _place(fromCompanyName, fromAddress);
  String get toPlace => _place(toCompanyName, toAddress);

  /// Az autó előző útjának állapota (csak a szabad fuvarok listájában jön).
  /// Amíg az nem teljesült (COMPLETED), ez az út nem vehető fel: az utak sorban mennek.
  final String? previousLegStatus;

  bool get waitsForPreviousLeg => previousLegStatus != null && previousLegStatus != 'COMPLETED';

  /// Körfuvar odaútja: a cél egy várakozó megálló, ahol a sofőr megvárja az autót,
  /// és onnan viszi tovább (visszaút). Jelző nélkül a régi WAIT kód dönt.
  bool get isOutbound => toStopWaits ?? toStopType == 'WAIT';

  /// Körfuvar visszaútja: a várakozó megállóból indul.
  bool get isReturn => fromStopWaits ?? fromStopType == 'WAIT';

  /// Az út egy korábbi út végpontjából indul (pl. körfuvar visszaútja): ott már csak felvétel van,
  /// a megálló típusa („Leadás, majd felvétel később ugyanitt”) itt nem mond semmit.
  bool get startsMidRoute => sequenceNo > 1;

  /// Az indulás felirata a sofőrnek.
  String get fromLabel => startsMidRoute ? 'Felvétel' : (fromStopTypeName ?? 'Felvétel');

  /// Kis megjegyzés az indulásnál, ha az autó egy korábbi útról van ott.
  String? get fromNote => !startsMidRoute ? null : (fromStopWaits == true ? 'itt várta meg a sofőr' : 'korábban itt hagyott autó');

  factory DriverLeg.fromJson(Map<String, dynamic> json) => DriverLeg(
        legId: json['legId']?.toString(),
        legKey: '${json['legKey']}',
        status: '${json['status'] ?? 'PLANNED'}',
        sequenceNo: int.tryParse('${json['sequenceNo'] ?? 0}') ?? 0,
        plannedStart: _date(json['plannedStart']),
        plannedEnd: _date(json['plannedEnd']),
        orderVehicleId: '${json['orderVehicleId']}',
        registrationNumber: '${json['registrationNumber']}',
        make: json['make']?.toString(),
        model: json['model']?.toString(),
        color: json['color']?.toString(),
        orderNo: '${json['orderNo']}',
        serviceOrgId: '${json['serviceOrgId']}',
        fromAddress: '${json['fromAddress'] ?? ''}',
        toAddress: '${json['toAddress'] ?? ''}',
        vehicleUserName: json['vehicleUserName']?.toString(),
        vehicleUserEmail: json['vehicleUserEmail']?.toString(),
        vehicleUserPhone: json['vehicleUserPhone']?.toString(),
        fromContactName: json['fromContactName']?.toString(),
        fromContactPhone: json['fromContactPhone']?.toString(),
        toContactName: json['toContactName']?.toString(),
        toContactPhone: json['toContactPhone']?.toString(),
        legCount: int.tryParse('${json['legCount'] ?? ''}'),
        fromStopType: json['fromStopType']?.toString(),
        toStopType: json['toStopType']?.toString(),
        fromStopTypeName: json['fromStopTypeName']?.toString(),
        toStopTypeName: json['toStopTypeName']?.toString(),
        fromStopWaits: _flag(json['fromStopWaits']),
        toStopWaits: _flag(json['toStopWaits']),
        previousLegStatus: json['previousLegStatus']?.toString(),
        fromCompanyName: json['fromCompanyName']?.toString(),
        toCompanyName: json['toCompanyName']?.toString(),
        fromStopNotes: json['fromStopNotes']?.toString(),
        toStopNotes: json['toStopNotes']?.toString(),
        vehicleNotes: json['vehicleNotes']?.toString(),
        vehicleExtraEmail: json['vehicleExtraEmail']?.toString(),
        locationSharing: _flag(json['locationSharing']) ?? false,
        formTypeId: json['formTypeId']?.toString(),
      );

  Map<String, dynamic> toCacheMap() => {
        'leg_key': legKey,
        'leg_id': legId,
        'status': status,
        'sequence_no': sequenceNo,
        'planned_start': plannedStart?.toIso8601String(),
        'planned_end': plannedEnd?.toIso8601String(),
        'order_vehicle_id': orderVehicleId,
        'registration_number': registrationNumber,
        'make': make,
        'model': model,
        'color': color,
        'order_no': orderNo,
        'service_org_id': serviceOrgId,
        'from_address': fromAddress,
        'to_address': toAddress,
        'vehicle_user_name': vehicleUserName,
        'vehicle_user_email': vehicleUserEmail,
        'vehicle_user_phone': vehicleUserPhone,
        'from_contact_name': fromContactName,
        'from_contact_phone': fromContactPhone,
        'to_contact_name': toContactName,
        'to_contact_phone': toContactPhone,
        'from_stop_type': fromStopType,
        'to_stop_type': toStopType,
        'from_stop_type_name': fromStopTypeName,
        'to_stop_type_name': toStopTypeName,
        'from_stop_waits': fromStopWaits == null ? null : (fromStopWaits! ? 1 : 0),
        'to_stop_waits': toStopWaits == null ? null : (toStopWaits! ? 1 : 0),
        'from_company_name': fromCompanyName,
        'to_company_name': toCompanyName,
        'from_stop_notes': fromStopNotes,
        'to_stop_notes': toStopNotes,
        'vehicle_notes': vehicleNotes,
        'vehicle_extra_email': vehicleExtraEmail,
        'location_sharing': locationSharing ? 1 : 0,
        'form_type_id': formTypeId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  factory DriverLeg.fromCacheMap(Map<String, dynamic> json) => DriverLeg(
        legId: json['leg_id']?.toString(),
        legKey: '${json['leg_key']}',
        status: '${json['status']}',
        sequenceNo: json['sequence_no'] as int? ?? 0,
        plannedStart: _date(json['planned_start']),
        plannedEnd: _date(json['planned_end']),
        orderVehicleId: '${json['order_vehicle_id']}',
        registrationNumber: '${json['registration_number']}',
        make: json['make']?.toString(),
        model: json['model']?.toString(),
        color: json['color']?.toString(),
        orderNo: '${json['order_no']}',
        serviceOrgId: '${json['service_org_id']}',
        fromAddress: '${json['from_address']}',
        toAddress: '${json['to_address']}',
        vehicleUserName: json['vehicle_user_name']?.toString(),
        vehicleUserEmail: json['vehicle_user_email']?.toString(),
        vehicleUserPhone: json['vehicle_user_phone']?.toString(),
        fromContactName: json['from_contact_name']?.toString(),
        fromContactPhone: json['from_contact_phone']?.toString(),
        toContactName: json['to_contact_name']?.toString(),
        toContactPhone: json['to_contact_phone']?.toString(),
        fromStopType: json['from_stop_type']?.toString(),
        toStopType: json['to_stop_type']?.toString(),
        fromStopTypeName: json['from_stop_type_name']?.toString(),
        toStopTypeName: json['to_stop_type_name']?.toString(),
        fromStopWaits: _flag(json['from_stop_waits']),
        toStopWaits: _flag(json['to_stop_waits']),
        fromCompanyName: json['from_company_name']?.toString(),
        toCompanyName: json['to_company_name']?.toString(),
        fromStopNotes: json['from_stop_notes']?.toString(),
        toStopNotes: json['to_stop_notes']?.toString(),
        vehicleNotes: json['vehicle_notes']?.toString(),
        vehicleExtraEmail: json['vehicle_extra_email']?.toString(),
        locationSharing: _flag(json['location_sharing']) ?? false,
        formTypeId: json['form_type_id']?.toString(),
      );

  DriverLeg copyWithStatus(String newStatus) => DriverLeg(
        legId: legId,
        legKey: legKey,
        status: newStatus,
        sequenceNo: sequenceNo,
        plannedStart: plannedStart,
        plannedEnd: plannedEnd,
        orderVehicleId: orderVehicleId,
        registrationNumber: registrationNumber,
        make: make,
        model: model,
        color: color,
        orderNo: orderNo,
        serviceOrgId: serviceOrgId,
        fromAddress: fromAddress,
        toAddress: toAddress,
        vehicleUserName: vehicleUserName,
        vehicleUserEmail: vehicleUserEmail,
        vehicleUserPhone: vehicleUserPhone,
        fromContactName: fromContactName,
        fromContactPhone: fromContactPhone,
        toContactName: toContactName,
        toContactPhone: toContactPhone,
        legCount: legCount,
        fromStopType: fromStopType,
        toStopType: toStopType,
        fromStopTypeName: fromStopTypeName,
        toStopTypeName: toStopTypeName,
        fromStopWaits: fromStopWaits,
        toStopWaits: toStopWaits,
        previousLegStatus: previousLegStatus,
        fromCompanyName: fromCompanyName,
        toCompanyName: toCompanyName,
        fromStopNotes: fromStopNotes,
        toStopNotes: toStopNotes,
        vehicleNotes: vehicleNotes,
        vehicleExtraEmail: vehicleExtraEmail,
        locationSharing: locationSharing,
        formTypeId: formTypeId,
      );
}

String _place(String? company, String address) {
  final name = company?.trim() ?? '';
  return name.isEmpty ? address : '$name – $address';
}

/// Egy autó útjai mindig egymás után, sorszám szerint (a felvétel, pl. a körfuvar
/// odaútja elöl); az autók egymás közti sorrendjét [compareVehicles] adja az
/// autó első útja alapján.
List<DriverLeg> groupByVehicle(List<DriverLeg> legs, int Function(DriverLeg a, DriverLeg b) compareVehicles) {
  final groups = <String, List<DriverLeg>>{};
  for (final leg in legs) {
    groups.putIfAbsent(leg.orderVehicleId, () => []).add(leg);
  }
  final ordered = groups.values.map((group) => group..sort((a, b) => a.sequenceNo.compareTo(b.sequenceNo))).toList()
    ..sort((a, b) => compareVehicles(a.first, b.first));
  return [for (final group in ordered) ...group];
}

class FormFieldConfig {
  const FormFieldConfig({
    required this.formTypeId,
    required this.fieldDefinitionId,
    required this.code,
    required this.name,
    required this.dataType,
    required this.required,
    required this.sortOrder,
    required this.phase,
    this.description,
    this.unit,
    this.options = const [],
  });

  final String formTypeId;
  final String fieldDefinitionId;
  final String code;
  final String name;
  final String dataType;
  final bool required;
  final int sortOrder;
  final String phase;
  final String? description;
  final String? unit;
  final List<FormOption> options;
}

class FormOption {
  const FormOption({required this.id, required this.code, required this.label, required this.sortOrder});
  final String id;
  final String code;
  final String label;
  final int sortOrder;
}

class FormTypeConfig {
  const FormTypeConfig({
    required this.id,
    required this.serviceOrgId,
    required this.code,
    required this.name,
    this.description,
    required this.fields,
    required this.photoRequirements,
    this.isDefault = false,
  });
  final String id;
  final String serviceOrgId;
  final String code;
  final String name;
  final String? description;
  /// A szolgálat alapértelmezett jegyzőkönyv-típusa (ha a megrendelés nem mond mást).
  final bool isDefault;
  final List<FormFieldConfig> fields;
  final List<PhotoRequirement> photoRequirements;
}

class PhotoRequirement {
  const PhotoRequirement({required this.photoType, required this.phase, required this.required, required this.minCount});
  final String photoType;
  final String phase;
  final bool required;
  final int minCount;
}

class PreviousInspection {
  const PreviousInspection({
    required this.serverId,
    required this.formTypeId,
    required this.inspectionType,
    required this.completedAt,
    required this.values,
    required this.damages,
    required this.photos,
  });
  final String serverId;
  final String formTypeId;
  final String inspectionType;
  final DateTime? completedAt;
  final List<Map<String, dynamic>> values;
  final List<Map<String, dynamic>> damages;
  final List<Map<String, dynamic>> photos;
}

/// MySQL BOOLEAN (1/0), JSON bool vagy szöveg → bool; hiányzó érték → null.
bool? _flag(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = '$value'.toLowerCase();
  if (text == 'true' || text == '1') return true;
  if (text == 'false' || text == '0') return false;
  return null;
}

DateTime? _date(dynamic value) {
  if (value == null || '$value'.isEmpty) return null;
  return DateTime.tryParse('$value');
}

/// Egy nyitott út a szolgálat táblájáról: kinél van, és mit tehet vele a sofőr.
class OpenLeg {
  const OpenLeg({required this.leg, this.driverName, this.mine = false, this.canClaim = false, this.canTakeOver = false});
  final DriverLeg leg;
  final String? driverName;
  final bool mine;
  final bool canClaim;
  final bool canTakeOver;

  factory OpenLeg.fromJson(Map<String, dynamic> json) => OpenLeg(
        leg: DriverLeg.fromJson(json),
        driverName: json['driverName']?.toString(),
        mine: json['mine'] == true,
        canClaim: json['canClaim'] == true,
        canTakeOver: json['canTakeOver'] == true,
      );
}
