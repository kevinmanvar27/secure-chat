import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Dialog shown while waiting for call to be answered
class OutgoingCallDialog extends StatefulWidget {
  final String receiverName;
  final String receiverId;
  final VoidCallback onCancel;

  const OutgoingCallDialog({
    super.key,
    required this.receiverName,
    required this.receiverId,
    required this.onCancel,
  });

  @override
  State<OutgoingCallDialog> createState() => _OutgoingCallDialogState();
}

class _OutgoingCallDialogState extends State<OutgoingCallDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = AppTheme.getBackgroundColor(context);
    final onSurfaceColor = AppTheme.getOnSurfaceColor(context);
    final primaryColor = AppTheme.getPrimaryColor(context);
    final errorColor = AppTheme.getErrorColor(context);
    
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Calling...',
              style: TextStyle(
                color: onSurfaceColor,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),

            RotationTransition(
              turns: _rotationController,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primaryColor,
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.phone_in_talk,
                  size: 50,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              widget.receiverName,
              style: TextStyle(
                color: onSurfaceColor,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),

            Text(
              'ID: ${widget.receiverId}',
              style: TextStyle(
                color: onSurfaceColor.withOpacity(0.6),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              'Waiting for answer...',
              style: TextStyle(
                color: onSurfaceColor.withOpacity(0.7),
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 32),

            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onCancel,
                borderRadius: BorderRadius.circular(35),
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: errorColor,
                    boxShadow: [
                      BoxShadow(
                        color: errorColor.withOpacity(0.5),
                        blurRadius: 15,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Cancel',
              style: TextStyle(
                color: onSurfaceColor,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
