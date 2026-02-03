import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import 'main_navigation_screen.dart';

class TutorialScreen extends StatefulWidget {
  final bool isFirstTime;
  
  const TutorialScreen({super.key, this.isFirstTime = true});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  late final List<TutorialPage> _pages = [
    TutorialPage(
      icon: Icons.security_rounded,
      title: 'Secure & Private',
      description: 'End-to-end encrypted video calls. Your conversations stay private.',
      color: Theme.of(context).colorScheme.primaryContainer,
    ),
    TutorialPage(
      icon: Icons.person_search_rounded,
      title: 'Call by ID',
      description: 'Share your unique ID with friends. Enter their ID to start a secure video call instantly.',
      color: Theme.of(context).colorScheme.primaryContainer,
    ),
    TutorialPage(
      icon: Icons.shuffle_rounded,
      title: 'Random Chat',
      description: 'Meet new people! Tap Start in the Random tab to connect with someone random for a video chat.',
      color: Theme.of(context).colorScheme.primaryContainer,
    ),
    // Rating page - second to last
    TutorialPage(
      icon: Icons.star_rounded,
      title: 'Rate Us',
      description: 'Enjoying the app? Tap below to rate us on the Play Store and help us improve!',
      color: Theme.of(context).colorScheme.primaryContainer,
      isRatingPage: true,
    ),
    TutorialPage(
      icon: Icons.contacts_rounded,
      title: 'Find Friends',
      description: 'See which contacts have the app and call them directly. Invite others to join you on SecureChat.',
      color: Theme.of(context).colorScheme.primaryContainer,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finishTutorial();
    }
  }

  void _skip() {
    _finishTutorial();
  }

  Future<void> _openPlayStoreRating() async {
    // Replace 'com.yourapp.package' with your actual package name
    const String packageName = 'com.rektech.chatapp';
    
    // Try to open Play Store app directly with rating dialog
    final Uri playStoreUri = Uri.parse('market://details?id=$packageName');
    final Uri webUri = Uri.parse('https://play.google.com/store/apps/details?id=$packageName');
    
    try {
      // Try to launch Play Store app first
      if (await canLaunchUrl(playStoreUri)) {
        await launchUrl(playStoreUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(webUri)) {
        // Fallback to web browser
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // If all fails, try web URL
      try {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      } catch (_) {
        // Silently fail
      }
    }
  }

  Future<void> _finishTutorial() async {
    if (widget.isFirstTime) {
      // Mark first launch complete
      await SessionManager().setFirstLaunchComplete();
      
      // Navigate to main app
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const MainNavigationScreen(),
          ),
        );
      }
    } else {
      // Just pop back to previous screen
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextButton(
                  onPressed: _skip,
                  child: Text(
                    widget.isFirstTime ? 'Skip' : 'Close',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ),

            // Page content
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemBuilder: (context, index) {
                  return _buildPage(_pages[index]);
                },
              ),
            ),

            // Page indicators
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _pages.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentPage == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? _pages[index].color
                          : AppTheme.getDisabledColor(context).withOpacity(0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),

            // Next/Get Started button
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _nextPage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _pages[_currentPage].color,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _currentPage == _pages.length - 1 ? 'Get Started' : 'Next',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(TutorialPage page) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Make the icon tappable for rating page
          GestureDetector(
            onTap: page.isRatingPage ? _openPlayStoreRating : null,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: page.color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                page.icon,
                size: 80,
                color: page.color,
              ),
            ),
          ),
          const SizedBox(height: 48),
          Text(
            page.title,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            page.description,
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          // Add a "Rate Now" button for the rating page
          if (page.isRatingPage) ...[
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: _openPlayStoreRating,
              icon: Icon(Icons.star, color: AppTheme.getWarningColor(context)),
              label: const Text(
                'Rate Now',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primaryContainer,
                // side: BorderSide(color: Theme.of(context).colorScheme.primaryContainer, width: 2),
                // foregroundColor: Colors.amber,
                side: BorderSide(color: AppTheme.getWarningColor(context), width: 2),
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class TutorialPage {
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final bool isRatingPage;

  TutorialPage({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    this.isRatingPage = false,
  });
}
