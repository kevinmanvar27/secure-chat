import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

class ChatMessage {
  final String id;
  final String senderId;
  final String receiverId;
  final String message;
  final DateTime timestamp;
  final bool isRead;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.message,
    required this.timestamp,
    this.isRead = false,
  });

  factory ChatMessage.fromMap(String id, Map<dynamic, dynamic> map) {
    return ChatMessage(
      id: id,
      senderId: map['senderId'] ?? '',
      receiverId: map['receiverId'] ?? '',
      message: map['message'] ?? '',
      timestamp: DateTime.parse(map['timestamp'] ?? DateTime.now().toIso8601String()),
      isRead: map['isRead'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'isRead': isRead,
    };
  }
}

class RoomChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String message;
  final DateTime timestamp;

  RoomChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.message,
    required this.timestamp,
  });

  factory RoomChatMessage.fromMap(String id, Map<dynamic, dynamic> map) {
    return RoomChatMessage(
      id: id,
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? 'Unknown',
      message: map['message'] ?? '',
      timestamp: map['timestamp'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'senderName': senderName,
      'message': message,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }
}

class ChatService {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final _messagesController = StreamController<List<ChatMessage>>.broadcast();
  final _roomMessagesController = StreamController<List<RoomChatMessage>>.broadcast();
  
  Stream<List<ChatMessage>> get messages => _messagesController.stream;
  Stream<List<RoomChatMessage>> get roomMessages => _roomMessagesController.stream;
  
  StreamSubscription? _messagesSubscription;
  StreamSubscription? _roomMessagesSubscription;

  String _getChatRoomId(String userId1, String userId2) {
    List<String> ids = [userId1, userId2];
    ids.sort(); // Sort to ensure same room ID regardless of order
    return '${ids[0]}_${ids[1]}';
  }

  void startListening(String myId, String remoteId) {
    String chatRoomId = _getChatRoomId(myId, remoteId);
    
    _messagesSubscription = _database
        .child('chats/$chatRoomId/messages')
        .orderByChild('timestamp')
        .onValue
        .listen((event) {
      if (event.snapshot.value != null) {
        Map<dynamic, dynamic> messagesMap = event.snapshot.value as Map<dynamic, dynamic>;
        List<ChatMessage> messagesList = [];
        
        messagesMap.forEach((key, value) {
          if (value is Map) {
            messagesList.add(ChatMessage.fromMap(key, value));
          }
        });
        
        messagesList.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        
        _messagesController.add(messagesList);
      } else {
        _messagesController.add([]);
      }
    });
  }

  Future<void> sendMessage(String myId, String remoteId, String message) async {
    if (message.trim().isEmpty) return;
    
    String chatRoomId = _getChatRoomId(myId, remoteId);
    
    try {
      ChatMessage chatMessage = ChatMessage(
        id: '',
        senderId: myId,
        receiverId: remoteId,
        message: message.trim(),
        timestamp: DateTime.now(),
        isRead: false,
      );
      
      await _database
          .child('chats/$chatRoomId/messages')
          .push()
          .set(chatMessage.toMap());
    } catch (e) {
      rethrow;
    }
  }

  Future<void> markMessagesAsRead(String myId, String remoteId) async {
    String chatRoomId = _getChatRoomId(myId, remoteId);
    
    try {
      final snapshot = await _database
          .child('chats/$chatRoomId/messages')
          .orderByChild('receiverId')
          .equalTo(myId)
          .once();
      
      if (snapshot.snapshot.value != null) {
        Map<dynamic, dynamic> messages = snapshot.snapshot.value as Map<dynamic, dynamic>;
        
        for (var entry in messages.entries) {
          await _database
              .child('chats/$chatRoomId/messages/${entry.key}')
              .update({'isRead': true});
        }
      }
    } catch (e) {
    }
  }

  Future<void> clearChatHistory(String myId, String remoteId) async {
    String chatRoomId = _getChatRoomId(myId, remoteId);
    
    try {
      await _database.child('chats/$chatRoomId').remove();
    } catch (e) {
    }
  }


  /// Start listening to room chat messages (for group calls)
  void startListeningToRoom(String roomId) {
    _roomMessagesSubscription?.cancel();
    
    _roomMessagesSubscription = _database
        .child('room_chats/$roomId/messages')
        .orderByChild('timestamp')
        .onValue
        .listen((event) {
      if (event.snapshot.value != null) {
        Map<dynamic, dynamic> messagesMap = event.snapshot.value as Map<dynamic, dynamic>;
        List<RoomChatMessage> messagesList = [];
        
        messagesMap.forEach((key, value) {
          if (value is Map) {
            messagesList.add(RoomChatMessage.fromMap(key, value));
          }
        });
        
        messagesList.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        
        _roomMessagesController.add(messagesList);
      } else {
        _roomMessagesController.add([]);
      }
    });
  }

  /// Send a message to room (for group calls)
  Future<void> sendMessageToRoom(String roomId, String senderId, String senderName, String message) async {
    if (message.trim().isEmpty) return;
    
    try {
      RoomChatMessage chatMessage = RoomChatMessage(
        id: '',
        senderId: senderId,
        senderName: senderName,
        message: message.trim(),
        timestamp: DateTime.now(),
      );
      
      await _database
          .child('room_chats/$roomId/messages')
          .push()
          .set(chatMessage.toMap());
    } catch (e) {
      rethrow;
    }
  }

  /// Clear room chat history
  Future<void> clearRoomChatHistory(String roomId) async {
    try {
      await _database.child('room_chats/$roomId').remove();
    } catch (e) {
    }
  }

  /// Stop listening to room messages
  void stopListeningToRoom() {
    _roomMessagesSubscription?.cancel();
    _roomMessagesSubscription = null;
  }

  void dispose() {
    _messagesSubscription?.cancel();
    _roomMessagesSubscription?.cancel();
    _messagesController.close();
    _roomMessagesController.close();
  }
}
