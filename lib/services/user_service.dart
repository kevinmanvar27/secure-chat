import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

/// Model for registered user
class AppUser {
  final String odid;
  final String odname;
  final String phoneNumber;
  final String odphoneHash; // Hashed phone number for privacy
  final int createdAt;
  final int lastSeen;
  final bool isOnline;
  final bool isInRandomPool;

  AppUser({
    required this.odid,
    required this.odname,
    required this.phoneNumber,
    required this.odphoneHash,
    required this.createdAt,
    required this.lastSeen,
    this.isOnline = false,
    this.isInRandomPool = false,
  });

  factory AppUser.fromJson(String odid, Map<dynamic, dynamic> json) {
    return AppUser(
      odid: odid,
      odname: json['odname'] ?? '',
      phoneNumber: json['phoneNumber'] ?? '',
      odphoneHash: json['odphoneHash'] ?? '',
      createdAt: json['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
      lastSeen: json['lastSeen'] ?? DateTime.now().millisecondsSinceEpoch,
      isOnline: json['isOnline'] ?? false,
      isInRandomPool: json['isInRandomPool'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'odname': odname,
      'phoneNumber': phoneNumber,
      'odphoneHash': odphoneHash,
      'createdAt': createdAt,
      'lastSeen': lastSeen,
      'isOnline': isOnline,
      'isInRandomPool': isInRandomPool,
    };
  }
}

/// Service to manage users in Firebase
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  
  StreamSubscription? _randomPoolListener;
  final _randomUserController = StreamController<AppUser>.broadcast();
  Stream<AppUser> get randomUserFound => _randomUserController.stream;

  /// Generate a simple hash for phone number (for matching contacts)
  String _hashPhoneNumber(String phone) {
    // Normalize phone number - remove spaces, dashes, country code variations
    String normalized = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    // Keep last 10 digits
    if (normalized.length > 10) {
      normalized = normalized.substring(normalized.length - 10);
    }
    // Simple hash - in production use proper hashing
    int hash = 0;
    for (int i = 0; i < normalized.length; i++) {
      hash = ((hash << 5) - hash) + normalized.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).toUpperCase();
  }

  /// Register or update user in Firebase
  Future<void> registerUser({
    required String odid,
    required String odname,
    required String phoneNumber,
  }) async {
    try {
      final odphoneHash = _hashPhoneNumber(phoneNumber);
      
      final userRef = _database.child('users/$odid');
      final snapshot = await userRef.get();
      
      if (snapshot.exists) {
        // Update existing user
        await userRef.update({
          'odname': odname,
          'phoneNumber': phoneNumber,
          'odphoneHash': odphoneHash,
          'lastSeen': ServerValue.timestamp,
          'isOnline': true,
        });
      } else {
        // Create new user
        final user = AppUser(
          odid: odid,
          odname: odname,
          phoneNumber: phoneNumber,
          odphoneHash: odphoneHash,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          lastSeen: DateTime.now().millisecondsSinceEpoch,
          isOnline: true,
          isInRandomPool: false,
        );
        await userRef.set(user.toJson());
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Set user online status
  Future<void> setUserOnline(String odid, bool isOnline) async {
    try {
      await _database.child('users/$odid').update({
        'isOnline': isOnline,
        'lastSeen': ServerValue.timestamp,
      });
    } catch (e) {
      // Ignore errors
    }
  }

  /// Join random pool (user is available for random calls)
  Future<void> joinRandomPool(String odid) async {
    try {
      await _database.child('users/$odid').update({
        'isInRandomPool': true,
        'randomJoinedAt': ServerValue.timestamp,
      });
      
      // Also add to random_pool for faster queries
      await _database.child('random_pool/$odid').set({
        'joinedAt': ServerValue.timestamp,
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Leave random pool
  Future<void> leaveRandomPool(String odid) async {
    try {
      await _database.child('users/$odid').update({
        'isInRandomPool': false,
      });
      await _database.child('random_pool/$odid').remove();
    } catch (e) {
      // Ignore errors
    }
  }

  /// Find a random user to connect with (excluding self)
  Future<AppUser?> findRandomUser(String myodid) async {
    try {
      final snapshot = await _database.child('random_pool').get();
      
      if (!snapshot.exists || snapshot.value == null) {
        return null;
      }
      
      final poolMap = snapshot.value as Map<dynamic, dynamic>;
      final availableUsers = poolMap.keys
          .map((k) => k.toString())
          .where((odid) => odid != myodid)
          .toList();
      
      if (availableUsers.isEmpty) {
        return null;
      }
      
      // Pick random user
      availableUsers.shuffle();
      final randomodid = availableUsers.first;
      
      // Get user details
      final userSnapshot = await _database.child('users/$randomodid').get();
      if (userSnapshot.exists) {
        return AppUser.fromJson(randomodid, userSnapshot.value as Map<dynamic, dynamic>);
      }
      
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Listen for random users joining the pool
  void listenForRandomUsers(String myodid, Function(AppUser) onUserFound) {
    _randomPoolListener?.cancel();
    
    _randomPoolListener = _database
        .child('random_pool')
        .onChildAdded
        .listen((event) async {
      final odid = event.snapshot.key;
      if (odid != null && odid != myodid) {
        // Get user details
        final userSnapshot = await _database.child('users/$odid').get();
        if (userSnapshot.exists) {
          final user = AppUser.fromJson(odid, userSnapshot.value as Map<dynamic, dynamic>);
          onUserFound(user);
        }
      }
    });
  }

  /// Stop listening for random users
  void stopListeningForRandomUsers() {
    _randomPoolListener?.cancel();
    _randomPoolListener = null;
  }

  /// Check if a phone number is registered (by hash)
  Future<List<AppUser>> findUsersByPhoneHashes(List<String> phoneNumbers) async {
    try {
      final hashes = phoneNumbers.map((p) => _hashPhoneNumber(p)).toSet();
      final List<AppUser> foundUsers = [];
      
      final snapshot = await _database.child('users').get();
      
      if (snapshot.exists && snapshot.value != null) {
        final usersMap = snapshot.value as Map<dynamic, dynamic>;
        
        for (var entry in usersMap.entries) {
          final userData = entry.value as Map<dynamic, dynamic>;
          final userHash = userData['odphoneHash'] as String?;
          
          if (userHash != null && hashes.contains(userHash)) {
            foundUsers.add(AppUser.fromJson(entry.key.toString(), userData));
          }
        }
      }
      
      return foundUsers;
    } catch (e) {
      return [];
    }
  }

  /// Get user by ID
  Future<AppUser?> getUserById(String odid) async {
    try {
      final snapshot = await _database.child('users/$odid').get();
      if (snapshot.exists) {
        return AppUser.fromJson(odid, snapshot.value as Map<dynamic, dynamic>);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Store contact in Firebase (for the user's contact list)
  Future<void> saveUserContacts(String odid, List<Map<String, String>> contacts) async {
    try {
      final contactsMap = <String, dynamic>{};
      for (var contact in contacts) {
        final hash = _hashPhoneNumber(contact['phone'] ?? '');
        contactsMap[hash] = {
          'name': contact['name'],
          'phone': contact['phone'],
        };
      }
      await _database.child('user_contacts/$odid').set(contactsMap);
    } catch (e) {
      // Ignore errors
    }
  }

  /// Clear ALL user data from Firebase when app closes
  /// This removes: user data, contacts, presence, random pool, webrtc signals, messages
  Future<void> clearAllUserData(String odid) async {
    try {
      // Remove user from database
      await _database.child('users/$odid').remove();
      
      // Remove user contacts
      await _database.child('user_contacts/$odid').remove();
      
      // Remove from random pool
      await _database.child('random_pool/$odid').remove();
      
      // Remove presence
      await _database.child('presence/$odid').remove();
      
      // Remove any call requests
      await _database.child('call_requests/$odid').remove();
      
      // Remove any webrtc signaling data involving this user
      // Note: Room IDs contain user IDs, so we clean up rooms containing this user
      final signalingSnapshot = await _database.child('webrtc_signaling').get();
      if (signalingSnapshot.exists && signalingSnapshot.value != null) {
        final signalingMap = signalingSnapshot.value as Map<dynamic, dynamic>;
        for (var roomId in signalingMap.keys) {
          if (roomId.toString().contains(odid)) {
            await _database.child('webrtc_signaling/$roomId').remove();
          }
        }
      }
      
      // Remove random matches involving this user
      final matchesSnapshot = await _database.child('random_matches').get();
      if (matchesSnapshot.exists && matchesSnapshot.value != null) {
        final matchesMap = matchesSnapshot.value as Map<dynamic, dynamic>;
        for (var roomId in matchesMap.keys) {
          if (roomId.toString().contains(odid)) {
            await _database.child('random_matches/$roomId').remove();
          }
        }
      }
      
      // Remove any messages involving this user
      final messagesSnapshot = await _database.child('messages').get();
      if (messagesSnapshot.exists && messagesSnapshot.value != null) {
        final messagesMap = messagesSnapshot.value as Map<dynamic, dynamic>;
        for (var roomId in messagesMap.keys) {
          if (roomId.toString().contains(odid)) {
            await _database.child('messages/$roomId').remove();
          }
        }
      }
      
      print('All user data cleared for: $odid');
    } catch (e) {
      print('Error clearing user data: $e');
    }
  }

  void dispose() {
    _randomPoolListener?.cancel();
    _randomUserController.close();
  }
}
