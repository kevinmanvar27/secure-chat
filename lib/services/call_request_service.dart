import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

/// Call types for private calls
enum CallType {
  chat,   // Chat only - no audio/video
  voice,  // Voice call - audio only
  video,  // Video call - full audio + video
}

/// Model for call request
class CallRequest {
  final String requestId;
  final String callerId;
  final String callerName;
  final String receiverId;
  final String roomId;
  final String status; // 'pending', 'accepted', 'rejected', 'cancelled'
  final int timestamp;
  final CallType callType; // Type of call requested

  CallRequest({
    required this.requestId,
    required this.callerId,
    required this.callerName,
    required this.receiverId,
    required this.roomId,
    required this.status,
    required this.timestamp,
    this.callType = CallType.video,
  });

  factory CallRequest.fromJson(String requestId, Map<dynamic, dynamic> json) {
    // Parse callType from string
    CallType type = CallType.video;
    final typeStr = json['callType'] as String?;
    if (typeStr == 'chat') type = CallType.chat;
    else if (typeStr == 'voice') type = CallType.voice;
    
    return CallRequest(
      requestId: requestId,
      callerId: json['callerId'] ?? '',
      callerName: json['callerName'] ?? 'Unknown',
      receiverId: json['receiverId'] ?? '',
      roomId: json['roomId'] ?? '',
      status: json['status'] ?? 'pending',
      timestamp: json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      callType: type,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'callerId': callerId,
      'callerName': callerName,
      'receiverId': receiverId,
      'roomId': roomId,
      'status': status,
      'timestamp': timestamp,
      'callType': callType.name, // 'chat', 'voice', or 'video'
    };
  }
}

/// NEW: Model for join request (user wants to join existing call)
class JoinRequest {
  final String requestId;
  final String userId;
  final String userName;
  final String roomId;
  final String status; // 'pending', 'accepted', 'rejected'
  final int timestamp;

  JoinRequest({
    required this.requestId,
    required this.userId,
    required this.userName,
    required this.roomId,
    required this.status,
    required this.timestamp,
  });

  factory JoinRequest.fromJson(String requestId, Map<dynamic, dynamic> json) {
    return JoinRequest(
      requestId: requestId,
      userId: json['userId'] ?? '',
      userName: json['userName'] ?? 'Unknown',
      roomId: json['roomId'] ?? '',
      status: json['status'] ?? 'pending',
      timestamp: json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'userName': userName,
      'roomId': roomId,
      'status': status,
      'timestamp': timestamp,
    };
  }
}

/// Model for call room (supports multiple users)
class CallRoom {
  final String roomId;
  final String creatorId;
  final List<String> participants;
  final int createdAt;
  final bool isActive;

  CallRoom({
    required this.roomId,
    required this.creatorId,
    required this.participants,
    required this.createdAt,
    required this.isActive,
  });

  factory CallRoom.fromJson(String roomId, Map<dynamic, dynamic> json) {
    List<String> participants = [];
    if (json['participants'] != null) {
      Map<dynamic, dynamic> participantsMap = json['participants'];
      participants = participantsMap.keys.map((k) => k.toString()).toList();
    }

    return CallRoom(
      roomId: roomId,
      creatorId: json['creatorId'] ?? '',
      participants: participants,
      createdAt: json['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
      isActive: json['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    Map<String, bool> participantsMap = {};
    for (var userId in participants) {
      participantsMap[userId] = true;
    }

    return {
      'creatorId': creatorId,
      'participants': participantsMap,
      'createdAt': createdAt,
      'isActive': isActive,
    };
  }
}

/// Service to handle call requests and multi-user rooms
class CallRequestService {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();

  final _incomingRequestController = StreamController<CallRequest>.broadcast();
  final _requestStatusController = StreamController<CallRequest>.broadcast();
  final _joinRequestController = StreamController<JoinRequest>.broadcast(); // NEW

  Stream<CallRequest> get incomingRequests => _incomingRequestController.stream;
  Stream<CallRequest> get requestStatusUpdates => _requestStatusController.stream;
  Stream<JoinRequest> get joinRequests => _joinRequestController.stream; // NEW

  StreamSubscription? _requestListener;
  StreamSubscription? _joinRequestListener; // NEW

  /// Send call request to a user
  Future<String> sendCallRequest({
    required String callerId,
    required String callerName,
    required String receiverId,
    required String roomId,
    CallType callType = CallType.video,
  }) async {
    try {
      final requestRef = _database.child('call_requests').push();
      final requestId = requestRef.key!;

      final request = CallRequest(
        requestId: requestId,
        callerId: callerId,
        callerName: callerName,
        receiverId: receiverId,
        roomId: roomId,
        status: 'pending',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        callType: callType,
      );

      await requestRef.set(request.toJson());

      Future.delayed(const Duration(seconds: 60), () async {
        final snapshot = await requestRef.get();
        if (snapshot.exists) {
          final data = snapshot.value as Map<dynamic, dynamic>;
          if (data['status'] == 'pending') {
            await requestRef.update({'status': 'cancelled'});
          }
        }
      });

      return requestId;
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  /// NEW: Send join request to existing room
  Future<String> sendJoinRequest({
    required String userId,
    required String userName,
    required String roomId,
  }) async {
    try {
      final requestRef = _database.child('join_requests').push();
      final requestId = requestRef.key!;

      final request = JoinRequest(
        requestId: requestId,
        userId: userId,
        userName: userName,
        roomId: roomId,
        status: 'pending',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      await requestRef.set(request.toJson());

      Future.delayed(const Duration(seconds: 60), () async {
        final snapshot = await requestRef.get();
        if (snapshot.exists) {
          final data = snapshot.value as Map<dynamic, dynamic>;
          if (data['status'] == 'pending') {
            await requestRef.update({'status': 'cancelled'});
          }
        }
      });

      return requestId;
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  /// Listen for incoming call requests
  void listenForIncomingRequests(String userId) {
    _requestListener?.cancel();

    _requestListener = _database
        .child('call_requests')
        .orderByChild('receiverId')
        .equalTo(userId)
        .onChildAdded
        .listen(
      (event) {
        try {
          if (event.snapshot.value != null) {
            final data = event.snapshot.value as Map<dynamic, dynamic>;
            final request = CallRequest.fromJson(event.snapshot.key!, data);

            if (request.status == 'pending') {
              _incomingRequestController.add(request);
            }
          }
        } catch (e, stackTrace) {
        }
      },
      onError: (error) {
      },
      cancelOnError: false,
    );
  }

  /// NEW: Listen for join requests to a room (for participants in call)
  void listenForJoinRequests(String roomId) {
    _joinRequestListener?.cancel();

    _joinRequestListener = _database
        .child('join_requests')
        .orderByChild('roomId')
        .equalTo(roomId)
        .onChildAdded
        .listen(
      (event) {
        try {
          if (event.snapshot.value != null) {
            final data = event.snapshot.value as Map<dynamic, dynamic>;
            final request = JoinRequest.fromJson(event.snapshot.key!, data);

            if (request.status == 'pending') {
              _joinRequestController.add(request);
            }
          }
        } catch (e, stackTrace) {
        }
      },
      onError: (error) {
      },
      cancelOnError: false,
    );
  }

  /// Listen for request status changes (for caller)
  void listenForRequestStatus(String requestId) {
    _database
        .child('call_requests/$requestId')
        .onValue
        .listen((event) {
      if (event.snapshot.value != null) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        final request = CallRequest.fromJson(requestId, data);
        _requestStatusController.add(request);
      }
    });
  }

  /// NEW: Listen for join request status (for user who sent join request)
  void listenForJoinRequestStatus(String requestId) {
    _database
        .child('join_requests/$requestId')
        .onValue
        .listen((event) {
      if (event.snapshot.value != null) {
      }
    });
  }

  /// Accept call request
  Future<void> acceptCallRequest(String requestId) async {
    try {
      await _database.child('call_requests/$requestId').update({
        'status': 'accepted',
      });
    } catch (e) {
      rethrow;
    }
  }

  /// NEW: Accept join request
  Future<void> acceptJoinRequest(String requestId, String roomId, String userId) async {
    try {
      await _database.child('join_requests/$requestId').update({
        'status': 'accepted',
      });

      await joinCallRoom(roomId, userId);
    } catch (e) {
      rethrow;
    }
  }

  /// Reject call request
  Future<void> rejectCallRequest(String requestId) async {
    try {
      await _database.child('call_requests/$requestId').update({
        'status': 'rejected',
      });
    } catch (e) {
      rethrow;
    }
  }

  /// NEW: Reject join request
  Future<void> rejectJoinRequest(String requestId) async {
    try {
      await _database.child('join_requests/$requestId').update({
        'status': 'rejected',
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Cancel call request (by caller)
  Future<void> cancelCallRequest(String requestId) async {
    try {
      await _database.child('call_requests/$requestId').update({
        'status': 'cancelled',
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Create a call room
  Future<String> createCallRoom(String creatorId) async {
    try {
      final roomRef = _database.child('call_rooms').push();
      final roomId = roomRef.key!;

      final room = CallRoom(
        roomId: roomId,
        creatorId: creatorId,
        participants: [creatorId],
        createdAt: DateTime.now().millisecondsSinceEpoch,
        isActive: true,
      );

      await roomRef.set(room.toJson());

      return roomId;
    } catch (e) {
      rethrow;
    }
  }

  /// Join a call room
  Future<void> joinCallRoom(String roomId, String userId) async {
    try {
      await _database.child('call_rooms/$roomId/participants/$userId').set(true);
    } catch (e) {
      rethrow;
    }
  }

  /// Leave a call room
  Future<void> leaveCallRoom(String roomId, String userId) async {
    try {
      await _database.child('call_rooms/$roomId/participants/$userId').remove();

      final snapshot = await _database.child('call_rooms/$roomId/participants').get();
      if (!snapshot.exists || (snapshot.value as Map).isEmpty) {
        await _database.child('call_rooms/$roomId').update({'isActive': false});
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Get room participants (stream - for continuous updates)
  Stream<List<String>> getRoomParticipants(String roomId) {
    return _database
        .child('call_rooms/$roomId/participants')
        .onValue
        .map((event) {
      if (event.snapshot.value == null) return <String>[];
      
      final participantsMap = event.snapshot.value as Map<dynamic, dynamic>;
      return participantsMap.keys.map((k) => k.toString()).toList();
    });
  }
  
  /// Get room participants once (synchronous - for initial load)
  Future<List<String>> getRoomParticipantsOnce(String roomId) async {
    try {
      final snapshot = await _database.child('call_rooms/$roomId/participants').get();
      if (!snapshot.exists || snapshot.value == null) {
        return <String>[];
      }
      
      final participantsMap = snapshot.value as Map<dynamic, dynamic>;
      return participantsMap.keys.map((k) => k.toString()).toList();
    } catch (e) {
      return <String>[];
    }
  }

  /// Get call room info
  Future<CallRoom?> getCallRoom(String roomId) async {
    try {
      final snapshot = await _database.child('call_rooms/$roomId').get();
      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        return CallRoom.fromJson(roomId, data);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// NEW: Get room info
  Future<CallRoom?> getRoomInfo(String roomId) async {
    try {
      final snapshot = await _database.child('call_rooms/$roomId').get();
      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        return CallRoom.fromJson(roomId, data);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// NEW: Check if room exists and is active
  Future<bool> isRoomActive(String roomId) async {
    try {
      final snapshot = await _database.child('call_rooms/$roomId').get();
      
      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        return data['isActive'] == true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Get all active rooms
  Future<List<CallRoom>> getActiveRooms() async {
    try {
      final snapshot = await _database
          .child('call_rooms')
          .orderByChild('isActive')
          .equalTo(true)
          .get();

      if (!snapshot.exists || snapshot.value == null) {
        return [];
      }

      final roomsMap = snapshot.value as Map<dynamic, dynamic>;
      final rooms = <CallRoom>[];

      for (var entry in roomsMap.entries) {
        final data = entry.value as Map<dynamic, dynamic>;
        final room = CallRoom.fromJson(entry.key.toString(), data);
        if (room.isActive && room.participants.isNotEmpty) {
          rooms.add(room);
        }
      }

      return rooms;
    } catch (e) {
      return [];
    }
  }

  /// Clean up old requests (older than 5 minutes)
  Future<void> cleanupOldRequests() async {
    try {
      final fiveMinutesAgo = DateTime.now().millisecondsSinceEpoch - (5 * 60 * 1000);
      final snapshot = await _database.child('call_requests').get();

      if (snapshot.exists) {
        final requests = snapshot.value as Map<dynamic, dynamic>;
        for (var entry in requests.entries) {
          final data = entry.value as Map<dynamic, dynamic>;
          if (data['timestamp'] < fiveMinutesAgo) {
            await _database.child('call_requests/${entry.key}').remove();
          }
        }
      }
    } catch (e) {
    }
  }

  /// Dispose resources
  void dispose() {
    _requestListener?.cancel();
    _joinRequestListener?.cancel();
    _incomingRequestController.close();
    _requestStatusController.close();
    _joinRequestController.close();
  }
}
