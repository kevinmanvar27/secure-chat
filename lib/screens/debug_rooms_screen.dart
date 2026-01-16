import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';

class DebugRoomsScreen extends StatefulWidget {
  const DebugRoomsScreen({super.key});

  @override
  State<DebugRoomsScreen> createState() => _DebugRoomsScreenState();
}

class _DebugRoomsScreenState extends State<DebugRoomsScreen> {
  final _database = FirebaseDatabase.instance.ref();
  List<Map<String, dynamic>> _rooms = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    try {
      final snapshot = await _database.child('call_rooms').get();
      
      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        final rooms = <Map<String, dynamic>>[];
        
        data.forEach((key, value) {
          final roomData = value as Map<dynamic, dynamic>;
          rooms.add({
            'roomId': key,
            'creatorId': roomData['creatorId'] ?? 'N/A',
            'isActive': roomData['isActive'] ?? false,
            'createdAt': roomData['createdAt'] ?? 0,
            'participants': roomData['participants'] ?? {},
          });
        });
        
        setState(() {
          _rooms = rooms;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug: All Rooms'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadRooms();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _rooms.isEmpty
              ? const Center(
                  child: Text(
                    'No rooms found in database',
                    style: TextStyle(fontSize: 16),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rooms.length,
                  itemBuilder: (context, index) {
                    final room = _rooms[index];
                    final participants = room['participants'] as Map<dynamic, dynamic>;
                    final participantsList = participants.keys.toList();
                    
                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Room ID: ${room['roomId']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 20),
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(text: room['roomId']),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Room ID copied'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('Creator: ${room['creatorId']}'),
                            Text(
                              'Status: ${room['isActive'] ? 'Active' : 'Inactive'}',
                              style: TextStyle(
                                color: room['isActive'] ? Colors.green : Colors.red,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Created: ${DateTime.fromMillisecondsSinceEpoch(room['createdAt']).toString()}',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Participants (${participantsList.length}):',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            ...participantsList.map((p) => Text('  • $p')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
