import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../../models/component.dart';
import '../utils/fuzzy.dart';
import 'cart_parser.dart';

/// 按 [cid] 查询元件的三态判定结果（用户审查 #2）：区分 可插入 / 存在未删 / 存在已删。
enum LookupStatus { notFound, active, deleted }

class ComponentLookup {
  final LookupStatus status;
  final Component? component;
  const ComponentLookup(this.status, [this.component]);
}

/// LIKE 特殊字符转义：`%`→`\%`、`_`→`\_`、`\`→`\\`（用户审查 #4）。
/// 与 SQL 里 `ESCAPE '\'` 配合使用。
String _escapeLike(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll('%', r'\%')
    .replaceAll('_', r'\_');

/// 生成「无 C 号手录元件」的内部隐藏编号（存进 cid 列作身份/同步合并键）。
/// 形如 `local_时间戳_随机`，绝不形如 C+数字，与真实立创 C 号互不冲突；
/// UI 一律不展示该编号。
String newInternalCid() {
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = math.Random().nextInt(0xFFFFFF).toRadixString(36);
  return 'local_${stamp}_$rand';
}

/// 元件仓储：CRUD + 软删 + 模糊搜索 + insertOrAddQty。
///
/// 所有写操作刷新 [Component.updatedAt]（同步 LWW 键）。
/// [recent] 语义：updated_at 降序返回前 N 条未删除（默认 100）。
/// 分类筛选的'全部'哨兵在本层被忽略。
class ComponentRepository {
  final Database db;
  ComponentRepository(this.db);

  /// 查询全部：category 为 null 或 '全部' 时不过滤（审查 #6）；不含已删；sort ∈
  /// {qty_asc, qty_desc, created_desc}（created_desc 最新在前）。
  Future<List<Component>> all({
    String? category,
    String sort = 'created_desc',
    bool includeDeleted = false,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) where.add('deleted_at IS NULL');
    if (category != null && category.isNotEmpty && category != '全部') {
      where.add('category = ?');
      args.add(category);
    }
    final orderBy = switch (sort) {
      'qty_asc' => 'quantity ASC, id DESC',
      'qty_desc' => 'quantity DESC, id DESC',
      // 最新在前；同秒创建的用 id DESC 稳定断并列（审查#5：排序确定性）
      _ => 'created_at DESC, id DESC',
    };
    final rows = await db.query(
      'components',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: orderBy,
    );
    return rows.map(Component.fromMap).toList();
  }

  /// 三态按 CID 查询：notFound / active / deleted。
  Future<ComponentLookup> byCid(String cid) async {
    final rows = await db.query(
      'components',
      where: 'cid = ?',
      whereArgs: [cid],
      limit: 1,
    );
    if (rows.isEmpty) return const ComponentLookup(LookupStatus.notFound);
    final c = Component.fromMap(rows.first);
    return ComponentLookup(c.isDeleted ? LookupStatus.deleted : LookupStatus.active, c);
  }

  /// 插入新元件。返回自增 id。重复 cid 由 UNIQUE 约束抛异常。
  /// cid 留空（无 C 号手录元件）时自动生成内部隐藏编号落库。
  Future<int> insert(Component c) async {
    final now = Component.now();
    final cid = c.cid.trim().isEmpty ? newInternalCid() : c.cid;
    final map = c.copyWith(cid: cid).toMap()
      ..remove('id')
      ..['created_at'] = now
      ..['updated_at'] = now;
    return db.insert('components', map, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// 按 id 更新（保留 created_at，刷新 updated_at）。
  Future<int> update(Component c) async {
    final map = c.toMap()
      ..remove('id')
      ..remove('created_at')
      ..['updated_at'] = Component.now();
    return db.update('components', map, where: 'id = ?', whereArgs: [c.id]);
  }

  /// 软删除：置 deleted_at = now 并刷新 updated_at（墓碑，随同步传播）。
  Future<int> delete(int id) async {
    final now = Component.now();
    return db.update(
      'components',
      {'deleted_at': now, 'updated_at': now},
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
  }

  /// 恢复软删。
  Future<int> restore(int id) async {
    final now = Component.now();
    return db.update(
      'components',
      {'deleted_at': null, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 彻底删除（回收站清除）。双保险（审查 #10）：先主动检查 BOM 引用给友好
  /// 提示；DELETE 触发 RESTRICT 抛 DatabaseException 时也转同一业务异常。
  Future<void> purge(int id) async {
    final refs = await db.query(
      'bom_items',
      columns: ['id'],
      where: 'component_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (refs.isNotEmpty) {
      throw ComponentDeletionException(
          '该元件已被 BOM 引用，请先从 BOM 中移除再彻底删除');
    }
    try {
      await db.delete('components', where: 'id = ?', whereArgs: [id]);
    } on DatabaseException catch (e) {
      if (e.toString().contains('FOREIGN KEY')) {
        throw ComponentDeletionException(
            '该元件已被 BOM 引用，请先从 BOM 中移除再彻底删除');
      }
      rethrow;
    }
  }

  /// 扫码累加（事务，审查 #8）：已删则恢复并加量 / 未删则加量 / 不存在则 INSERT。
  /// 返回操作后（恢复前语义见注释）的元件。写操作刷新 updated_at。
  Future<Component> insertOrAddQty(String cid, {required int add}) async {
    final now = Component.now();
    return db.transaction((txn) async {
      final rows = await txn.query(
        'components',
        where: 'cid = ?',
        whereArgs: [cid],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final c = Component.fromMap(rows.first);
        final newQty = math.max(0, c.quantity + add);
        final fields = <String, Object?>{
          'quantity': newQty,
          'updated_at': now,
          if (c.isDeleted) 'deleted_at': null, // 自动恢复
        };
        await txn.update('components', fields, where: 'id = ?', whereArgs: [c.id]);
        return c.copyWith(
          quantity: newQty,
          updatedAt: now,
          clearDeleted: true,
        );
      }
      // 不存在 → INSERT
      final map = <String, Object?>{
        'cid': cid,
        'model': cid,
        'category': '其他',
        'quantity': math.max(0, add),
        'created_at': now,
        'updated_at': now,
      };
      final id = await txn.insert('components', map);
      return Component.fromMap(map..['id'] = id);
    });
  }

  /// 查询某 cid 的首行（事务内共用）。
  Future<Map<String, Object?>?> _rowByCid(
      DatabaseExecutor e, String cid) async {
    final rows = await e.query(
      'components',
      where: 'cid = ?',
      whereArgs: [cid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 把无 C 号元件（[sourceCid] 为内部编号）的数量并入真实 C 号元件（[targetCid]）。
  /// 单事务：目标数量相加并刷新 updated_at，源条目**软删**进回收站（墓碑随局域网
  /// 同步传播）。源/目标非法或同料抛 [StateError]。合并全程人工（详情页入口）。
  Future<void> mergeToReal({
    required String sourceCid,
    required String targetCid,
  }) async {
    if (sourceCid == targetCid) {
      throw StateError('不能把元件并入它自身');
    }
    final now = Component.now();
    await db.transaction((txn) async {
      final src = await _rowByCid(txn, sourceCid);
      if (src == null || src['deleted_at'] != null) {
        throw StateError('源元件不存在或已在回收站');
      }
      final tgt = await _rowByCid(txn, targetCid);
      if (tgt == null || tgt['deleted_at'] != null) {
        throw StateError('目标元件不存在或已在回收站');
      }
      final addQty = (src['quantity'] as int?) ?? 0;
      final oldQty = (tgt['quantity'] as int?) ?? 0;
      await txn.update(
        'components',
        {'quantity': math.max(0, oldQty + addQty), 'updated_at': now},
        where: 'id = ?',
        whereArgs: [tgt['id']],
      );
      await txn.update(
        'components',
        {'deleted_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [src['id']],
      );
    });
  }

  /// 把无 C 号元件 [sourceCid] 正式绑定为立创 C 号 [newRealCid]（库存还没有该料时
  /// 的「认领」路径）。事务内校验新 C 号未被占用（含回收站），占用抛 [StateError]。
  Future<void> attachRealCid(String sourceCid, String newRealCid) async {
    final now = Component.now();
    await db.transaction((txn) async {
      final src = await _rowByCid(txn, sourceCid);
      if (src == null || src['deleted_at'] != null) {
        throw StateError('源元件不存在或已在回收站');
      }
      final taken = await _rowByCid(txn, newRealCid);
      if (taken != null) {
        throw StateError(
            '该 C 号已被「${taken['model']}」占用，请改用「合并数量」');
      }
      await txn.update(
        'components',
        {'cid': newRealCid, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [src['id']],
      );
    });
  }

  /// 购物车批量入库（单事务，审查：不可中断到半途）。
  ///
  /// 以 C 号唯一匹配（与扫码同语义，见 [insertOrAddQty]）：
  /// - 不存在 → 整行入库（含型号/分类/封装/note，来源购物车）；
  /// - 存在未删 → 仅累加数量，**不覆盖**用户已维护的型号/分类等字段；
  /// - 存在已删 → 恢复（清 deleted_at）+ 累加数量。
  /// 所有写操作刷新 updated_at（同步 LWW 键）。
  Future<CartImportReport> importCart(List<CartItem> items) async {
    final now = Component.now();
    var inserted = 0, merged = 0, restored = 0;
    await db.transaction((txn) async {
      for (final it in items) {
        final rows = await txn.query(
          'components',
          columns: ['id', 'quantity', 'deleted_at', 'brand'],
          where: 'cid = ?',
          whereArgs: [it.code],
          limit: 1,
        );
        if (rows.isEmpty) {
          final map = <String, Object?>{
            'cid': it.code,
            'model': it.model,
            'category': it.category,
            'package': it.package,
            'brand': it.brand,
            'quantity': math.max(0, it.qty),
            'note': it.note,
            'created_at': now,
            'updated_at': now,
          };
          await txn.insert('components', map);
          inserted++;
        } else {
          final existed = rows.first;
          final wasDeleted = existed['deleted_at'] != null;
          final oldQty = (existed['quantity'] as int?) ?? 0;
          // 老行缺品牌时回填（绝不覆盖用户已维护的品牌）。
          final hadBrand = (existed['brand'] as String?)?.trim().isNotEmpty == true;
          await txn.update(
            'components',
            {
              'quantity': math.max(0, oldQty + it.qty),
              'updated_at': now,
              if (wasDeleted) 'deleted_at': null,
              if (it.brand != null && !hadBrand) 'brand': it.brand,
            },
            where: 'id = ?',
            whereArgs: [existed['id']],
          );
          wasDeleted ? restored++ : merged++;
        }
      }
    });
    return CartImportReport(
      inserted: inserted,
      merged: merged,
      restored: restored,
      total: items.length,
    );
  }

  /// 模糊搜索：SQL LIKE 候选池（特殊字符转义 + ESCAPE）→ 内存 Levenshtein 排序，
  /// 按 min(型号距离, cid 距离) 取前 [limit] 条。
  Future<List<Component>> search(String query,
      {String? category, int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return all(category: category);
    final like = '%${_escapeLike(q)}%';
    final isCid = RegExp(r'^C\d+$').hasMatch(q);
    final where = <String>[];
    final params = <Object?>[];
    where.add(isCid ? 'cid LIKE ? ESCAPE \'\\\'' : '(model LIKE ? ESCAPE \'\\\' OR cid LIKE ? ESCAPE \'\\\')');
    params.addAll(isCid ? [like] : [like, like]);
    if (category != null && category.isNotEmpty && category != '全部') {
      where.add('category = ?');
      params.add(category);
    }
    final rows = await db.query(
      'components',
      where: where.join(' AND '),
      whereArgs: params,
    );
    final candidates = rows.map(Component.fromMap).toList();
    candidates.sort((a, b) {
      final ql = q.toLowerCase();
      final sa = similarityScore(a.model.toLowerCase(), a.cid.toLowerCase(), ql);
      final sb = similarityScore(b.model.toLowerCase(), b.cid.toLowerCase(), ql);
      return sa != sb ? sa.compareTo(sb) : b.updatedAt.compareTo(a.updatedAt);
    });
    return candidates.take(limit).toList();
  }

  /// 最近修改：updated_at 降序前 N 条未删除（默认 100）。
  Future<List<Component>> recent({int limit = 100}) async {
    final rows = await db.query(
      'components',
      where: 'deleted_at IS NULL',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Component.fromMap).toList();
  }

  /// 各分类数量统计（不含已删）。
  Future<Map<String, int>> countByCategory() async {
    final rows = await db.rawQuery(
        'SELECT category, COUNT(*) c FROM components WHERE deleted_at IS NULL GROUP BY category');
    return {for (final r in rows) r['category'] as String: (r['c'] as int)};
  }

  /// 分类改名：仅更新活动行（deleted_at IS NULL）——不碰软删墓碑的时间戳，
  /// 避免影响局域网同步的 LWW 语义。返回受影响行数。
  Future<int> renameCategory(String from, String to) async {
    if (from == to) return 0;
    final now = Component.now();
    return db.update(
      'components',
      {'category': to, 'updated_at': now},
      where: 'category = ? AND deleted_at IS NULL',
      whereArgs: [from],
    );
  }

  /// 同步落库：按 cid 整体覆盖（含墓碑/时间戳/库存），不存在则插入。
  /// 专供局域网同步：保留合并结果里的 created_at/updated_at/deleted_at，
  /// 不刷新本机 now()——否则每台设备各自刷新会破坏 LWW 一致性。
  Future<void> syncUpsert(Component c) async {
    final rows = await db.query(
      'components',
      where: 'cid = ?',
      whereArgs: [c.cid],
      limit: 1,
    );
    final map = c.toMap()..remove('id');
    if (rows.isEmpty) {
      await db.insert('components', map, conflictAlgorithm: ConflictAlgorithm.abort);
      return;
    }
    // created_at 保留最早（首次创建时间）；其余字段按合并结果覆盖。
    final existing = Component.fromMap(rows.first);
    map['created_at'] = math.min(existing.createdAt, c.createdAt);
    await db.update('components', map, where: 'cid = ?', whereArgs: [c.cid]);
  }

  /// 数量低于 [threshold] 的未删元件（采购清单来源），按数量升序。
  Future<List<Component>> quantitiesBelow(int threshold) async {
    final rows = await db.query(
      'components',
      where: 'deleted_at IS NULL AND quantity < ?',
      whereArgs: [threshold],
      orderBy: 'quantity ASC',
    );
    return rows.map(Component.fromMap).toList();
  }

  /// BOM 比对按结果扣库存：单事务对每个 id 扣减指定数量（下限 0），
  /// 刷新 updated_at 参与同步 LWW；已删/不存在/扣无可扣的行跳过。
  /// 返回实际发生扣减的行数（供 UI 提示）。
  Future<int> deductForBom(Map<int, int> deductByComponentId) async {
    if (deductByComponentId.isEmpty) return 0;
    final now = Component.now();
    var changed = 0;
    await db.transaction((txn) async {
      for (final e in deductByComponentId.entries) {
        if (e.value <= 0) continue;
        final rows = await txn.query(
          'components',
          columns: ['quantity'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [e.key],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final qty = (rows.first['quantity'] as int?) ?? 0;
        final next = math.max(0, qty - e.value);
        if (next == qty) continue;
        await txn.update(
          'components',
          {'quantity': next, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [e.key],
        );
        changed++;
      }
    });
    return changed;
  }
}

/// 元件彻底删除被 BOM 引用时的业务异常。
class ComponentDeletionException implements Exception {
  final String message;
  const ComponentDeletionException(this.message);
  @override
  String toString() => message;
}

/// 购物车批量入库报告：各类命中行数（供导入页结果提示）。
class CartImportReport {
  final int inserted; // 全新入库
  final int merged; // 已存在未删 → 累加数量
  final int restored; // 已存在已删 → 恢复 + 累加
  final int total; // 请求行数（解析后有效行）

  const CartImportReport({
    required this.inserted,
    required this.merged,
    required this.restored,
    required this.total,
  });

  int get touched => inserted + merged + restored;
}