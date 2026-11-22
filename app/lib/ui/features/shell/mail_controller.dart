import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/platform/os_notify.dart';
import '../../../data/repositories/in_memory_mail_backend.dart';
import '../../../data/repositories/local_ffi_backend.dart';
import '../../../data/repositories/mail_backend.dart';
import '../../../data/repositories/remote_http_backend.dart';
import '../../../data/repositories/session_token_store_stub.dart'
    if (dart.library.js_interop) '../../../data/repositories/session_token_store_web.dart';
import '../../../domain/models/account_models.dart';
import '../../../domain/models/ai_models.dart';
import '../../../domain/models/automation_models.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/models/preferences_models.dart';
import '../../../domain/models/service_event.dart';
import '../../core/theme/colecto_palette.dart';
import '../../core/widgets/toast_overlay.dart';
import 'folders.dart';

enum SettingsSection {
  accounts('accounts', 'Accounts', LucideIcons.atSign),
  mail('mail', 'Mail', LucideIcons.inbox),
  appearance('appearance', 'Appearance', LucideIcons.palette),
  notifications('notifications', 'Notifications', LucideIcons.bell),
  privacy('privacy', 'Privacy', LucideIcons.image),
  servers('servers', 'Connection', LucideIcons.server),
  backup('backup', 'Backup', LucideIcons.databaseBackup),
  ai('ai', 'AI', LucideIcons.cpu),
  apiKeys('api-keys', 'API keys', LucideIcons.keyRound),
  sendApprovals('send-approvals', 'Send approvals', LucideIcons.shieldCheck);

  const SettingsSection(this.routeSegment, this.label, this.icon);
  final String routeSegment;
  final String label;
  final IconData icon;

  static SettingsSection? fromSegment(String segment) {
    for (final s in SettingsSection.values) {
      if (s.routeSegment == segment) return s;
    }
    return null;
  }
}

enum BackendKind { demo, remoteHttp, localFfi }

/// How the message list is ordered, as in Colecto's mailbox.
enum ThreadSort {
  newest('Newest first'),
  oldest('Oldest first'),
  sender('Sender A–Z'),
  subject('Subject A–Z');

  const ThreadSort(this.label);
  final String label;
}

class ComposeRequest {
  const ComposeRequest({
    this.draftId,
    this.to = '',
    this.cc = '',
    this.subject = '',
    this.body = '',
    this.inReplyTo = '',
    this.references = '',
    this.forwardOf,
    this.replyMessageId,
    this.attachments = const [],
    this.heading = 'New message',
  });

  final String? draftId;
  final String to;
  final String cc;
  final String subject;
  final String body;
  final String inReplyTo;
  final String references;
  final String? forwardOf;
  final String? replyMessageId;
  final List<OutgoingAttachment> attachments;

  /// `New message`, `Reply`, `Forward` or `Your draft`.
  final String heading;
}

String _plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

class MailController extends ChangeNotifier {
  MailController({
    MailBackend? backend,
    BackendKind initialKind = BackendKind.demo,
    String initialDaemonUrl = 'http://127.0.0.1:4173',
    String initialToken = '',
  }) : _backend =
           backend ??
           _buildBackend(initialKind, initialDaemonUrl, initialToken),
       _backendKind = initialKind,
       _daemonUrl = initialDaemonUrl,
       _daemonToken = initialToken;

  static MailBackend _buildBackend(
    BackendKind kind,
    String daemonUrl,
    String token,
  ) {
    return switch (kind) {
      BackendKind.demo => InMemoryMailBackend(
        worstCase: InMemoryMailBackend.worstCaseDefine,
      ),
      BackendKind.remoteHttp => RemoteHttpBackend(
        baseUrl: daemonUrl.trim(),
        token: token.trim(),
      ),
      BackendKind.localFfi => LocalFfiBackend(),
    };
  }

  MailBackend _backend;
  BackendKind _backendKind;
  String _daemonUrl;
  String _daemonToken;

  StreamSubscription<ServiceEvent>? _eventSub;
  bool _eventsConnectedOnce = false;
  bool _disposed = false;
  int _mailboxEpoch = 0;
  int _threadEpoch = 0;
  int _reloadEpoch = 0;
  int _toastSeq = 0;
  final Map<int, Timer> _toastTimers = {};
  final Map<int, _PendingSend> _pendingSends = {};
  int _pendingSendSeq = 0;

  bool get hasPendingSends => _pendingSends.isNotEmpty;

  int get reloadEpoch => _reloadEpoch;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // Global UI state
  ThemeMode _themeMode = ThemeMode.system;
  // A session preview (Appearance, or a test) wins over the saved choice.
  ColectoPlatformStyle? _sessionDesign;
  bool _loading = true;
  bool _refreshing = false;
  bool _authRequired = false;
  String? _error;
  SettingsSection? _activeSettings;
  bool _settingsIndex = false;
  final List<ColectoToast> _toasts = [];
  final Set<int> _heldToasts = {};
  DateTime? _syncedAt;

  // Composer hosted by the shell (reader stage on desktop, a full-screen
  // sheet on phones). The key changes for every new compose so the editor
  // starts fresh.
  ComposeRequest? _compose;
  int _composeKey = 0;

  // System metadata
  VersionInfo? _version;
  ReleaseStatus? _releaseStatus;
  SecurityInfo _security = const SecurityInfo(
    cleanupPending: false,
    protected: false,
    locked: false,
  );
  Preferences _preferences = const Preferences();

  // Accounts & sync
  List<AccountInfo> _accounts = const [];
  String _activeAccount = 'demo';
  Map<String, AccountSync> _syncByAccount = const {};

  // Mailbox state
  List<Folder> _folders = const [];
  LabelMap _labels = const {};
  String _activeFolder = 'inbox';
  String? _activeLabel;
  String _searchQuery = '';
  List<MailMessage> _messages = const [];
  List<ConversationThread> _threads = const [];
  List<Draft> _drafts = const [];
  final Set<String> _bulkSelectedIds = {};
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _loadMoreError;
  int _nextOffset = 0;

  /// Matches `colecto_core::MAX_LIST_OFFSET`.
  static const int maxListOffset = 100000;

  // Reader state
  String? _selectedMessageId;
  List<ThreadMessage> _conversation = const [];
  final Map<String, MessageContent> _contentCache = {};
  static const int _maxContentCache = 40;
  final Set<String> _loadingContentIds = {};

  // AI & Automation state
  AiSettingsView _aiSettings = const AiSettingsView();
  final Map<String, String> _summaries = {};
  static const int _maxSummariesCache = 100;
  final Set<String> _loadingSummaryIds = {};
  List<ApiKeyMetadata> _apiKeys = const [];
  List<PendingSend> _sendRequests = const [];

  // Getters
  MailBackend get backend => _backend;
  BackendKind get backendKind => _backendKind;
  String get daemonUrl => _daemonUrl;
  String get daemonToken => _daemonToken;
  ThemeMode get themeMode => _themeMode;

  /// The design system in use. `COLECTO_DESIGN` (a launch flag for
  /// previews) wins, then the owner's saved choice, then the platform's own.
  /// Any design works on any platform.
  ColectoPlatformStyle get design =>
      _sessionDesign ??
      ColectoPlatformStyle.parse(colectoDesignDefine) ??
      ColectoPlatformStyle.parse(_preferences.design) ??
      ColectoPlatformStyle.native();

  /// Whether a launch flag is overriding the saved design.
  bool get designForcedByLaunch =>
      ColectoPlatformStyle.parse(colectoDesignDefine) != null;

  /// Saves [design] as the owner's choice; the platform's own design is
  /// stored as no choice, so it keeps following the platform. When
  /// [resetFont] is true, clears any custom font so the new design's default
  /// takes effect.
  Future<void> setDesign(
    ColectoPlatformStyle design, {
    bool resetFont = false,
  }) async {
    _sessionDesign = null;
    await updatePreferences(
      PreferencesPatch(
        design: design == ColectoPlatformStyle.native() ? '' : design.id,
        font: resetFont ? '' : null,
      ),
    );
  }

  /// Reloads the Flutter app state and re-fetches preferences, accounts,
  /// folders, and mail from the active backend without restarting the process.
  Future<void> reloadApp() async {
    _reloadEpoch++;
    _activeSettings = null;
    _compose = null;
    _selectedMessageId = null;
    _conversation = const [];
    _contentCache.clear();
    _loadingContentIds.clear();
    _summaries.clear();
    _loadingSummaryIds.clear();
    _bulkSelectedIds.clear();
    _sortedThreadsCache = null;
    notifyListeners();
    await initialize();
  }

  /// Browser-like zoom steps, in percent.
  static const zoomSteps = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200];

  /// Whole-interface zoom as a factor (1.0 = 100 %).
  double get zoom => (_preferences.zoom ?? 100) / 100;

  bool _zoomHintShown = false;

  Future<void> _setZoom(int percent, {String? undoKey}) async {
    final prev = _preferences.zoom ?? 100;
    await updatePreferences(PreferencesPatch(zoom: percent));
    if (!_zoomHintShown && percent != prev && undoKey != null) {
      _zoomHintShown = true;
      final mod = defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl';
      showToast(
        'Zoom $percent%',
        detail: 'Press $mod$undoKey to undo, or ${mod}0 to reset.',
      );
    }
  }

  Future<void> zoomIn() {
    final now = _preferences.zoom ?? 100;
    return _setZoom(
      zoomSteps.firstWhere((s) => s > now, orElse: () => 200),
      undoKey: '-',
    );
  }

  Future<void> zoomOut() {
    final now = _preferences.zoom ?? 100;
    return _setZoom(
      zoomSteps.lastWhere((s) => s < now, orElse: () => zoomSteps.first),
      undoKey: '+',
    );
  }

  Future<void> resetZoom() => _setZoom(100);

  /// Uses [design] until restart without saving it (tests, previews).
  void previewDesign(ColectoPlatformStyle design) {
    _sessionDesign = design;
    notifyListeners();
  }

  bool get loading => _loading;

  bool _onboarding = false;
  bool _onboardingDone = false;

  /// First run: onboarding never finished and there is no real account yet.
  /// It stays up once shown, so adding the account can end on its last step.
  bool get showsOnboarding {
    if (!_loading &&
        _error == null &&
        !_authRequired &&
        !_preferences.onboarded &&
        !_accounts.any((a) => a.id != 'demo')) {
      _onboarding = true;
    }
    return _onboarding && !_onboardingDone && !_preferences.onboarded;
  }

  /// Ends onboarding, in [account] when given or with the sample mail.
  Future<void> finishOnboarding({String? account, bool demo = false}) async {
    _onboardingDone = true;
    await updatePreferences(
      PreferencesPatch(
        onboarded: true,
        account: demo ? 'demo' : account,
        accountsEnabled: demo ? const {'demo': true} : null,
      ),
    );
    final target = demo ? 'demo' : account;
    if (target != null && enabledAccounts.any((a) => a.id == target)) {
      await selectAccount(target);
    }
    notifyListeners();
  }

  bool get refreshing => _refreshing;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get loadMoreError => _loadMoreError;
  bool get authRequired => _authRequired;

  /// Batch size for initial load and on-demand pagination, matching the
  /// configured warm/prefetch count (clamped to the backend's 1..=100 limit).
  int get pageSize => _preferences.prefetch.count > 0
      ? _preferences.prefetch.count.clamp(1, 100)
      : 50;

  bool get canPaginate =>
      _activeAccount.isNotEmpty &&
      _activeLabel == null &&
      _activeFolder != 'drafts' &&
      _messages.isNotEmpty;

  bool get canLoadMore =>
      canPaginate &&
      _hasMore &&
      !_loadingMore &&
      !_refreshing &&
      _loadMoreError == null &&
      _nextOffset < maxListOffset;
  String? get error => _error;
  SettingsSection? get activeSettings => _activeSettings;

  /// Whether a phone shows the Settings section list rather than a page.
  bool get showsSettingsIndex => _settingsIndex;
  List<ColectoToast> get toasts => List.unmodifiable(_toasts);
  DateTime? get syncedAt => _syncedAt;
  ComposeRequest? get compose => _compose;
  int get composeKey => _composeKey;

  bool get isInboxActive {
    if (_activeFolder.toLowerCase() == 'inbox') return true;
    for (final f in _folders) {
      if (f.id == _activeFolder) return f.role == FolderRole.inbox;
    }
    return false;
  }

  bool get isDraftsActive {
    if (_activeFolder.toLowerCase() == 'drafts') return true;
    for (final f in _folders) {
      if (f.id == _activeFolder) return f.role == FolderRole.drafts;
    }
    return false;
  }

  String get currentFolderName {
    if (_activeLabel != null) return _activeLabel!;
    for (final f in _folders) {
      if (f.id == _activeFolder ||
          (isInboxActive && f.role == FolderRole.inbox)) {
        return folderDisplayName(f);
      }
    }
    if (_activeFolder.isEmpty || _activeFolder.toUpperCase() == 'INBOX') {
      return 'Inbox';
    }
    return '${_activeFolder[0].toUpperCase()}${_activeFolder.substring(1)}';
  }

  void startCompose([ComposeRequest request = const ComposeRequest()]) {
    _compose = request;
    _composeKey++;
    notifyListeners();
  }

  void closeCompose() {
    if (_compose == null) return;
    _compose = null;
    notifyListeners();
  }

  VersionInfo? get version => _version;
  ReleaseStatus? get releaseStatus => _releaseStatus;
  SecurityInfo get security => _security;
  Preferences get preferences => _preferences;

  List<AccountInfo> get accounts {
    final order = _preferences.accountOrder;
    if (order.isEmpty || _accounts.length < 2) return _accounts;
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    final sorted = List<AccountInfo>.from(_accounts);
    sorted.sort((a, b) {
      final ra = rank[a.id];
      final rb = rank[b.id];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return -1;
      if (rb != null) return 1;
      return 0;
    });
    return sorted;
  }

  List<AccountInfo> get enabledAccounts {
    final ordered = accounts;
    final enabled = ordered
        .where((a) => _preferences.accountEnabled(a.id))
        .toList(growable: false);
    return enabled.isNotEmpty ? enabled : ordered;
  }

  Future<void> reorderAccounts(int oldIndex, int newIndex) async {
    final list = List<AccountInfo>.from(accounts);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= list.length || newIndex == oldIndex) return;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    await updatePreferences(
      PreferencesPatch(accountOrder: [for (final a in list) a.id]),
    );
  }

  String get activeAccount => _activeAccount;
  AccountInfo? get currentAccountInfo {
    for (final a in _accounts) {
      if (a.id == _activeAccount) return a;
    }
    return _accounts.isNotEmpty ? _accounts.first : null;
  }

  AccountSync? get currentAccountSync => _syncByAccount[_activeAccount];
  Map<String, AccountSync> get syncByAccount => _syncByAccount;

  List<Folder> get folders => _folders;
  LabelMap get labels => _labels;
  String get activeFolder => _activeFolder;
  String? get activeLabel => _activeLabel;
  String get searchQuery => _searchQuery;
  List<MailMessage> get messages => _messages;
  ThreadSort _sort = ThreadSort.newest;
  List<ConversationThread>? _sortedThreadsCache;
  ThreadSort get sort => _sort;
  void setSort(ThreadSort sort) {
    if (_sort == sort) return;
    _sort = sort;
    _sortedThreadsCache = null;
    notifyListeners();
  }

  void _setThreads(List<ConversationThread> threads) {
    _threads = threads;
    _sortedThreadsCache = null;
  }

  /// The conversations in the list, in the chosen order (cached until
  /// threads or sort order changes).
  List<ConversationThread> get threads {
    if (_sort == ThreadSort.newest) return _threads;
    final cached = _sortedThreadsCache;
    if (cached != null) return cached;
    String key(ConversationThread t) => switch (_sort) {
      ThreadSort.sender => t.latest.displaySender,
      _ => t.subject,
    }.toLowerCase();
    final sorted = switch (_sort) {
      ThreadSort.newest => _threads,
      ThreadSort.oldest => _threads.reversed.toList(growable: false),
      ThreadSort.sender || ThreadSort.subject => [
        ..._threads,
      ]..sort((a, b) => key(a).compareTo(key(b))),
    };
    _sortedThreadsCache = sorted;
    return sorted;
  }

  List<Draft> get drafts => _drafts;
  Set<String> get bulkSelectedIds => Set.unmodifiable(_bulkSelectedIds);

  String? get selectedMessageId => _selectedMessageId;
  List<ThreadMessage> get conversation => _conversation;
  MessageContent? contentFor(String id) => _contentCache[id];
  bool isLoadingContent(String id) => _loadingContentIds.contains(id);

  AiSettingsView get aiSettings => _aiSettings;
  String? summaryFor(String id) => _summaries[id];
  bool isLoadingSummary(String id) => _loadingSummaryIds.contains(id);
  List<ApiKeyMetadata> get apiKeys => _apiKeys;
  List<PendingSend> get sendRequests => _sendRequests;
  int get pendingApprovalCount =>
      _sendRequests.where((r) => r.status == ApprovalStatus.pending).length;

  /// Settings sections worth showing. Send approvals appears only while
  /// something waits (or while it is open, so approving the last request
  /// doesn't pull the page away).
  List<SettingsSection> get visibleSettingsSections => SettingsSection.values;

  bool get hasUpdateBanner {
    final latest = _releaseStatus?.latest;
    if (latest == null) return false;
    return _preferences.notifiedRelease != latest.version;
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  /// Opens Settings at [section]; with none, phones start at the section
  /// list (wider windows show Accounts beside it).
  void openSettings([SettingsSection? section]) {
    _settingsIndex = section == null;
    section ??= SettingsSection.accounts;
    _activeSettings = section;
    notifyListeners();
    if (section == SettingsSection.ai) unawaited(loadAiSettings());
    if (section == SettingsSection.apiKeys) unawaited(loadApiKeys());
    if (section == SettingsSection.sendApprovals) unawaited(loadSendRequests());
    if (section == SettingsSection.accounts) unawaited(loadSecurity());
  }

  void closeSettings() {
    _activeSettings = null;
    notifyListeners();
  }

  /// Back from a Settings page to the section list (phones).
  void showSettingsIndex() {
    _settingsIndex = true;
    notifyListeners();
  }

  int? showToast(
    String message, {
    bool isError = false,
    String? detail,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 6),
    bool allowHoverHold = true,
  }) {
    if (!_preferences.notifications.enabled && !isError && onAction == null) {
      return null;
    }
    final id = ++_toastSeq;
    _toasts.add(
      ColectoToast(
        id: id,
        message: message,
        detail: detail,
        isError: isError,
        actionLabel: actionLabel,
        onAction: onAction,
        allowHoverHold: allowHoverHold,
      ),
    );
    if (_toasts.length > 4) {
      final evicted = _toasts.removeAt(0);
      _toastTimers.remove(evicted.id)?.cancel();
    }
    notifyListeners();
    _armToast(id, duration: duration);
    return id;
  }

  // Notifications leave after their duration (default six seconds) unless hovered.
  void _armToast(int id, {Duration duration = const Duration(seconds: 6)}) {
    _toastTimers.remove(id)?.cancel();
    _toastTimers[id] = Timer(duration, () => dismissToast(id));
  }

  void holdToast(int id, bool hold) {
    final toast = _toasts.where((t) => t.id == id).firstOrNull;
    if (toast == null || !toast.allowHoverHold) return;
    if (hold) {
      _heldToasts.add(id);
      _toastTimers.remove(id)?.cancel();
    } else if (_heldToasts.remove(id) && _toasts.any((t) => t.id == id)) {
      _armToast(id);
    }
  }

  void dismissToast(int id) {
    _heldToasts.remove(id);
    _toastTimers.remove(id)?.cancel();
    final before = _toasts.length;
    _toasts.removeWhere((t) => t.id == id);
    if (_toasts.length != before) notifyListeners();
  }

  Future<void> switchBackend({
    required BackendKind kind,
    String? daemonUrl,
    String? token,
  }) async {
    await _eventSub?.cancel();
    _backend.dispose();
    _backendKind = kind;
    if (daemonUrl != null) _daemonUrl = daemonUrl.trim();
    if (token != null) _daemonToken = token.trim();

    _backend = switch (kind) {
      BackendKind.demo => InMemoryMailBackend(
        worstCase: InMemoryMailBackend.worstCaseDefine,
      ),
      BackendKind.remoteHttp => RemoteHttpBackend(
        baseUrl: _daemonUrl,
        token: _daemonToken,
      ),
      BackendKind.localFfi => LocalFfiBackend(),
    };
    _contentCache.clear();
    _summaries.clear();
    _selectedMessageId = null;
    _conversation = const [];
    _authRequired = false;
    await initialize();
  }

  /// Forgets the daemon access token kept for this session and asks for it
  /// again, as Colecto's Connection page did.
  void forgetSessionToken() {
    clearSessionToken();
    _daemonToken = '';
    _authRequired = true;
    notifyListeners();
  }

  Future<void> authenticateDaemon(String url, String token) async {
    await switchBackend(
      kind: BackendKind.remoteHttp,
      daemonUrl: url,
      token: token,
    );
  }

  Future<void> initialize() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _version = await _backend.version();
      _preferences = await _backend.getPreferences();
      _accounts = await _backend.listAccounts();
      _security = await _backend.security();
      await _loadSyncStatus();

      final enabled = enabledAccounts;
      if (_preferences.account != null &&
          enabled.any((a) => a.id == _preferences.account)) {
        _activeAccount = _preferences.account!;
      } else if (enabled.isNotEmpty) {
        _activeAccount = enabled.first.id;
      }

      _authRequired = false;
      if (_backendKind == BackendKind.remoteHttp && _daemonToken.isNotEmpty) {
        writeSessionToken(_daemonToken);
      }
      _subscribeEvents();
      await loadMailbox(refresh: false);
      unawaited(_loadBackgroundMetadata());
    } on MailBackendException catch (e) {
      if (e.isAuthRequired) {
        _authRequired = true;
        clearSessionToken();
      }
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadBackgroundMetadata() async {
    try {
      _releaseStatus = await _backend.latestRelease();
    } catch (_) {}
    try {
      _sendRequests = await _backend.listSendRequests();
    } catch (_) {}
    if (_activeAccount.isNotEmpty) {
      try {
        _aiSettings = await _backend.aiSettings(account: _activeAccount);
      } catch (_) {}
    }
    notifyListeners();
  }

  void _subscribeEvents() {
    _eventSub?.cancel();
    _eventsConnectedOnce = false;
    _eventSub = _backend.events(window: true).listen(_handleServiceEvent);
  }

  void _handleServiceEvent(ServiceEvent event) {
    switch (event) {
      case ReadyServiceEvent():
        if (_eventsConnectedOnce) {
          unawaited(loadMailbox(refresh: false));
        } else {
          _eventsConnectedOnce = true;
        }
      case ResyncServiceEvent():
        unawaited(loadMailbox(refresh: false));
      case MailServiceEvent(:final account, :final ids):
        if (account == _activeAccount) {
          unawaited(loadMailbox(refresh: false));
        }
        if (_preferences.notifications.system && ids.isNotEmpty) {
          unawaited(
            sendOsNotification(
              title: 'New mail',
              body: '${_plural(ids.length, 'new message')} arrived.',
            ),
          );
        }
      case SyncServiceEvent(:final sync):
        _syncByAccount = {..._syncByAccount, sync.account: sync};
        notifyListeners();
      case ApprovalServiceEvent(:final from, :final subject):
        unawaited(loadSendRequests());
        showToast(
          'Approval requested',
          detail: '$from wants to send “$subject”.',
        );
        if (_preferences.notifications.system) {
          unawaited(
            sendOsNotification(
              title: 'Approval requested',
              body: '$from wants to send “$subject”.',
            ),
          );
        }
      case NavigateServiceEvent(:final target, :final account):
        if (account.isNotEmpty &&
            account != _activeAccount &&
            _accounts.any((a) => a.id == account)) {
          unawaited(selectAccount(account));
        }
        _handleNavigateTarget(target);
      case McpServiceEvent(:final on):
        _preferences = Preferences(
          mcp: on,
          account: _preferences.account,
          workspace: _preferences.workspace,
          accent: _preferences.accent,
          font: _preferences.font,
          design: _preferences.design,
          zoom: _preferences.zoom,
          fontSize: _preferences.fontSize,
          textSpacing: _preferences.textSpacing,
          notifications: _preferences.notifications,
          remoteImages: _preferences.remoteImages,
          accountsEnabled: _preferences.accountsEnabled,
          onboarded: _preferences.onboarded,
          listDensity: _preferences.listDensity,
          dateGroups: _preferences.dateGroups,
          autoLoadMore: _preferences.autoLoadMore,
          notifiedRelease: _preferences.notifiedRelease,
          prefetch: _preferences.prefetch,
          changed: _preferences.changed,
        );
        notifyListeners();
      case PreferencesServiceEvent():
        unawaited(reloadPreferences());
      case LabelsUpdatedServiceEvent(:final account):
        if (account == _activeAccount) {
          unawaited(loadLabels());
        }
    }
  }

  void _handleNavigateTarget(String target) {
    if (target.startsWith('settings/')) {
      final section = SettingsSection.fromSegment(
        target.substring('settings/'.length),
      );
      if (section != null) openSettings(section);
      return;
    }
    closeSettings();
    switch (target) {
      case 'inbox':
      case 'sent':
      case 'drafts':
        unawaited(selectFolder(target));
    }
  }

  Future<void> _loadSyncStatus() async {
    try {
      final statuses = await _backend.syncStatus();
      _syncByAccount = {for (final s in statuses) s.account: s};
    } catch (_) {}
  }

  Future<void> reloadPreferences() async {
    try {
      _preferences = await _backend.getPreferences();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> updatePreferences(PreferencesPatch patch) async {
    try {
      _preferences = await _backend.updatePreferences(patch);
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> selectAccount(String accountId) async {
    if (_activeAccount == accountId) return;
    _activeAccount = accountId;
    _activeFolder = 'inbox';
    _activeLabel = null;
    _searchQuery = '';
    _selectedMessageId = null;
    _conversation = const [];
    _contentCache.clear();
    _loadingContentIds.clear();
    _summaries.clear();
    _loadingSummaryIds.clear();
    _bulkSelectedIds.clear();
    _threadEpoch++;
    notifyListeners();
    unawaited(updatePreferences(PreferencesPatch(account: accountId)));
    await loadMailbox(refresh: false);
  }

  Future<void> selectFolder(String folderId) async {
    _activeSettings = null;
    _activeFolder = folderId.toLowerCase() == 'inbox' ? 'inbox' : folderId;
    _activeLabel = null;
    _selectedMessageId = null;
    _conversation = const [];
    _bulkSelectedIds.clear();
    notifyListeners();
    await loadMailbox(refresh: false);
  }

  Future<void> selectLabel(String labelName) async {
    _activeSettings = null;
    _activeLabel = labelName;
    _selectedMessageId = null;
    _conversation = const [];
    _bulkSelectedIds.clear();
    notifyListeners();
    await loadMailbox(refresh: false);
  }

  /// Back to the whole folder, newest first.
  Future<void> clearFilters() async {
    _sort = ThreadSort.newest;
    if (_activeLabel != null) {
      await selectFolder(_activeFolder);
    } else {
      notifyListeners();
    }
    if (_searchQuery.isNotEmpty) await setSearchQuery('');
  }

  Future<void> setSearchQuery(String query) async {
    _searchQuery = query;
    notifyListeners();
    await loadMailbox(refresh: false);
  }

  Future<void> loadLabels() async {
    try {
      _labels = await _backend.labels(_activeAccount);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadMailbox({bool refresh = true}) async {
    final epoch = ++_mailboxEpoch;
    final account = _activeAccount;
    final folder = _activeFolder;
    final label = _activeLabel;
    final query = _searchQuery;
    if (account.isEmpty) {
      _folders = const [];
      _labels = const {};
      _messages = const [];
      _threads = const [];
      _drafts = const [];
      _refreshing = false;
      _loadingMore = false;
      _hasMore = false;
      _loadMoreError = null;
      _nextOffset = 0;
      notifyListeners();
      return;
    }
    final limit = pageSize;
    _refreshing = true;
    _loadingMore = false;
    _loadMoreError = null;
    _error = null;
    notifyListeners();
    try {
      final folders = await _backend.folders(account);
      if (epoch != _mailboxEpoch) return;
      final labels = await _backend.labels(account);
      if (epoch != _mailboxEpoch) return;

      final isDrafts =
          folder.toLowerCase() == 'drafts' ||
          folders.any((f) => f.id == folder && f.role == FolderRole.drafts);
      if (isDrafts && label == null) {
        final drafts = await _backend.drafts(account);
        if (epoch != _mailboxEpoch) return;
        _folders = folders;
        _labels = labels;
        _drafts = drafts;
        _messages = const [];
        _setThreads(const []);
        _nextOffset = 0;
        _hasMore = false;
      } else {
        final List<MailMessage> messages;
        if (refresh || query.isNotEmpty) {
          messages = await _backend.refreshMessages(
            account,
            folder: folder,
            query: query,
            limit: limit,
          );
        } else {
          final snap = await _backend.cachedMessages(
            account,
            folder: folder,
            query: query,
            limit: limit,
          );
          // If no cached snapshot exists yet for a connected non-demo account
          // (e.g. first load of Gmail Inbox or opening another folder), fetch
          // from the provider immediately instead of showing an empty list.
          if (snap.messages.isEmpty &&
              snap.fetchedAt == null &&
              account != 'demo' &&
              (currentAccountInfo?.connected ?? false)) {
            messages = await _backend.refreshMessages(
              account,
              folder: folder,
              query: query,
              limit: limit,
            );
          } else {
            messages = snap.messages;
          }
        }
        if (epoch != _mailboxEpoch) return;
        _folders = folders;
        _labels = labels;
        _messages = messages;
        _nextOffset = messages.length;
        _hasMore =
            label == null &&
            messages.length >= limit &&
            _nextOffset < maxListOffset;
        var visible = messages;
        if (label != null) {
          final allowed = (labels[label] ?? const <String>[]).toSet();
          visible = messages
              .where((m) => allowed.contains(m.id))
              .toList(growable: false);
        }
        _setThreads(groupConversations(visible));
      }
      _syncedAt = DateTime.now();
      await _loadSyncStatus();
    } on MailBackendException catch (e) {
      if (epoch != _mailboxEpoch) return;
      if (e.isAuthRequired) _authRequired = true;
      _error = e.message;
      showToast(e.message, isError: true);
    } finally {
      if (epoch == _mailboxEpoch) {
        _refreshing = false;
        notifyListeners();
      }
    }
  }

  /// Fetches the next page of older messages and appends them without
  /// replacing or duplicating already-loaded messages.
  Future<void> loadMoreMessages() async {
    if (!canPaginate ||
        _loadingMore ||
        _refreshing ||
        !_hasMore ||
        _nextOffset >= maxListOffset) {
      return;
    }
    final epoch = _mailboxEpoch;
    final account = _activeAccount;
    final folder = _activeFolder;
    final query = _searchQuery;
    final offset = _nextOffset;
    final limit = pageSize;

    _loadingMore = true;
    _loadMoreError = null;
    notifyListeners();
    try {
      final page = await _backend.refreshMessages(
        account,
        folder: folder,
        query: query,
        offset: offset,
        limit: limit,
      );
      if (epoch != _mailboxEpoch) return;
      final existingIds = _messages.map((m) => m.id).toSet();
      final fresh = page
          .where((m) => existingIds.add(m.id))
          .toList(growable: false);
      _nextOffset = offset + page.length;
      if (fresh.isNotEmpty) {
        _messages = [..._messages, ...fresh];
        _setThreads(groupConversations(_messages));
      }
      _hasMore = page.length >= limit && _nextOffset < maxListOffset;
    } on MailBackendException catch (e) {
      if (epoch != _mailboxEpoch) return;
      if (e.isAuthRequired) _authRequired = true;
      _loadMoreError = e.message;
    } finally {
      if (epoch == _mailboxEpoch) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Conversations open in the reader as tabs, per account, as in
  /// Colecto's reader. Opening one adds a tab; at most [maxOpenTabs].
  final Map<String, List<ConversationThread>> _tabs = {};
  static const maxOpenTabs = 30;

  List<ConversationThread> get openTabs => _tabs[_activeAccount] ?? const [];

  /// The tab showing the selected message, if any.
  String? get activeTabId => openTabs
      .where((t) => t.messages.any((m) => m.id == _selectedMessageId))
      .firstOrNull
      ?.id;

  void _remember(ConversationThread thread) {
    final list = [...openTabs];
    final at = list.indexWhere((t) => t.id == thread.id);
    if (at >= 0) {
      list[at] = thread;
    } else {
      if (list.length >= maxOpenTabs) list.removeAt(0);
      list.add(thread);
    }
    _tabs[_activeAccount] = list;
  }

  /// Closes a message tab; closing the one shown opens its neighbour.
  void closeTab(String threadId) {
    final list = [...openTabs];
    final at = list.indexWhere((t) => t.id == threadId);
    if (at < 0) return;
    final shown = activeTabId == threadId;
    list.removeAt(at);
    _tabs[_activeAccount] = list;
    if (!shown) return notifyListeners();
    if (list.isEmpty) return clearSelection();
    unawaited(selectThread(list[at.clamp(0, list.length - 1)]));
  }

  void closeOtherTabs(ConversationThread keep) {
    _tabs[_activeAccount] = [keep];
    unawaited(selectThread(keep));
  }

  void closeAllTabs() {
    _tabs.remove(_activeAccount);
    clearSelection();
  }

  void _forgetTabs(Iterable<String> messageIds) {
    final ids = messageIds.toSet();
    final list = openTabs
        .where((t) => !t.messages.any((m) => ids.contains(m.id)))
        .toList();
    _tabs[_activeAccount] = list;
  }

  Future<void> selectThread(ConversationThread thread) async {
    final epoch = ++_threadEpoch;
    final account = _activeAccount;
    final folder = _activeFolder;
    final latest = thread.latest;
    final fallback = [
      for (final m in thread.messages)
        ThreadMessage(folder: folder, message: m),
    ];
    _remember(thread);
    _selectedMessageId = latest.id;
    _conversation = fallback;
    _compose = null;
    notifyListeners();

    try {
      final conversation = await _backend.conversation(account, latest.id);
      if (epoch != _threadEpoch || account != _activeAccount) return;
      _conversation = conversation.isNotEmpty ? conversation : fallback;
      notifyListeners();
    } on MailBackendException catch (e) {
      if (epoch != _threadEpoch || account != _activeAccount) return;
      showToast(e.message, isError: true);
    }

    if (epoch != _threadEpoch || account != _activeAccount) return;
    for (final tm in _conversation) {
      unawaited(loadMessageContent(tm.message.id));
    }
    if (thread.hasUnread) {
      final unreadIds = thread.messages
          .where((m) => !m.seen)
          .map((m) => m.id)
          .toList(growable: false);
      if (unreadIds.isNotEmpty) {
        await organizeMessages('flags', ids: unreadIds, seen: true);
      }
    }
    unawaited(loadSummary(latest.id));
  }

  void clearSelection() {
    _threadEpoch++;
    _selectedMessageId = null;
    _conversation = const [];
    notifyListeners();
  }

  void selectAdjacentThread(int delta) {
    final list = threads;
    if (list.isEmpty) return;
    final currentIdx = _selectedMessageId == null
        ? -1
        : list.indexWhere(
            (t) => t.messages.any((m) => m.id == _selectedMessageId),
          );
    final nextIdx = currentIdx < 0
        ? (delta > 0 ? 0 : list.length - 1)
        : (currentIdx + delta).clamp(0, list.length - 1);
    unawaited(selectThread(list[nextIdx]));
  }

  Future<void> loadMessageContent(
    String messageId, {
    bool? remoteImages,
    bool force = false,
  }) async {
    final account = _activeAccount;
    if (!force &&
        remoteImages == null &&
        _contentCache.containsKey(messageId)) {
      return;
    }
    _loadingContentIds.add(messageId);
    notifyListeners();
    try {
      final content = await _backend.messageContent(
        account,
        messageId,
        remoteImages: remoteImages,
      );
      if (account != _activeAccount) return;
      _contentCache.remove(messageId);
      _contentCache[messageId] = content;
      while (_contentCache.length > _maxContentCache) {
        _contentCache.remove(_contentCache.keys.first);
      }
    } on MailBackendException catch (e) {
      if (account == _activeAccount) showToast(e.message, isError: true);
    } finally {
      if (account == _activeAccount) {
        _loadingContentIds.remove(messageId);
        notifyListeners();
      }
    }
  }

  void toggleBulkSelect(String messageId) {
    if (!_bulkSelectedIds.remove(messageId)) {
      _bulkSelectedIds.add(messageId);
    }
    notifyListeners();
  }

  void selectAllVisible() {
    _bulkSelectedIds
      ..clear()
      ..addAll(_threads.map((t) => t.latest.id));
    notifyListeners();
  }

  void clearBulkSelection() {
    _bulkSelectedIds.clear();
    notifyListeners();
  }

  Future<void> organizeMessages(
    String action, {
    required List<String> ids,
    bool? seen,
    bool? flagged,
    String? folder,
  }) async {
    if (ids.isEmpty) return;
    final account = _activeAccount;
    final previousFolder = _activeFolder;
    try {
      await _backend.organizeMessages(
        account,
        action,
        ids: ids,
        seen: seen,
        flagged: flagged,
        folder: folder,
      );
      if (action == 'archive' || action == 'delete' || action == 'move') {
        _forgetTabs(ids);
        if (ids.contains(_selectedMessageId)) {
          _selectedMessageId = null;
          _conversation = const [];
        }
        _bulkSelectedIds.removeAll(ids);
        showToast(
          switch (action) {
            'archive' => 'Archived ${_plural(ids.length, 'message')}',
            'delete' => 'Moved ${_plural(ids.length, 'message')} to Trash',
            _ => 'Moved ${_plural(ids.length, 'message')}',
          },
          actionLabel: 'Undo',
          onAction: () => _undoMove(
            account: account,
            ids: List<String>.from(ids),
            targetFolder: previousFolder,
          ),
        );
      }
      await loadMailbox(refresh: false);
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> _undoMove({
    required String account,
    required List<String> ids,
    required String targetFolder,
  }) async {
    try {
      await _backend.organizeMessages(
        account,
        'move',
        ids: ids,
        folder: targetFolder,
      );
      if (account == _activeAccount) {
        await loadMailbox(refresh: false);
      }
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> updateLabel({
    required String name,
    String? messageId,
    bool remove = false,
  }) async {
    try {
      _labels = await _backend.updateLabel(
        _activeAccount,
        name: name,
        messageId: messageId,
        remove: remove,
      );
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  List<String> labelsForMessage(String messageId) {
    final result = <String>[];
    for (final entry in _labels.entries) {
      if (entry.value.contains(messageId)) result.add(entry.key);
    }
    return result;
  }

  // Drafts & Send
  Future<Draft?> saveDraft(DraftInput input, {bool quiet = false}) async {
    try {
      final saved = await _backend.saveDraft(_activeAccount, input);
      _drafts = await _backend.drafts(_activeAccount);
      notifyListeners();
      return saved;
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  /// Grace period before an outgoing message is actually dispatched.
  static const sendDelay = Duration(seconds: 5);

  /// Duration of the Undo toast during the grace period (0.5 s shorter than
  /// [sendDelay] so the user can never tap Undo after dispatch).
  static const sendUndoToastDuration = Duration(milliseconds: 4500);

  /// Queues [input] for dispatch after [sendDelay] (5 s), showing a 4.5 s
  /// "Email sent" notification with an Undo action that cancels dispatch and
  /// reopens the composer with the message intact.
  void scheduleSend(DraftInput input) {
    final account = _activeAccount;
    final token = ++_pendingSendSeq;
    final toastId = showToast(
      'Email sent',
      actionLabel: 'Undo',
      duration: sendUndoToastDuration,
      allowHoverHold: false,
      onAction: () {
        final pending = _pendingSends.remove(token);
        if (pending == null) return;
        pending.timer.cancel();
        startCompose(
          ComposeRequest(
            draftId: input.id,
            to: input.recipient,
            cc: input.cc,
            subject: input.subject,
            body: input.body,
            attachments: input.attachments,
          ),
        );
      },
    );
    final timer = Timer(sendDelay, () {
      _pendingSends.remove(token);
      if (_disposed) return;
      unawaited(_dispatchScheduledSend(account, input));
    });
    _pendingSends[token] = _PendingSend(
      timer: timer,
      account: account,
      input: input,
      toastId: toastId,
    );
  }

  /// Skips the remaining 5-second grace period for all queued outgoing emails,
  /// immediately dismisses their Undo notifications, and dispatches them now.
  Future<void> flushPendingSends() async {
    if (_pendingSends.isEmpty) return;
    final batch = _pendingSends.values.toList(growable: false);
    _pendingSends.clear();
    final futures = <Future<void>>[];
    for (final pending in batch) {
      pending.timer.cancel();
      if (pending.toastId != null) {
        dismissToast(pending.toastId!);
      }
      futures.add(_dispatchScheduledSend(pending.account, pending.input));
    }
    await Future.wait(futures);
  }

  Future<void> _dispatchScheduledSend(String account, DraftInput input) async {
    try {
      final outcome = await _backend.send(account, input);
      if (_disposed) return;
      if (outcome.requiresApproval) {
        showToast(
          'Waiting for approval',
          detail: 'Approve it in Settings → Send approvals to send it.',
        );
        unawaited(loadSendRequests());
      }
      if (account == _activeAccount) {
        await loadMailbox(refresh: false);
      }
    } on MailBackendException catch (e) {
      if (_disposed) return;
      showToast(e.message, isError: true);
      startCompose(
        ComposeRequest(
          draftId: input.id,
          to: input.recipient,
          cc: input.cc,
          subject: input.subject,
          body: input.body,
          attachments: input.attachments,
        ),
      );
    }
  }

  Future<DeliveryOutcome?> sendMail(DraftInput input) async {
    try {
      final outcome = await _backend.send(_activeAccount, input);
      if (outcome.requiresApproval) {
        showToast(
          'Waiting for approval',
          detail: 'Approve it in Settings → Send approvals to send it.',
        );
        unawaited(loadSendRequests());
      }
      await loadMailbox(refresh: false);
      return outcome;
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  // Accounts & Security
  Future<void> reloadAccounts() async {
    try {
      _accounts = await _backend.listAccounts();
      await _loadSyncStatus();
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  /// Saves an account. A failure goes to [onError] when given (the account
  /// wizard shows it in place), otherwise to a toast.
  Future<AccountInfo?> saveAccount(
    AccountInput input, {
    ValueChanged<String>? onError,
  }) async {
    try {
      final info = await _backend.upsertAccount(input);
      await reloadAccounts();
      if (_activeAccount.isEmpty && _preferences.accountEnabled(info.id)) {
        await selectAccount(info.id);
      }
      return info;
    } on MailBackendException catch (e) {
      if (onError != null) {
        onError(e.message);
      } else {
        showToast(e.message, isError: true);
      }
      return null;
    }
  }

  /// Asks the provider for a fresh Inbox, which shows at once whether the
  /// account connects.
  Future<bool> reconnectAccount(String id) async {
    try {
      await _backend.refreshMessages(id);
      await reloadAccounts();
      return true;
    } on MailBackendException catch (e) {
      showToast('Could not connect', detail: e.message, isError: true);
      await reloadAccounts();
      return false;
    }
  }

  Future<DiscoveryResult?> discoverAccount(String address) async {
    try {
      return await _backend.discoverAccount(address);
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  Future<void> disconnectAccount(String id) async {
    try {
      await _backend.disconnectAccount(id);
      await reloadAccounts();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> removeAccount(String id) async {
    try {
      await _backend.removeAccount(id);
      await reloadAccounts();
      if (_activeAccount == id) {
        if (enabledAccounts.isNotEmpty) {
          await selectAccount(enabledAccounts.first.id);
        } else {
          _activeAccount = '';
          _folders = const [];
          _labels = const {};
          _messages = const [];
          _threads = const [];
          _drafts = const [];
          _selectedMessageId = null;
          _conversation = const [];
          _contentCache.clear();
          _summaries.clear();
          _bulkSelectedIds.clear();
          notifyListeners();
        }
      }
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> loadSecurity() async {
    try {
      _security = await _backend.security();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> runSecurityAction(String action, {String password = ''}) async {
    try {
      _security = await _backend.securityAction(action, password: password);
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  // Backups
  /// A backup of this service's data; a failure goes to [onError].
  Future<({String filename, Uint8List bytes})?> exportBackup({
    String passphrase = '',
    required ValueChanged<String> onError,
  }) async {
    try {
      return await _backend.exportBackup(passphrase: passphrase);
    } on MailBackendException catch (e) {
      onError(e.message);
      return null;
    }
  }

  /// Restores a backup, then reloads everything from it. Returns whether it
  /// worked; a failure goes to [onError] and changes nothing.
  Future<bool> importBackup(
    Uint8List bytes, {
    String passphrase = '',
    required ValueChanged<String> onError,
  }) async {
    try {
      await _backend.importBackup(bytes, passphrase: passphrase);
    } on MailBackendException catch (e) {
      onError(e.message);
      return false;
    }
    _tabs.clear();
    _activeAccount = '';
    _selectedMessageId = null;
    _conversation = const [];
    _contentCache.clear();
    _summaries.clear();
    await initialize();
    showToast(
      'Backup restored',
      detail: 'Accounts without saved passwords need you to sign in again.',
    );
    return true;
  }

  // AI
  Future<void> loadAiSettings() async {
    try {
      _aiSettings = await _backend.aiSettings(account: _activeAccount);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveAiSettings(AiSettings settings) async {
    try {
      _aiSettings = await _backend.aiUpdateSettings(
        settings,
        account: _activeAccount,
      );
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> saveAiKey(String kind, String? key) async {
    try {
      _aiSettings = await _backend.aiPutKey(kind: kind, key: key);
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<bool> testAiConnection(String kind) async {
    try {
      final ok = await _backend.aiTestConnection(
        kind: kind,
        account: _activeAccount,
      );
      showToast(
        ok ? 'Connection succeeded' : 'Connection failed',
        isError: !ok,
      );
      return ok;
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return false;
    }
  }

  Future<PreviewResult?> previewAiRule(LabelRule rule) async {
    try {
      return await _backend.aiPreview(_activeAccount, rule);
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  Future<void> reclassifyMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final res = await _backend.aiReclassify(_activeAccount, ids);
      await loadLabels();
      showToast(
        'Reclassified ${_plural(res.checked, 'message')}',
        detail: res.changed == 0
            ? 'No labels changed.'
            : '${_plural(res.changed, 'label change')}.',
      );
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> loadSummary(String messageId) async {
    try {
      final summary = await _backend.aiGetSummary(_activeAccount, messageId);
      if (summary != null && summary.isNotEmpty) {
        _summaries.remove(messageId);
        _summaries[messageId] = summary;
        while (_summaries.length > _maxSummariesCache) {
          _summaries.remove(_summaries.keys.first);
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> generateSummary(String messageId) async {
    _loadingSummaryIds.add(messageId);
    notifyListeners();
    try {
      final summary = await _backend.aiCreateSummary(_activeAccount, messageId);
      _summaries.remove(messageId);
      _summaries[messageId] = summary;
      while (_summaries.length > _maxSummariesCache) {
        _summaries.remove(_summaries.keys.first);
      }
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    } finally {
      _loadingSummaryIds.remove(messageId);
      notifyListeners();
    }
  }

  Future<void> deleteSummary(String messageId) async {
    try {
      await _backend.aiDeleteSummary(_activeAccount, messageId);
      _summaries.remove(messageId);
      notifyListeners();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<String?> generateAiReply({
    required String messageId,
    required String notes,
    required String tone,
  }) async {
    try {
      return await _backend.aiDraftReply(
        _activeAccount,
        messageId: messageId,
        input: notes,
        tone: tone,
      );
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  // API Keys & Send Approvals
  Future<void> loadApiKeys() async {
    try {
      _apiKeys = await _backend.listApiKeys();
      notifyListeners();
    } catch (_) {}
  }

  Future<MintedApiKey?> mintApiKey(ApiKeyInput input) async {
    try {
      final minted = await _backend.mintApiKey(input);
      await loadApiKeys();
      return minted;
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
      return null;
    }
  }

  Future<void> revokeApiKey(String id) async {
    try {
      await _backend.revokeApiKey(id);
      await loadApiKeys();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  Future<void> loadSendRequests() async {
    try {
      _sendRequests = await _backend.listSendRequests();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> decideSendRequest(String id, {required bool approve}) async {
    try {
      if (approve) {
        await _backend.approveSend(id);
      } else {
        await _backend.rejectSend(id);
      }
      await loadSendRequests();
    } on MailBackendException catch (e) {
      showToast(e.message, isError: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _heldToasts.clear();
    for (final timer in _toastTimers.values) {
      timer.cancel();
    }
    _toastTimers.clear();
    for (final pending in _pendingSends.values) {
      pending.timer.cancel();
    }
    _pendingSends.clear();
    _eventSub?.cancel();
    _backend.dispose();
    super.dispose();
  }
}

class _PendingSend {
  const _PendingSend({
    required this.timer,
    required this.account,
    required this.input,
    this.toastId,
  });

  final Timer timer;
  final String account;
  final DraftInput input;
  final int? toastId;
}
