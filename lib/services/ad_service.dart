import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

/// Service to manage Google Ads throughout the app
class AdService {
  static final AdService _instance = AdService._internal();
  factory AdService() => _instance;
  AdService._internal();

  // Test Ad Unit IDs (Replace with your real IDs for production)
  // Banner Ad
  static const String _testBannerAdUnitId = 'ca-app-pub-3940256099942544/9214589741';
  // Interstitial Ad
  static const String _testInterstitialAdUnitId = 'ca-app-pub-3940256099942544/1033173712';
  
  // Production Ad Unit IDs (Replace these with your actual AdMob IDs)
  static const String _prodBannerAdUnitId = 'ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX';
  static const String _prodInterstitialAdUnitId = 'ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX';

  // Use test ads in debug mode
  String get bannerAdUnitId => kDebugMode ? _testBannerAdUnitId : _prodBannerAdUnitId;
  String get interstitialAdUnitId => kDebugMode ? _testInterstitialAdUnitId : _prodInterstitialAdUnitId;

  InterstitialAd? _interstitialAd;
  bool _isInterstitialAdReady = false;
  
  // Track if ad is currently showing - IMPORTANT for blocking connections
  bool _isShowingAd = false;
  Completer<bool>? _adCompleter;
  
  // Counters for ad frequency
  int _randomMatchCount = 0;
  int _privateCallCount = 0;
  int _inviteCount = 0;
  
  // User status
  bool _isNewUser = true;
  DateTime? _firstUseDate;
  
  // Ad frequency settings - AGGRESSIVE for more revenue
  static const int _newUserAdFrequency = 2; // Show ad every 2 actions for new users
  static const int _regularUserAdFrequency = 1; // Show ad every action for regular users
  static const int _newUserDays = 3; // User is "new" for first 3 days

  // Firebase ads control - DEFAULT TO FALSE (respect admin panel)
  bool _adsEnabled = false;
  StreamSubscription? _adsEnabledSubscription;
  DatabaseReference? _database;

  bool get isInterstitialAdReady => _isInterstitialAdReady && _adsEnabled;
  bool get adsEnabled => _adsEnabled;
  
  /// Check if ad is currently being shown - use this to block other operations
  bool get isShowingAd => _isShowingAd;

  /// Initialize the ad service - respects admin panel setting
  Future<void> initialize() async {
    try {
      // Initialize Firebase reference FIRST
      _database = FirebaseDatabase.instance.ref();
      
      // Load ads setting from Firebase FIRST (with timeout)
      // Default to FALSE if timeout/error - respect admin setting
      await _loadAdsEnabledFromFirebase().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          // On timeout, keep ads DISABLED (safer default)
          _adsEnabled = false;
          print('⚠️ Ads setting timeout - defaulting to DISABLED');
        },
      );
      
      // Listen for real-time changes
      _listenToAdsEnabled();
      
      // Only initialize MobileAds if ads are enabled
      if (_adsEnabled) {
        unawaited(MobileAds.instance.initialize().then((_) {
          loadInterstitialAd();
        }));
        
        // Load user status in background
        unawaited(_loadUserStatus());
      }
      
      print('📢 Ads initialized - enabled: $_adsEnabled');
      
    } catch (e) {
      // If anything fails, default to DISABLED (respect admin)
      _adsEnabled = false;
      print('❌ Ads init error: $e - defaulting to DISABLED');
    }
  }

  /// Load ads enabled status from Firebase
  Future<void> _loadAdsEnabledFromFirebase() async {
    try {
      if (_database == null) return;
      
      final snapshot = await _database!.child('app_settings/ads_enabled').get();
      if (snapshot.exists && snapshot.value != null) {
        _adsEnabled = snapshot.value as bool? ?? false;
        print('📢 Ads setting from Firebase: $_adsEnabled');
      } else {
        // If not set in Firebase, default to DISABLED
        _adsEnabled = false;
        print('📢 Ads setting not found - defaulting to DISABLED');
      }
    } catch (e) {
      _adsEnabled = false; // Default to DISABLED on error
      print('❌ Error loading ads setting: $e');
    }
  }

  /// Listen to ads enabled changes in real-time
  void _listenToAdsEnabled() {
    if (_database == null) return;
    _adsEnabledSubscription?.cancel();
    _adsEnabledSubscription = _database!.child('app_settings/ads_enabled').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _adsEnabled = event.snapshot.value as bool? ?? false;
        print('📢 Ads setting changed: $_adsEnabled');
        if (_adsEnabled && !_isInterstitialAdReady) {
          loadInterstitialAd();
        }
      }
    }, onError: (e) {
      print('❌ Ads listener error: $e');
    });
  }

  /// Set ads enabled status (for admin panel)
  Future<void> setAdsEnabled(bool enabled) async {
    try {
      if (_database == null) return;
      await _database!.child('app_settings/ads_enabled').set(enabled);
      _adsEnabled = enabled;
      if (enabled && !_isInterstitialAdReady) {
        loadInterstitialAd();
      }
    } catch (e) {
      // Handle error silently
    }
  }

  /// Load user status from preferences
  Future<void> _loadUserStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final firstUseTimestamp = prefs.getInt('first_use_timestamp');
    
    if (firstUseTimestamp == null) {
      // First time user
      _firstUseDate = DateTime.now();
      await prefs.setInt('first_use_timestamp', _firstUseDate!.millisecondsSinceEpoch);
      _isNewUser = true;
    } else {
      _firstUseDate = DateTime.fromMillisecondsSinceEpoch(firstUseTimestamp);
      final daysSinceFirstUse = DateTime.now().difference(_firstUseDate!).inDays;
      _isNewUser = daysSinceFirstUse < _newUserDays;
    }
    
    // Load counters
    _randomMatchCount = prefs.getInt('random_match_count') ?? 0;
    _privateCallCount = prefs.getInt('private_call_count') ?? 0;
    _inviteCount = prefs.getInt('invite_count') ?? 0;
  }

  /// Save counters to preferences
  Future<void> _saveCounters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('random_match_count', _randomMatchCount);
    await prefs.setInt('private_call_count', _privateCallCount);
    await prefs.setInt('invite_count', _inviteCount);
  }

  /// Get ad frequency based on user status
  int get _adFrequency => _isNewUser ? _newUserAdFrequency : _regularUserAdFrequency;

  /// Load interstitial ad
  void loadInterstitialAd() {
    if (!_adsEnabled) return;
    
    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _isInterstitialAdReady = true;
          
          _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              _isShowingAd = false;
              _adCompleter?.complete(true);
              _adCompleter = null;
              ad.dispose();
              _isInterstitialAdReady = false;
              loadInterstitialAd(); // Load next ad
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              _isShowingAd = false;
              _adCompleter?.complete(false);
              _adCompleter = null;
              ad.dispose();
              _isInterstitialAdReady = false;
              loadInterstitialAd();
            },
          );
        },
        onAdFailedToLoad: (error) {
          _isInterstitialAdReady = false;
          // Retry after delay
          Future.delayed(const Duration(seconds: 30), loadInterstitialAd);
        },
      ),
    );
  }

  /// Check if should show ad for random match
  bool shouldShowAdForRandomMatch() {
    if (!_adsEnabled) return false;
    _randomMatchCount++;
    _saveCounters();
    return _randomMatchCount % _adFrequency == 0;
  }

  /// Check if should show ad for private call - EVERY CALL for regular users
  bool shouldShowAdForPrivateCall() {
    if (!_adsEnabled) return false;
    _privateCallCount++;
    _saveCounters();
    return _privateCallCount % (_isNewUser ? 2 : 1) == 0;
  }

  /// Check if should show ad for invite - EVERY INVITE for regular users
  bool shouldShowAdForInvite() {
    if (!_adsEnabled) return false;
    _inviteCount++;
    _saveCounters();
    return _inviteCount % (_isNewUser ? 2 : 1) == 0;
  }
  
  /// Always show ad - for important events like call end, tab switch
  bool shouldAlwaysShowAd() {
    return _adsEnabled;
  }

  /// Show interstitial ad and WAIT for it to complete
  /// Returns true if ad was shown and completed, false otherwise
  /// This method blocks until ad is dismissed or fails
  Future<bool> showInterstitialAd() async {
    if (!_adsEnabled) return false;
    if (_isShowingAd) return false; // Already showing an ad
    
    if (_isInterstitialAdReady && _interstitialAd != null) {
      _isShowingAd = true;
      _adCompleter = Completer<bool>();
      
      try {
        await _interstitialAd!.show();
        // Wait for ad to be dismissed or fail
        final result = await _adCompleter!.future.timeout(
          const Duration(seconds: 60), // Max 60 seconds for ad
          onTimeout: () {
            _isShowingAd = false;
            return false;
          },
        );
        return result;
      } catch (e) {
        _isShowingAd = false;
        _adCompleter = null;
        return false;
      }
    }
    return false;
  }

  /// Create a banner ad (returns null if ads disabled)
  BannerAd? createBannerAd({
    required Function() onAdLoaded,
    required Function(LoadAdError) onAdFailedToLoad,
  }) {
    if (!_adsEnabled) return null;
    
    return BannerAd(
      adUnitId: bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) => onAdLoaded(),
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          onAdFailedToLoad(error);
        },
      ),
    );
  }

  /// Dispose resources
  void dispose() {
    _interstitialAd?.dispose();
    _adsEnabledSubscription?.cancel();
  }
}
