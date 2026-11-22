import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:colecto/data/repositories/in_memory_mail_backend.dart';
import 'package:colecto/domain/models/automation_models.dart';
import 'package:colecto/domain/models/mail_models.dart';
import 'package:colecto/domain/models/preferences_models.dart';
import 'package:colecto/ui/core/theme/colecto_palette.dart';
import 'package:colecto/ui/features/settings/account_wizard.dart';
import 'package:colecto/ui/features/settings/settings_view.dart';
import 'package:colecto/ui/features/shell/mail_controller.dart';

import 'test_helpers.dart';

void main() {
  group('ColectoApp core user flows', () {
    Finder wizardField(int i) => find
        .descendant(
          of: find.byType(AccountWizard),
          matching: find.byType(EditableText),
        )
        .at(i);

    /// Email, then Servers (found by lookup), then Review.
    Future<void> walkWizard(WidgetTester tester, String save) async {
      await tester.enterText(wizardField(0), 'me@fastmail.com');
      await tester.tap(find.text('Continue').last);
      await tester.pumpAndSettle();
      expect(find.text('Settings found for Fastmail'), findsOneWidget);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AccountWizard),
              matching: find.byType(EditableText),
            )
            .last,
        'app-password',
      );
      await tester.tap(find.text('Continue').last);
      await tester.pumpAndSettle();
      expect(find.text('Receives mail from'), findsOneWidget);
      expect(find.text('imap.fastmail.com'), findsOneWidget);
      await tester.tap(find.text(save).last);
      await tester.pumpAndSettle();
    }

    for (final (design, size) in const [
      (ColectoPlatformStyle.desktop, Size(1280, 800)),
      (ColectoPlatformStyle.ios, Size(390, 844)),
    ]) {
      testWidgets('first run adds an account and opens its Inbox '
          '(${design.id})', (tester) async {
        final c = await pumpColectoApp(
          tester,
          size: size,
          design: design,
          onboarded: false,
        );
        expect(find.text('Welcome to Colecto'), findsOneWidget);
        await tester.tap(find.text('Add your first account'));
        await tester.pumpAndSettle();
        await walkWizard(tester, 'Connect account');
        expect(find.text('You’re all set'), findsOneWidget);
        await tester.tap(find.text('Open Inbox'));
        await tester.pumpAndSettle();
        expect(c.preferences.onboarded, isTrue);
        expect(c.showsOnboarding, isFalse);
        expect(c.accounts.any((a) => a.address == 'me@fastmail.com'), isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('first run can skip to the sample mail', (tester) async {
      final c = await pumpColectoApp(tester, onboarded: false);
      // The sample account stays off unless the person asks for it.
      expect(c.preferences.accountEnabled('demo'), isFalse);
      await tester.tap(find.text('Explore with sample mail first'));
      await tester.pumpAndSettle();
      expect(c.preferences.onboarded, isTrue);
      expect(c.preferences.accountEnabled('demo'), isTrue);
      expect(find.text('Welcome to Colecto'), findsWidgets);
    });

    testWidgets('a row menu labels and moves mail, and the list sorts', (
      tester,
    ) async {
      final c = await pumpColectoApp(tester);
      await tester.tap(
        find.text('Q4 Architecture Review').first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Label: Newsletters'), findsOneWidget);
      expect(find.text('Move to Sent'), findsOneWidget);
      await tester.tap(find.text('Label: Newsletters'));
      await tester.pumpAndSettle();
      expect(
        c.labels['Newsletters'],
        contains(
          c.threads.firstWhere((t) => t.subject.contains('Q4')).latest.id,
        ),
      );

      c.setSort(ThreadSort.subject);
      await tester.pumpAndSettle();
      expect(find.text('Sorted subject a–z'), findsOneWidget);
      final subjects = [for (final t in c.threads) t.subject.toLowerCase()];
      expect(subjects, [...subjects]..sort());
      await tester.tap(find.byTooltip('Clear sorting'));
      await tester.pumpAndSettle();
      expect(c.sort, ThreadSort.newest);
    });

    testWidgets('a locked backup needs matching passphrases', (tester) async {
      final c = await pumpColectoApp(tester);
      c.openSettings(SettingsSection.backup);
      await tester.pumpAndSettle();
      expect(find.text('Export a backup'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(SettingsView),
        matching: find.byType(EditableText),
      );
      await tester.enterText(fields.at(0), 'correct horse');
      await tester.enterText(fields.at(1), 'correct house');
      await tester.tap(find.text('Export backup…'));
      await tester.pumpAndSettle();
      expect(find.text('The passphrases do not match.'), findsOneWidget);
    });

    testWidgets('open messages stay as reader tabs', (tester) async {
      final c = await pumpColectoApp(tester);
      await tester.tap(find.text('Welcome to Colecto').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Q4 Architecture Review').first);
      await tester.pumpAndSettle();
      expect(c.openTabs.length, 2);
      expect(c.activeTabId, c.openTabs.last.id);

      // Back to the first tab, then close it: its neighbour shows.
      await tester.tap(find.byTooltip('Welcome to Colecto'));
      await tester.pumpAndSettle();
      expect(c.activeTabId, c.openTabs.first.id);
      c.closeTab(c.openTabs.first.id);
      await tester.pumpAndSettle();
      expect(c.openTabs.length, 1);
      expect(c.activeTabId, c.openTabs.single.id);

      // Right-click a tab for Close all.
      await tester.tap(
        find.byTooltip('Q4 Architecture Review'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close all'));
      await tester.pumpAndSettle();
      expect(c.openTabs, isEmpty);
      expect(c.selectedMessageId, isNull);
    });

    testWidgets('long-press opens a row’s menu on touch designs', (
      tester,
    ) async {
      await pumpColectoApp(
        tester,
        size: const Size(390, 844),
        design: ColectoPlatformStyle.ios,
      );
      await tester.longPress(find.text('Q4 Architecture Review').first);
      await tester.pumpAndSettle();
      expect(find.text('Archive'), findsWidgets);
    });

    testWidgets('Settings adds an account through the three-step wizard', (
      tester,
    ) async {
      final c = await pumpColectoApp(tester);
      c.openSettings(SettingsSection.accounts);
      await tester.pumpAndSettle();
      expect(find.text('Accounts & security'), findsOneWidget);
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();
      expect(find.text('Add an account'), findsOneWidget);
      await walkWizard(tester, 'Save account');
      expect(find.byType(AccountWizard), findsNothing);
      expect(find.text('me@fastmail.com'), findsOneWidget);
      expect(c.accounts.length, 2);
    });

    testWidgets(
      'desktop layout reads mail, blocks remote images, and approves a send',
      (tester) async {
        final c = await pumpColectoApp(tester);

        expect(find.text('Colecto'), findsOneWidget);
        expect(find.text('Welcome to Colecto'), findsOneWidget);

        await tester.tap(find.text('Welcome to Colecto'));
        await tester.pumpAndSettle();
        expect(find.textContaining('remote images blocked'), findsOneWidget);
        expect(find.text('Reply'), findsOneWidget);

        await tester.tap(find.text('Send approvals'));
        await tester.pumpAndSettle();
        expect(
          find.text('Confirming Friday architecture sync'),
          findsOneWidget,
        );

        await tester.tap(find.text('Approve and send'));
        await tester.pumpAndSettle();
        expect(find.text('Approve and send'), findsNothing);
        expect(c.sendRequests.first.status, ApprovalStatus.sent);
      },
    );

    testWidgets(
      'composer opens in the reader and saves unfinished writing as a draft',
      (tester) async {
        final c = await pumpColectoApp(tester);
        c.startCompose();
        await tester.pumpAndSettle();
        expect(find.text('New message'), findsOneWidget);

        final to = tester.widget<TextField>(
          find.byWidgetPredicate(
            (w) =>
                w is TextField && w.decoration?.hintText == 'name@example.com',
          ),
        );
        to.controller!.text = 'ana@example.com';
        await tester.pump();
        expect(find.text('Unsaved changes'), findsOneWidget);

        c.closeCompose();
        await tester.pumpAndSettle();
        expect(c.drafts.any((d) => d.recipient == 'ana@example.com'), isTrue);
      },
    );

    testWidgets(
      'command palette opens via Ctrl+K, filters commands, and opens compose',
      (tester) async {
        await pumpColectoApp(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(find.text('New message'), findsOneWidget);
        await tester.tap(find.text('New message'));
        await tester.pumpAndSettle();
        expect(find.text('New message'), findsOneWidget);
        expect(find.text('Send'), findsOneWidget);
      },
    );

    testWidgets('settings sections render without errors and persist changes', (
      tester,
    ) async {
      final c = await pumpColectoApp(tester);

      for (final section in SettingsSection.values) {
        c.openSettings(section);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      c.closeSettings();
      await tester.pumpAndSettle();
      expect(c.activeSettings, isNull);

      // Settings is a real modal route: Escape dismisses it and the
      // controller hears about it.
      c.openSettings();
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(c.activeSettings, isNull);
      expect(find.text('Appearance'), findsNothing);
    });

    testWidgets(
      'phone Settings starts at the section list and goes back to it',
      (tester) async {
        final c = await pumpColectoApp(
          tester,
          size: const Size(390, 844),
          design: ColectoPlatformStyle.ios,
        );
        c.openSettings();
        await tester.pumpAndSettle();
        expect(c.showsSettingsIndex, isTrue);

        await tester.tap(find.text('Appearance'));
        await tester.pumpAndSettle();
        expect(c.activeSettings, SettingsSection.appearance);
        expect(find.text('Theme'), findsOneWidget);

        // Back leads to the list, not out of Settings.
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(c.showsSettingsIndex, isTrue);
        expect(c.activeSettings, isNotNull);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(c.activeSettings, isNull);
      },
    );

    testWidgets('phones get a native list with a bottom folder bar', (
      tester,
    ) async {
      await pumpColectoApp(
        tester,
        size: const Size(400, 820),
        design: ColectoPlatformStyle.android,
      );
      expect(find.text('Welcome to Colecto'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Pick a message and it will open here.'), findsNothing);
    });

    testWidgets(
      'shows Load more link when auto-load is off and appends older messages',
      (tester) async {
        final backend = _PagedListBackend(total: 35);
        final c = await pumpColectoApp(tester, backend: backend);
        await c.updatePreferences(
          const PreferencesPatch(
            autoLoadMore: false,
            prefetch: PrefetchPreferences(enabled: true, count: 25),
          ),
        );
        await c.loadMailbox(refresh: true);
        await tester.pumpAndSettle();

        expect(c.messages.length, 25);
        final scrollable = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Load more'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('Load more'), findsOneWidget);

        await tester.tap(find.text('Load more'));
        await tester.pumpAndSettle();
        expect(c.messages.length, 35);
        await tester.scrollUntilVisible(
          find.text('No older messages'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('No older messages'), findsOneWidget);
      },
    );
  });
}

class _PagedListBackend extends InMemoryMailBackend {
  _PagedListBackend({required int total})
    : _items = List.generate(
        total,
        (i) => MailMessage(
          id: 'w-$i',
          sender: 'Author $i',
          address: 'a$i@example.com',
          subject: 'Batch email $i',
          body: 'Preview $i',
          date: DateTime.utc(
            2026,
            11,
            21,
          ).subtract(Duration(minutes: i)).toIso8601String(),
          seen: true,
          thread: 'wt-$i',
        ),
      );

  final List<MailMessage> _items;

  @override
  Future<MailSnapshot> cachedMessages(
    String account, {
    String folder = 'inbox',
    String query = '',
    int offset = 0,
    int? limit,
  }) async {
    final slice = _slice(offset, limit);
    return MailSnapshot(folder: folder, messages: slice, fetchedAt: 1700000000);
  }

  @override
  Future<List<MailMessage>> refreshMessages(
    String account, {
    String folder = 'inbox',
    String query = '',
    int offset = 0,
    int? limit,
  }) async => _slice(offset, limit);

  List<MailMessage> _slice(int offset, int? limit) {
    if (offset >= _items.length) return const [];
    final end = limit == null
        ? _items.length
        : (offset + limit).clamp(offset, _items.length);
    return _items.sublist(offset, end);
  }
}
