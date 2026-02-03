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
    final primaryColor = AppTheme.getPrimaryColor(context);
    final secondaryColor = AppTheme.getSecondaryColor(context);
    final errorColor = AppTheme.getErrorColor(context);
    final onPrimaryColor = AppTheme.getOnPrimaryColor(context);
    
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              primaryColor.withOpacity(0.9),
              primaryColor,
            ],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: primaryColor.withOpacity(0.5),
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
                color: onPrimaryColor,
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
                  gradient: LinearGradient(
                    colors: [
                      secondaryColor,
                      secondaryColor.withOpacity(0.7),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: secondaryColor.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.phone_in_talk,
                  size: 50,
                  color: onPrimaryColor,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              widget.receiverName,
              style: TextStyle(
                color: onPrimaryColor,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),

            Text(
              'ID: ${widget.receiverId}',
              style: TextStyle(
                color: onPrimaryColor.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              'Waiting for answer...',
              style: TextStyle(
                color: onPrimaryColor.withOpacity(0.8),
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
                  child: Icon(
                    Icons.call_end,
                    color: AppTheme.getOnErrorColor(context),
                    size: 32,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Cancel',
              style: TextStyle(
                color: onPrimaryColor,
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
