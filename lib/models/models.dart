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
      );
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
  });
  final String id;
  final String serviceOrgId;
  final String code;
  final String name;
  final String? description;
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

DateTime? _date(dynamic value) {
  if (value == null || '$value'.isEmpty) return null;
  return DateTime.tryParse('$value');
}
