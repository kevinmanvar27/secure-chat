import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Dialog to join an existing room via Room ID
class JoinRoomDialog extends StatefulWidget {
  final String myId;
  final Function(String roomId) onJoin;

  const JoinRoomDialog({
    super.key,
    required this.myId,
    required this.onJoin,
  });

  @override
  State<JoinRoomDialog> createState() => _JoinRoomDialogState();
}

class _JoinRoomDialogState extends State<JoinRoomDialog> {
  final TextEditingController _roomIdController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _roomIdController.dispose();
    super.dispose();
  }

  void _handleJoin() async {
    final roomId = _roomIdController.text.trim();
    
    if (roomId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Room ID')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await widget.onJoin(roomId);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to join room: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = AppTheme.getPrimaryColor(context);
    final secondaryColor = AppTheme.getSecondaryColor(context);
    final surfaceColor = AppTheme.getSurfaceColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final backgroundColor = AppTheme.getBackgroundColor(context);
    
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              secondaryColor.withOpacity(0.1),
              primaryColor.withOpacity(0.1),
            ],
          ),
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: secondaryColor.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.meeting_room,
                size: 48,
                color: secondaryColor,
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'Join Call',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: onSurfaceColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the Room ID to join',
              style: TextStyle(
                fontSize: 14,
                color: onSurfaceColor.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _roomIdController,
              decoration: InputDecoration(
                labelText: 'Room ID',
                hintText: 'Enter room ID',
                prefixIcon: Icon(Icons.vpn_key, color: primaryColor),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: surfaceColor,
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: BorderSide(color: primaryColor),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleJoin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: secondaryColor,
                      foregroundColor: AppTheme.getOnPrimaryColor(context),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    child: _isLoading
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppTheme.getOnPrimaryColor(context),
                              ),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.login, size: 20),
                              const SizedBox(width: 8),
                              const Text(
                                'Join',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
