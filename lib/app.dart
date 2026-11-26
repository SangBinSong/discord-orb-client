import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'api/preview_repository_impl.dart';
import 'auth/auth_repository_impl.dart';
import 'auth/oauth_loopback_listener.dart';
import 'auth/oauth_scheme_listener.dart';
import 'auth/token_manager.dart';
import 'contracts/auth_repository.dart';
import 'contracts/orb_window_controller.dart';
import 'contracts/preview_repository.dart';
import 'core/device_identity_store.dart';
import 'core/http_client.dart';
import 'models/channel_models.dart';
import 'models/message_models.dart';
import 'models/orb_error.dart';
import 'models/session_models.dart';
import 'platform/android_orb_window_controller.dart';
import 'platform/desktop_orb_window_controller.dart';
import 'ui/channels/channel_select_screen.dart';
import 'ui/common/orb_avatar.dart';
import 'ui/orb/orb_shell.dart';
import 'ui/settings/session_settings_sheet.dart';
import 'ui/setup/backend_setup_screen.dart';
import 'ui/setup/sign_in_screen.dart';

/// Method/event channel names shared with native platform hosts.
abstract final class OrbPlatformChannels {
  static const String window = 'discord_orb/window';
  static const String authLinks = 'discord_orb/auth_links';
}

/// Default [SystemBrowserLauncher] opening OAuth URLs in the host browser.
class PlatformSystemBrowserLauncher implements SystemBrowserLauncher {
  const PlatformSystemBrowserLauncher();

  @override
  Future<void> launch(Uri uri) async {
    try {
      final ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('open', <String>[uri.toString()]);
      } else if (Platform.isWindows) {
        result = await Process.run(
          'cmd',
          <String>['/c', 'start', '', uri.toString()],
          runInShell: true,
        );
      } else if (Platform.isAndroid) {
        result = await Process.run(
          'am',
          <String>[
            'start',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            uri.toString(),
          ],
        );
      } else {
        result = await Process.run('xdg-open', <String>[uri.toString()]);
      }

      if (result.exitCode != 0) {
        throw OrbException(
          code: 'browser_launch_failed',
          message: 'Failed to launch system browser (exit ${result.exitCode}).',
          state: OrbPreviewState.networkError,
        );
      }
    } on OrbException {
      rethrow;
    } catch (error) {
      throw OrbException(
        code: 'browser_launch_failed',
        message: 'Failed to launch system browser: $error',
        state: OrbPreviewState.networkError,
      );
    }
  }
}

/// Root application widget for Discord Orb with full dependency injection.
class DiscordOrbApp extends StatefulWidget {
  const DiscordOrbApp({
    super.key,
    this.platform,
    this.secureStore,
    this.httpClient,
    this.browserLauncher,
    this.loopbackListenerFactory,
    this.schemeListener,
    this.authRepository,
    this.previewRepository,
    this.windowController,
  });

  static const String windowChannelName = OrbPlatformChannels.window;
  static const String authLinksChannelName = OrbPlatformChannels.authLinks;

  static const Key openSettingsButtonKey = Key('orb_open_settings_button');
  static const Key changeChannelButtonKey = Key('orb_change_channel_button');

  final OrbPlatform? platform;
  final SecureKeyValueStore? secureStore;
  final OrbHttpClient? httpClient;
  final SystemBrowserLauncher? browserLauncher;
  final OAuthLoopbackListener Function()? loopbackListenerFactory;
  final OAuthSchemeListener? schemeListener;
  final AuthRepository? authRepository;
  final PreviewRepository? previewRepository;
  final OrbWindowController? windowController;

  @override
  State<DiscordOrbApp> createState() => _DiscordOrbAppState();
}

enum _AppStage {
  loading,
  setup,
  signIn,
  channelSelect,
  orb,
}

class _DiscordOrbAppState extends State<DiscordOrbApp> {
  late final OrbPlatform _platform;
  late final SecureKeyValueStore _secureStore;
  late final DeviceIdentityStore _identityStore;
  late final OrbHttpClient? _ownedHttpClient;
  late final TokenManager? _tokenManager;
  late final AuthRepository _authRepository;
  late final PreviewRepository _previewRepository;
  late final OrbWindowController _windowController;
  late final bool _ownsWindowController;
  late final OAuthSchemeListener? _ownedSchemeListener;

  final OrbShellController _orbShellController = OrbShellController();

  _AppStage _stage = _AppStage.loading;
  EligibleChannel? _selectedChannel;
  ChatListLayout _chatListLayout = ChatListLayout.standard;
  bool _panelPinned = true;
  bool _toastNotificationsEnabled = true;
  int _maxVisibleToastCount = DeviceIdentityStore.defaultMaxVisibleToastCount;
  ChatListLayout _toastLayout = ChatListLayout.standard;
  OrbPanelExpandDirection _panelExpandDirection = OrbPanelExpandDirection.below;

  @override
  void initState() {
    super.initState();
    _platform = widget.platform ?? DeviceIdentityStore.detectCurrentPlatform();
    _secureStore = widget.secureStore ?? InMemorySecureKeyValueStore();
    _identityStore = DeviceIdentityStore(
      store: _secureStore,
      defaultPlatform: _platform,
    );

    if (widget.authRepository != null && widget.previewRepository != null) {
      _ownedHttpClient = null;
      _tokenManager = null;
      _ownedSchemeListener = null;
      _authRepository = widget.authRepository!;
      _previewRepository = widget.previewRepository!;
    } else {
      final httpClient = widget.httpClient ?? OrbHttpClient();
      _ownedHttpClient = widget.httpClient == null ? httpClient : null;

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: _identityStore,
      );
      _tokenManager = tokenManager;

      final schemeListener = widget.schemeListener ??
          (_platform == OrbPlatform.android ? OAuthSchemeListener() : null);
      _ownedSchemeListener =
          widget.schemeListener == null ? schemeListener : null;

      _authRepository = widget.authRepository ??
          AuthRepositoryImpl(
            identityStore: _identityStore,
            httpClient: httpClient,
            tokenManager: tokenManager,
            browserLauncher:
                widget.browserLauncher ?? const PlatformSystemBrowserLauncher(),
            loopbackListenerFactory: widget.loopbackListenerFactory,
            schemeListener: schemeListener,
            platform: _platform,
          );

      _previewRepository = widget.previewRepository ??
          PreviewRepositoryImpl(
            httpClient: httpClient,
            tokenManager: tokenManager,
            backendBaseUrlProvider: () => _authRepository.backendBaseUrl,
          );
    }

    if (widget.windowController != null) {
      _windowController = widget.windowController!;
      _ownsWindowController = false;
    } else {
      _windowController = _platform == OrbPlatform.android
          ? AndroidOrbWindowController()
          : DesktopOrbWindowController();
      _ownsWindowController = true;
    }

    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _orbShellController.dispose();
    _ownedHttpClient?.close();
    if (_ownedSchemeListener != null) {
      unawaited(_ownedSchemeListener.dispose());
    }
    if (_ownsWindowController) {
      unawaited(_windowController.dispose());
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final storedLayout = await _identityStore.readChatListLayout();
    final storedPanelPinned = await _identityStore.readPanelPinned();
    final storedToastEnabled =
        await _identityStore.readToastNotificationsEnabled();
    final storedMaxToasts = await _identityStore.readMaxVisibleToastCount();
    final storedToastLayout = await _identityStore.readToastLayout();
    final storedTokens = await _authRepository.loadStoredSession();
    final backendUrl = _authRepository.backendBaseUrl;
    if (!mounted) return;
    _chatListLayout = storedLayout;
    _panelPinned = storedPanelPinned;
    _toastNotificationsEnabled = storedToastEnabled;
    _maxVisibleToastCount = storedMaxToasts;
    _toastLayout = storedToastLayout;
    await _setPanelPinnedSafely(_panelPinned);
    await _setToastNotificationsEnabledSafely(_toastNotificationsEnabled);
    await _setToastLayoutSafely(_toastLayout);

    if (backendUrl == null) {
      setState(() {
        _selectedChannel = null;
        _stage = _AppStage.setup;
      });
      await _showMainWindowSafely();
      return;
    }

    if (storedTokens == null) {
      setState(() {
        _selectedChannel = null;
        _stage = _AppStage.signIn;
      });
      await _showMainWindowSafely();
      return;
    }

    final restoredChannel = await _restoreSelectedChannel();
    if (!mounted) return;

    if (restoredChannel != null) {
      setState(() {
        _selectedChannel = restoredChannel;
        _stage = _AppStage.orb;
      });
      await _showOrbIfPermitted();
      return;
    }

    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.channelSelect;
    });
    await _showMainWindowSafely();
  }

  Future<EligibleChannel?> _restoreSelectedChannel() async {
    final raw = await _identityStore.readSelectedChannel();
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return EligibleChannel.fromJson(decoded);
      }
    } catch (_) {
      await _identityStore.deleteSelectedChannel();
    }
    return null;
  }

  Future<void> _persistSelectedChannel(EligibleChannel channel) async {
    await _identityStore.saveSelectedChannel(jsonEncode(channel.toJson()));
  }

  Future<void> _showOrbIfPermitted() async {
    try {
      final hasPermission = await _windowController.hasOverlayPermission();
      if (hasPermission) {
        await _windowController.showCollapsedOrb();
      }
    } catch (_) {
      // Host window channel might not be registered in headless/widget tests.
    }
  }

  Future<void> _showMainWindowSafely() async {
    try {
      await _windowController.showMainWindow();
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
  }

  Future<void> _setPanelPinnedSafely(bool pinned) async {
    try {
      await _windowController.setPanelPinned(pinned);
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
  }

  Future<void> _setToastNotificationsEnabledSafely(bool enabled) async {
    try {
      await _windowController.setToastNotificationsEnabled(enabled);
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
  }

  Future<void> _setToastLayoutSafely(ChatListLayout layout) async {
    try {
      await _windowController.setToastLayout(layout);
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
  }

  Future<void> _handleQuitApp() async {
    _orbShellController.closeAndClear();
    _previewRepository.clearMemory();
    try {
      await _windowController.hideToastStack();
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
    try {
      await _windowController.quitApp();
    } catch (_) {
      // Ignore missing host plugin in widget tests.
    }
  }

  Future<void> _handleBackendConfigured() async {
    _previewRepository.clearMemory();
    await _identityStore.deleteSelectedChannel();
    if (!mounted) return;
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.signIn;
    });
  }

  void _handleSignedIn(OrbSessionTokens _) {
    _previewRepository.clearMemory();
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.channelSelect;
    });
  }

  Future<void> _handleChannelSelected(EligibleChannel channel) async {
    await _persistSelectedChannel(channel);
    if (!mounted) return;
    setState(() {
      _selectedChannel = channel;
      _stage = _AppStage.orb;
    });
    await _showOrbIfPermitted();
  }

  Future<void> _handleChangeBackendFromSignIn() async {
    await _authRepository.clearLocalStateForBackendChange();
    await _identityStore.deleteSelectedChannel();
    _previewRepository.clearMemory();
    await _showMainWindowSafely();
    if (!mounted) return;
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.setup;
    });
  }

  Future<void> _handleReauthenticate() async {
    _orbShellController.closeAndClear();
    _previewRepository.clearMemory();
    await _identityStore.deleteSelectedChannel();
    await _showMainWindowSafely();
    if (!mounted) return;
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.signIn;
    });
  }

  Future<void> _handleReselectChannel() async {
    _orbShellController.closeAndClear();
    _previewRepository.clearMemory();
    await _showMainWindowSafely();
    if (!mounted) return;
    setState(() {
      _stage = _AppStage.channelSelect;
    });
  }

  Future<void> _handleSignedOut() async {
    _orbShellController.closeAndClear();
    _previewRepository.clearMemory();
    await _identityStore.deleteSelectedChannel();
    await _showMainWindowSafely();
    if (!mounted) return;
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.signIn;
    });
  }

  Future<void> _handleBackendChangedFromSettings() async {
    _orbShellController.closeAndClear();
    _previewRepository.clearMemory();
    await _identityStore.deleteSelectedChannel();
    await _showMainWindowSafely();
    if (!mounted) return;
    setState(() {
      _selectedChannel = null;
      _stage = _AppStage.setup;
    });
  }

  void _handleChatListLayoutChanged(ChatListLayout next) {
    if (_chatListLayout != next) {
      setState(() {
        _chatListLayout = next;
      });
    }
    unawaited(_identityStore.saveChatListLayout(next));
  }

  void _handlePanelPinnedChanged(bool next) {
    if (_panelPinned != next) {
      setState(() {
        _panelPinned = next;
      });
    }
    unawaited(_setPanelPinnedSafely(next));
    unawaited(_identityStore.savePanelPinned(next));
  }

  void _handleToastNotificationsChanged(bool next) {
    if (_toastNotificationsEnabled != next) {
      setState(() {
        _toastNotificationsEnabled = next;
      });
    }
    unawaited(_setToastNotificationsEnabledSafely(next));
    unawaited(_identityStore.saveToastNotificationsEnabled(next));
  }

  void _handleMaxVisibleToastCountChanged(int next) {
    final clamped = DeviceIdentityStore.clampMaxVisibleToastCount(next);
    if (_maxVisibleToastCount != clamped) {
      setState(() {
        _maxVisibleToastCount = clamped;
      });
    }
    unawaited(_identityStore.saveMaxVisibleToastCount(clamped));
  }

  void _handleToastLayoutChanged(ChatListLayout next) {
    if (_toastLayout != next) {
      setState(() {
        _toastLayout = next;
      });
    }
    unawaited(_setToastLayoutSafely(next));
    unawaited(_identityStore.saveToastLayout(next));
  }

  void _handleExpandDirectionChanged(OrbPanelExpandDirection direction) {
    if (_panelExpandDirection != direction) {
      setState(() {
        _panelExpandDirection = direction;
      });
    }
  }

  void _openSettingsSheet(BuildContext sheetHostContext) {
    showModalBottomSheet<void>(
      context: sheetHostContext,
      isScrollControlled: true,
      builder: (BuildContext modalContext) {
        return SessionSettingsSheet(
          authRepository: _authRepository,
          selectedChannel: _selectedChannel,
          chatListLayout: _chatListLayout,
          onChatListLayoutChanged: _handleChatListLayoutChanged,
          isPanelPinned: _panelPinned,
          onPanelPinnedChanged: _handlePanelPinnedChanged,
          toastNotificationsEnabled: _toastNotificationsEnabled,
          onToastNotificationsChanged: _handleToastNotificationsChanged,
          maxVisibleToastCount: _maxVisibleToastCount,
          onMaxVisibleToastCountChanged: _handleMaxVisibleToastCountChanged,
          toastLayout: _toastLayout,
          onToastLayoutChanged: _handleToastLayoutChanged,
          onReselectChannel: () {
            Navigator.of(modalContext).pop();
            unawaited(_handleReselectChannel());
          },
          onSignedOut: () {
            Navigator.of(modalContext).pop();
            unawaited(_handleSignedOut());
          },
          onBackendChanged: () {
            Navigator.of(modalContext).pop();
            unawaited(_handleBackendChangedFromSettings());
          },
          onQuitApp: () {
            Navigator.of(modalContext).pop();
            unawaited(_handleQuitApp());
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep reference to _tokenManager for lifecycle awareness.
    assert(_tokenManager == null || _tokenManager.sessionEpoch >= 0);

    return MaterialApp(
      title: 'Discord Orb',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5865F2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Builder(
        builder: (BuildContext homeContext) {
          switch (_stage) {
            case _AppStage.loading:
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            case _AppStage.setup:
              return BackendSetupScreen(
                authRepository: _authRepository,
                platform: _platform,
                onConfigured: () => unawaited(_handleBackendConfigured()),
              );
            case _AppStage.signIn:
              return SignInScreen(
                authRepository: _authRepository,
                platform: _platform,
                onSignedIn: _handleSignedIn,
                onChangeBackend: () => unawaited(_handleChangeBackendFromSignIn()),
              );
            case _AppStage.channelSelect:
              return ChannelSelectScreen(
                previewRepository: _previewRepository,
                selectedChannel: _selectedChannel,
                onChannelSelected: (EligibleChannel channel) =>
                    unawaited(_handleChannelSelected(channel)),
                onSessionExpired: () => unawaited(_handleReauthenticate()),
                onOpenSettings: () => _openSettingsSheet(homeContext),
              );
            case _AppStage.orb:
              final channel = _selectedChannel;
              final controlsAlignment =
                  _panelExpandDirection == OrbPanelExpandDirection.above
                      ? Alignment.topLeft
                      : Alignment.bottomLeft;
              return Scaffold(
                backgroundColor: Colors.transparent,
                body: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final showControlsBar = constraints.maxWidth >= 200 &&
                        constraints.maxHeight >= 200;
                    return Stack(
                      children: <Widget>[
                        if (showControlsBar)
                          SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: Align(
                                alignment: controlsAlignment,
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        if (channel != null)
                                          OrbAvatar(
                                            name: channel.guildName,
                                            imageUrl: channel.guildIconUrl,
                                            size: 20,
                                          )
                                        else
                                          const Icon(Icons.tag, size: 16),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            channel == null
                                                ? 'No channel selected'
                                                : '${channel.guildName} · #${channel.channelName}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        IconButton(
                                          key: DiscordOrbApp
                                              .changeChannelButtonKey,
                                          tooltip: 'Change channel',
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            Icons.swap_horiz,
                                            size: 20,
                                          ),
                                          onPressed: () => unawaited(
                                            _handleReselectChannel(),
                                          ),
                                        ),
                                        IconButton(
                                          key: DiscordOrbApp
                                              .openSettingsButtonKey,
                                          tooltip: 'Session settings',
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            Icons.settings_outlined,
                                            size: 20,
                                          ),
                                          onPressed: () =>
                                              _openSettingsSheet(homeContext),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: OrbShell(
                            previewRepository: _previewRepository,
                            windowController: _windowController,
                            controller: _orbShellController,
                            guildId: channel?.guildId,
                            channelId: channel?.channelId,
                            channelName: channel?.channelName,
                            guildName: channel?.guildName,
                            guildIconUrl: channel?.guildIconUrl,
                            chatListLayout: _chatListLayout,
                            onChatListLayoutChanged:
                                _handleChatListLayoutChanged,
                            panelPinned: _panelPinned,
                            onPanelPinnedChanged: _handlePanelPinnedChanged,
                            toastNotificationsEnabled:
                                _toastNotificationsEnabled,
                            onToastNotificationsChanged:
                                _handleToastNotificationsChanged,
                            maxVisibleToastCount: _maxVisibleToastCount,
                            onMaxVisibleToastCountChanged:
                                _handleMaxVisibleToastCountChanged,
                            toastLayout: _toastLayout,
                            onToastLayoutChanged: _handleToastLayoutChanged,
                            onExpandDirectionChanged:
                                _handleExpandDirectionChanged,
                            onReauthenticate: () =>
                                unawaited(_handleReauthenticate()),
                            onReselectChannel: () =>
                                unawaited(_handleReselectChannel()),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );
          }
        },
      ),
    );
  }
}
