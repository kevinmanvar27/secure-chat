import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/chat_service.dart';
import '../services/call_request_service.dart';
import '../theme/app_theme.dart';
import 'dart:async';

/// Chat-only screen for private messaging without audio/video
class ChatOnlyScreen extends StatefulWidget {
  final String myId;
  final String remoteId;
  final String? roomId;
  final bool isCaller;

  const ChatOnlyScreen({
    super.key,
    required this.myId,
    required this.remoteId,
    this.roomId,
    this.isCaller = true,
  });

  @override
  State<ChatOnlyScreen> createState() => _ChatOnlyScreenState();
}

class _ChatOnlyScreenState extends State<ChatOnlyScreen> {
  final ChatService _chatService = ChatService();
  final CallRequestService _callRequestService = CallRequestService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  
  List<ChatMessage> _messages = [];
  StreamSubscription? _chatSubscription;
  bool _isConnected = false;
  String _connectionStatus = 'Connecting...';
  Timer? _sessionTimer;
  int _sessionSeconds = 0;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initializeChat();
    _startSessionTimer();
  }

  @override
  void dispose() {
    _chatSubscription?.cancel();
    _sessionTimer?.cancel();
    _messageController.dispose();
    _chatScrollController.dispose();
    _messageFocusNode.dispose();
    _chatService.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _startSessionTimer() {
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _sessionSeconds++;
        });
      }
    });
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Future<void> _initializeChat() async {
    try {
      // Start listening to chat messages
      _chatService.startListening(widget.myId, widget.remoteId);
      
      _chatSubscription = _chatService.messages.listen((messages) {
        if (mounted) {
          setState(() {
            _messages = messages.reversed.toList(); // Reverse to show newest at bottom
          });
          _scrollToBottom();
        }
      });

      setState(() {
        _isConnected = true;
        _connectionStatus = 'Connected';
      });
    } catch (e) {
      setState(() {
        _connectionStatus = 'Connection failed';
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _chatService.sendMessage(widget.myId, widget.remoteId, text);
    _messageController.clear();
    _messageFocusNode.requestFocus();
  }

  void _endChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Chat'),
        content: const Text('Are you sure you want to end this chat?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('End'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final backgroundColor = Theme.of(context).scaffoldBackgroundColor;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Chat with ${widget.remoteId}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              _isConnected ? _formatDuration(_sessionSeconds) : _connectionStatus,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.8),
              ),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _endChat,
        ),
        actions: [
          // Connection status indicator
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected ? Colors.greenAccent : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? 'Online' : 'Connecting',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: onSurfaceColor.withOpacity(0.3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start chatting!',
                          style: TextStyle(
                            fontSize: 18,
                            color: onSurfaceColor.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Send a message to begin the conversation',
                          style: TextStyle(
                            fontSize: 14,
                            color: onSurfaceColor.withOpacity(0.4),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _chatScrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message.senderId == widget.myId;
                      return _buildMessageBubble(message, isMe);
                    },
                  ),
          ),

          // Message input
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: backgroundColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, bool isMe) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? primaryColor : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Text(
          message.message,
          style: TextStyle(
            color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
