import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/add_component_dialog.dart';
import 'package:component_manager/screens/detail_screen.dart';
import 'package:component_manager/widgets/component_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// CID 可空（无 C 号手录）：
/// - 内部隐藏编号 newInternalCid 格式正确、绝不形如 C+数字；
/// - repo.insert 空 cid → 自动铸造内部编号，byCid 可查回；
/// - 卡片 / 详情一律不显示该编号，只显示「无 C 号」；
/// - 详情页「合并到真实 C 号」→ mergeToReal 数量相加 + 源软删 + 事务；
/// - attachRealCid：库存无该料时绑定为正式 C 号；占用则拒绝。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('内部隐藏编号（纯 Dart）', () {
    test('newInternalCid 前缀 local_，非 C 号；两次不同', () {
      final a = newInternalCid();
      final b = newInternalCid();
      expect(a, startsWith('local_'));
      expect(a.contains('C'), isFalse);
      expect(b, startsWith('local_'));
      expect(a, isNot(b));
      expect(RegExp(r'^C\d{5,}$').hasMatch(a), isFalse);
    });

    test('insert 空 cid → 自动铸造内部编号并落库；hasLcscCid/isNoCidEntry 正确', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final repo = ComponentRepository(db);

      final now = Component.now();
      final id = await repo.insert(Component(
        cid: '',
        model: 'SPL-LOOSE-01',
        category: '其他',
        quantity: 4,
        createdAt: now,
        updatedAt: now,
      ));
      expect(id, greaterThan(0));

      // 兜底铸造的是内部编号，不是空串
      final list = await repo.all();
      expect(list, hasLength(1));
      expect(list.single.cid, startsWith('local_'));
      expect(list.single.hasLcscCid, isFalse);
      expect(list.single.isNoCidEntry, isTrue);

      // 内部编号也能按 cid 查回（同步身份完整）
      final lookup = await repo.byCid(list.single.cid);
      expect(lookup.status, LookupStatus.active);
      expect(lookup.component!.model, 'SPL-LOOSE-01');
    });
  });

  group('mergeToReal（纯 Dart）', () {
    late Database db;
    late ComponentRepository repo;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await AppDatabase.openAt(inMemoryDatabasePath);
      repo = ComponentRepository(db);
    });

    tearDown(() => db.close());

    Future<String> seedNoCid(String model, int qty) async {
      final now = Component.now();
      final cid = newInternalCid();
      await repo.insert(Component(
        cid: cid,
        model: model,
        category: '其他',
        quantity: qty,
        createdAt: now,
        updatedAt: now,
      ));
      return cid;
    }

    Future<String> seedReal(String cid, String model, int qty) async {
      final now = Component.now();
      await repo.insert(Component(
        cid: cid,
        model: model,
        category: '电阻',
        quantity: qty,
        createdAt: now,
        updatedAt: now,
      ));
      return cid;
    }

    test('源并入目标：数量相加、源软删（可恢复，不硬删）', () async {
      final srcCid = await seedNoCid('LOOSE-RES', 3);
      await seedReal('C25704', 'RC0603FR-0710KL', 5);

      await repo.mergeToReal(sourceCid: srcCid, targetCid: 'C25704');

      final tgt = (await repo.byCid('C25704')).component!;
      expect(tgt.quantity, 8); // 5 + 3
      final src = (await repo.byCid(srcCid)).component!;
      expect(src.isDeleted, isTrue); // 软删进回收站（墓碑随同步传播）
      final restored = await repo.restore(src.id!); // 行仍在，可恢复
      expect(restored, 1);
    });

    test('源==目标 / 目标不存在 → StateError 且源不被软删（事务回滚）', () async {
      final srcCid = await seedNoCid('LOOSE-A', 2);

      await expectLater(
        repo.mergeToReal(sourceCid: srcCid, targetCid: srcCid),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.mergeToReal(sourceCid: srcCid, targetCid: 'C99999'),
        throwsA(isA<StateError>()),
      );
      expect((await repo.byCid(srcCid)).component!.isDeleted, isFalse);
    });

    test('源已删 → 拒绝', () async {
      final srcCid = await seedNoCid('LOOSE-B', 1);
      await repo.delete((await repo.byCid(srcCid)).component!.id!);
      await expectLater(
        repo.mergeToReal(sourceCid: srcCid, targetCid: 'C25704'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('attachRealCid（纯 Dart）', () {
    late Database db;
    late ComponentRepository repo;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await AppDatabase.openAt(inMemoryDatabasePath);
      repo = ComponentRepository(db);
    });

    tearDown(() => db.close());

    test('库存无该料 → 绑定为正式 C 号（身份升级，数量不变）', () async {
      final now = Component.now();
      final srcCid = newInternalCid();
      final id = await repo.insert(Component(
        cid: srcCid,
        model: 'LOOSE-CAP',
        category: '其他',
        quantity: 6,
        createdAt: now,
        updatedAt: now,
      ));

      await repo.attachRealCid(srcCid, 'C666001');

      final after = (await repo.byCid('C666001')).component!;
      expect(after.id, id);
      expect(after.hasLcscCid, isTrue);
      expect(after.isNoCidEntry, isFalse);
      expect(after.quantity, 6);
      expect((await repo.byCid(srcCid)).status, LookupStatus.notFound);
    });

    test('新 C 号已被占用 → StateError，源不被改写', () async {
      final now = Component.now();
      final srcCid = newInternalCid();
      await repo.insert(Component(
        cid: srcCid,
        model: 'LOOSE-X',
        category: '其他',
        quantity: 1,
        createdAt: now,
        updatedAt: now,
      ));
      await repo.insert(Component(
        cid: 'C777001',
        model: 'TAKEN-IC',
        category: 'IC',
        quantity: 9,
        createdAt: now,
        updatedAt: now,
      ));

      await expectLater(
        repo.attachRealCid(srcCid, 'C777001'),
        throwsA(isA<StateError>()),
      );
      final src = (await repo.byCid(srcCid)).component!;
      expect(src.isNoCidEntry, isTrue); // 仍是无 C 号，未被占用方覆盖
    });
  });

  group('卡片 / 详情展示（widget）', () {
    testWidgets('无 C 号卡片：无编号文本、灰标「无 C 号」、菜单无「复制 CID」',
        (tester) async {
      final c = Component(
        cid: 'local_abc123',
        model: 'SPL-LOOSE-01',
        category: '其他',
        quantity: 2,
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ComponentCard(
            component: c,
            onEdit: () {},
            onDeleteOrRestore: () {},
            onCopyCid: () {},
            onDetail: () {},
          ),
        ),
      ));

      // 主卡不显示内部编号：无「CID: local_…」，只有灰标「无 C 号」
      expect(find.textContaining('local_abc123'), findsNothing);
      expect(find.text('无 C 号'), findsOneWidget);

      // 长按菜单：头部副标题「无 C 号…」，且没有「复制 CID」项
      await tester.longPress(find.byType(ComponentCard));
      await tester.pumpAndSettle();
      expect(find.text('无 C 号（散料/内部编号）'), findsOneWidget);
      expect(find.text('复制 CID'), findsNothing);
    });

    testWidgets('详情页：无 C 号元件不显示编号、展示「合并到真实 C 号」入口',
        (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db =
          (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
      addTearDown(db.close);
      final state = AppState(db);
      final repo = state.components;
      final srcCid = newInternalCid();
      final now = Component.now();
      await tester.runAsync(() => repo.insert(Component(
            cid: srcCid,
            model: 'SPL-LOOSE-01',
            category: '其他',
            quantity: 2,
            createdAt: now,
            updatedAt: now,
          )));
      final c =
          (await tester.runAsync(() => repo.byCid(srcCid)))!.component!;

      await tester.pumpWidget(
          MaterialApp(home: DetailScreen(state: state, component: c)));
      await settle(tester);

      expect(find.text('无 C 号（内部编号）'), findsOneWidget);
      expect(find.textContaining(srcCid), findsNothing); // 绝不暴露编号
      expect(find.byKey(const ValueKey('merge_to_real_btn')), findsOneWidget);
    });

    testWidgets('空库手录留空 CID → 保存成功：落内部编号、首页只显「无 C 号」',
        (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final db =
          (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
      addTearDown(db.close);
      final repo = ComponentRepository(db);

      await tester.pumpWidget(ComponentManagerApp(AppState(db)));
      await settle(tester);

      await tester.tap(find.text('添加元件'));
      await tester.pump();
      await settle(tester);
      expect(find.byType(AddComponentDialog), findsOneWidget);

      // 型号填上，CID 留空
      final dialogFields = find.descendant(
          of: find.byType(AddComponentDialog),
          matching: find.byType(TextField));
      expect(dialogFields, findsNWidgets(7));
      await tester.enterText(dialogFields.at(0), 'SPL-LOOSE-01');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await settle(tester);

      // 首页卡片出现；内部编号绝不显示（搜索框 placeholder 含「CID」字样，
      // 但内部编号 local_… 不能在界面任何文本里出现），卡片标「无 C 号」。
      expect(find.text('SPL-LOOSE-01'), findsOneWidget);
      expect(find.text('无 C 号'), findsOneWidget);
      expect(find.textContaining('local_'), findsNothing);
      // 卡片不含「CID: …」段
      expect(
          find.descendant(
              of: find.byType(ComponentCard),
              matching: find.textContaining('CID')),
          findsNothing);

      final rows = (await tester.runAsync(() => repo.all()))!;
      expect(rows, hasLength(1));
      expect(rows.single.cid, startsWith('local_'));
      expect(rows.single.quantity, 1);
    });
  });
}
