import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/cart_parser.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/import_parser.dart';
import 'package:component_manager/models/component.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 立创购物车导入：表头自动识别 / 行→CartItem（合并、跳过、分类归类）/
/// 仓储批量入库（新增 / 累加 / 恢复不覆盖用户字段）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 购物车导出的 11 列中文表头（用户提供格式）。
  const header = [
    '购买类型', '商品编号/物料编码', '商品分类', '名称', '商品型号', '品牌',
    '封装规格', '单个毛重', '购买数量', '商品单价(元)', '金额(元)',
  ];

  List<List<String>> fixtureRows() => [
        header,
        // C66697：商品分类列空 → 分类靠「名称」hint 自动猜（贴片电阻）
        ['现货', 'C66697', '', '4.7kΩ ±1% 编带 贴片电阻', '4D03WGF4701T51',
            'UNI-ROYAL(厚声)', '0603×4', '0.00029', '50', '0.1161', '5.81'],
        // 同 C 号重复行（购物车可能出现）→ 数量应合并
        ['现货', 'C66697', '', '4.7k 排阻网络', '4D03WGF4701T51',
            'UNI-ROYAL(厚声)', '0603×4', '0.00029', '20', '0.1161', '2.32'],
        // 商品分类给出精确中文 → 直接命中，不猜
        ['现货', 'C12345', '电阻', '贴片电阻', 'RC0603FR-0710KL',
            'UNI-ROYAL(厚声)', '0603', '0.0001', '100', '0.01', '1.00'],
        // 商品编号为空 → 跳过
        ['现货', '', '电容', '贴片电容', 'GRM188R71C104KA01D', 'Murata',
            '0402', '0.0001', '50', '0.01', '0.50'],
        // 购买数量非法 → 跳过
        ['现货', 'C99999', '', '未知', 'TC-X', '-', 'SOT-23', '0.1', 'ABC',
            '0.1', '1.0'],
        // 型号列为空 → 回退「名称」；名称 hint 猜中传感器
        ['现货', 'C88888', '', 'DHT11 温度传感器模块', '', 'DHT(奥芯微)', 'TO-92',
            '0.1', '10', '0.5', '5.00'],
      ];

  test('11 列中文表头 → 自动识别编号/型号/数量/分类/品牌/封装/名称', () {
    final m = detectCartMapping(header);
    expect(m.codeCol, 1); // 商品编号/物料编码
    expect(m.modelCol, 4); // 商品型号
    expect(m.qtyCol, 8); // 购买数量
    expect(m.categoryCol, 2); // 商品分类
    expect(m.packageCol, 6); // 封装规格
    expect(m.brandCol, 5); // 品牌
    expect(m.nameCol, 3); // 名称
    expect(m.priceCol, 9); // 商品单价
    expect(m.isComplete, isTrue);
    expect(m.effectiveModelCol, 4);
  });

  test('CSV → 行解析：同 C 号合并数量、型号缺失回退名称、无效行跳过', () {
    // 经真实 parseCsv 通路（剥 BOM/裁剪尾空列/引号处理）再解析。
    final csv = const CsvEncoder().convert(fixtureRows());
    final rows = parseCsv(csv); // 走真实 CSV 通路（剥 BOM/引号/裁剪尾空列）

    final m = detectCartMapping(rows.first);
    final result = buildCartItems(rows, m);

    expect(result.skipped, 2);
    expect(result.skipReasons, hasLength(2));
    expect(result.skipReasons.join('\n'), contains('商品编号为空'));
    expect(result.skipReasons.join('\n'), contains('购买数量无效'));

    expect(result.items, hasLength(3));

    final byCode = {for (final it in result.items) it.code: it};
    // C66697：两行合并 50+20=70，元数据取首行
    final a = byCode['C66697']!;
    expect(a.qty, 70);
    expect(a.model, '4D03WGF4701T51');
    expect(a.package, '0603×4');
    expect(a.brand, 'UNI-ROYAL(厚声)'); // 品牌独立字段（v4）
    // 分类：商品分类空，靠名称 hint 猜中「电阻」
    expect(a.category, '电阻');

    // 分类列精确命中
    final c = byCode['C12345']!;
    expect(c.category, '电阻');
    expect(c.qty, 100);

    // 型号列空 → model 回退名称；品牌独立；分类靠名称猜中传感器
    final f = byCode['C88888']!;
    expect(f.model, 'DHT11 温度传感器模块');
    expect(f.category, '传感器');
    expect(f.brand, 'DHT(奥芯微)'); // 品牌进独立字段
  });

  test('categoryFromCart：精确中文 / LCSC 英文 / hint 自动分类 / 兜底', () {
    expect(categoryFromCart('电阻', ''), '电阻');
    expect(categoryFromCart('Chip Resistor - Surface Mount', ''), '电阻');
    expect(categoryFromCart('编带', 'STM32F103C8T6'), '单片机');
    expect(categoryFromCart('', ''), defaultCategory);
    expect(categoryFromCart(null, ''), defaultCategory);
    expect(categoryFromCart('编带', ''), defaultCategory);
  });

  group('仓储 importCart', () {
    late Database db;
    late ComponentRepository repo;

    setUp(() async {
      db = await AppDatabase.openAt(inMemoryDatabasePath);
      repo = ComponentRepository(db);
    });

    tearDown(() => db.close());

    Future<void> seed({
      required String cid,
      required String model,
      required String category,
      required int quantity,
      bool deleted = false,
    }) async {
      final id = await repo.insert(Component(
        cid: cid,
        model: model,
        category: category,
        quantity: quantity,
        createdAt: Component.now(),
        updatedAt: Component.now(),
      ));
      if (deleted) await repo.delete(id);
    }

    test('不存在整行入库；未删仅累加；已删恢复+累加，均不覆盖用户字段', () async {
      await seed(cid: 'C66697', model: '旧型号', category: '电阻', quantity: 10);
      await seed(cid: 'C20001', model: '已删型号', category: '其他', quantity: 5,
          deleted: true);

      final report = await repo.importCart(const [
        CartItem(
            code: 'C66697',
            model: '4D03WGF4701T51',
            category: '电阻',
            package: '0603×4',
            note: '品牌:UNI-ROYAL(厚声)',
            qty: 50),
        CartItem(
            code: 'C20001',
            model: '其他型号',
            category: '电感',
            qty: 7),
        CartItem(
            code: 'C30001',
            model: 'RC0603FR-0710KL',
            category: '电阻',
            package: '0603',
            note: '品牌:UNI-ROYAL(厚声)',
            qty: 8),
      ]);

      expect(report.inserted, 1); // C30001
      expect(report.merged, 1); // C66697
      expect(report.restored, 1); // C20001
      expect(report.total, 3);
      expect(report.touched, 3);

      // C66697：累加后 60，用户型号/分类未被购物车覆盖
      final a = (await repo.byCid('C66697')).component!;
      expect(a.quantity, 60);
      expect(a.model, '旧型号');
      expect(a.category, '电阻');
      expect(a.package, isNull);

      // C20001：恢复 + 累加 5+7=12，deleted_at 清空，型号保留
      final b = (await repo.byCid('C20001')).component!;
      expect(b.isDeleted, isFalse);
      expect(b.quantity, 12);
      expect(b.model, '已删型号');

      // C30001：整行入库含全字段
      final c = (await repo.byCid('C30001')).component!;
      expect(c.quantity, 8);
      expect(c.model, 'RC0603FR-0710KL');
      expect(c.category, '电阻');
      expect(c.package, '0603');
      expect(c.note, '品牌:UNI-ROYAL(厚声)');
    });

    test('同一 C 号在请求里重复：逐条累加而非插入冲突', () async {
      final report = await repo.importCart(const [
        CartItem(code: 'C77777', model: 'A', category: '电阻', qty: 3),
        CartItem(code: 'C77777', model: 'B', category: '电阻', qty: 4),
      ]);
      expect(report.inserted, 1);
      expect(report.merged, 1);
      final c = (await repo.byCid('C77777')).component!;
      expect(c.quantity, 7);
    });
  });
}
