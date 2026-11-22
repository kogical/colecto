import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:colecto/app.dart';
import 'package:colecto/ui/core/theme/colecto_palette.dart';
import 'package:colecto/ui/features/shell/mail_controller.dart';

import 'test_helpers.dart';

/// Worst-case layout resilience across all 5 native design systems.
///
/// Rather than running a 30-test cartesian product (5 designs × 3 sizes × 2 datasets),
/// every design is stressed at the narrowest mobile width (360 px — where overflows
/// actually happen), plus representative desktop (1280 px) and tablet (820 px)
/// viewports on two distinct desktop designs (`colecto` and `fluent`).
void main() {
  Future<void> exerciseWorstCase(
    WidgetTester tester,
    Size size,
    ColectoPlatformStyle design,
  ) async {
    final c = await pumpColectoApp(
      tester,
      size: size,
      design: design,
      worstCase: true,
    );

    // Longest message (attachments, recipients, long subject),
    // missing sender/subject, and a 27-message conversation.
    await c.selectThread(c.threads.first);
    await tester.pumpAndSettle();
    await c.selectThread(c.threads[1]);
    await tester.pumpAndSettle();
    await c.selectThread(c.threads.firstWhere((t) => t.messages.length > 20));
    await tester.pumpAndSettle();

    c.startCompose();
    await tester.pumpAndSettle();
    c.closeCompose();
    await tester.pumpAndSettle();

    // Check representative dense settings screens.
    for (final section in const [
      SettingsSection.accounts,
      SettingsSection.appearance,
      SettingsSection.ai,
    ]) {
      c.openSettings(section);
      await tester.pumpAndSettle();
    }
    c.closeSettings();
    await tester.pumpAndSettle();
    c.clearSelection();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  group('Worst-case layout resilience', () {
    for (final design in ColectoPlatformStyle.values) {
      testWidgets('${design.id} survives worst-case data at 360 px mobile', (
        tester,
      ) async {
        await exerciseWorstCase(tester, const Size(360, 740), design);
      });
    }

    for (final (design, size) in const [
      (ColectoPlatformStyle.desktop, Size(1280, 800)),
      (ColectoPlatformStyle.fluent, Size(820, 700)),
    ]) {
      testWidgets(
        '${design.id} survives worst-case data at ${size.width.toInt()} px',
        (tester) async {
          await exerciseWorstCase(tester, size, design);
        },
      );
    }

    testWidgets(
      'phone layout does not crash before folders load on Material or Cupertino',
      (tester) async {
        for (final design in const [
          ColectoPlatformStyle.android,
          ColectoPlatformStyle.ios,
        ]) {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          // Uninitialized controller has empty folders list.
          final c = MailController()..previewDesign(design);
          addTearDown(c.dispose);
          await tester.pumpWidget(ColectoApp(controller: c));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets('macOS Design select opens and switches back', (tester) async {
      final c = await pumpColectoApp(
        tester,
        size: const Size(1280, 800),
        design: ColectoPlatformStyle.macos,
      );
      c.openSettings(SettingsSection.appearance);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text(ColectoPlatformStyle.macos.label).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(ColectoPlatformStyle.macos.label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(ColectoPlatformStyle.fluent.label).last);
      await tester.pumpAndSettle();
      expect(c.design, ColectoPlatformStyle.fluent);
    });

    testWidgets('whole-interface zoom scales inner MediaQuery size', (
      tester,
    ) async {
      final c = await pumpColectoApp(
        tester,
        size: const Size(1280, 800),
        design: ColectoPlatformStyle.desktop,
      );
      await c.zoomIn(); // 110%
      await tester.pumpAndSettle();
      final innerCtx = tester.element(find.text('Colecto').first);
      final scaledSize = MediaQuery.sizeOf(innerCtx);
      expect(scaledSize.width, closeTo(1280 / 1.1, 1.0));
      expect(scaledSize.height, closeTo(800 / 1.1, 1.0));
    });

    testWidgets(
      'Ctrl+ and Ctrl- zoom globally even while Settings is open, and toasts show on top',
      (tester) async {
        final c = await pumpColectoApp(
          tester,
          size: const Size(1280, 800),
          design: ColectoPlatformStyle.desktop,
        );
        c.openSettings(SettingsSection.appearance);
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(c.zoom, closeTo(1.1, 0.01));
        expect(find.text('Zoom 110%'), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(c.zoom, closeTo(1.0, 0.01));
      },
    );

    testWidgets(
      'switching design from iOS to shadcn replaces CupertinoSheetRoute immediately and macOS switches cleanly',
      (tester) async {
        final c = await pumpColectoApp(
          tester,
          size: const Size(1280, 800),
          design: ColectoPlatformStyle.ios,
        );
        c.openSettings(SettingsSection.appearance);
        await tester.pumpAndSettle();

        await c.setDesign(ColectoPlatformStyle.desktop);
        await tester.pumpAndSettle();
        expect(c.design, ColectoPlatformStyle.desktop);
        expect(find.byType(CupertinoSheetTransition), findsNothing);
        expect(tester.takeException(), isNull);

        await c.setDesign(ColectoPlatformStyle.macos);
        await tester.pumpAndSettle();
        expect(c.design, ColectoPlatformStyle.macos);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'font picker shows grouped sections and design switch prompts when custom font is set',
      (tester) async {
        final c = await pumpColectoApp(
          tester,
          size: const Size(1280, 800),
          design: ColectoPlatformStyle.desktop,
        );
        c.openSettings(SettingsSection.appearance);
        await tester.pumpAndSettle();

        // Open grouped font picker and verify sections.
        await tester.tap(find.textContaining('Design default').first);
        await tester.pumpAndSettle();
        expect(find.text('THIS DESIGN'), findsOneWidget);
        expect(find.text('BUNDLED FONTS'), findsOneWidget);
        await tester.tap(find.text('Mona Sans').last);
        await tester.pumpAndSettle();
        expect(c.preferences.font, 'mona');

        // Switching design with a custom font prompts to keep or reset.
        await tester.ensureVisible(
          find.textContaining(ColectoPlatformStyle.desktop.label).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.textContaining(ColectoPlatformStyle.desktop.label).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(ColectoPlatformStyle.fluent.label).last);
        await tester.pumpAndSettle();
        expect(
          find.text('Use ${ColectoPlatformStyle.fluent.label}’s default font?'),
          findsOneWidget,
        );
        await tester.tap(find.text('Use default font'));
        await tester.pumpAndSettle();
        expect(c.design, ColectoPlatformStyle.fluent);
        expect(c.preferences.font ?? '', isEmpty);
      },
    );

    testWidgets('useless static Mail/Reader/Accounts tabs are removed', (
      tester,
    ) async {
      await pumpColectoApp(
        tester,
        size: const Size(1280, 800),
        design: ColectoPlatformStyle.desktop,
      );
      expect(find.text('Reader'), findsNothing);
      expect(find.text('Accounts'), findsNothing);
      expect(find.text('Mail'), findsNothing);
    });
  });
}
