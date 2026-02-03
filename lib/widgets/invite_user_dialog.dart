import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Dialog to invite a user to join the call (send call request from active call)
class InviteUserDialog extends StatefulWidget {
  final String roomId;
  final String currentUserId;
  final Function(String userId) onInvite;

  const InviteUserDialog({
    super.key,
    required this.roomId,
    required this.currentUserId,
    required this.onInvite,
  });

  @override
  State<InviteUserDialog> createState() => _InviteUserDialogState();
}

class _InviteUserDialogState extends State<InviteUserDialog> {
  final TextEditingController _userIdController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }

  void _handleInvite() async {
    final userId = _userIdController.text.trim();
    
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter a User ID'),
          backgroundColor: AppTheme.getPrimaryColor(context),
        ),
      );
      return;
    }

    if (userId == widget.currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('You cannot invite yourself!'),
          backgroundColor: AppTheme.getPrimaryColor(context),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await widget.onInvite(userId);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
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
              primaryColor.withOpacity(0.1),
              secondaryColor.withOpacity(0.1),
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
                color: primaryColor.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.person_add,
                size: 48,
                color: primaryColor,
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'Invite User',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: onSurfaceColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add someone to this call',
              style: TextStyle(
                fontSize: 14,
                color: onSurfaceColor.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _userIdController,
              decoration: InputDecoration(
                labelText: 'User ID',
                hintText: 'Enter user ID to invite',
                prefixIcon: Icon(Icons.person, color: primaryColor),
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
                    onPressed: _isLoading ? null : _handleInvite,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
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
                              const Icon(Icons.send, size: 20),
                              const SizedBox(width: 8),
                              const Text(
                                'Invite',
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
