# Component Manager 元件库存管理

基于 Flutter 的电子元件库存管理软件（Windows 桌面端 + Android），面向立创商城购件场景：
元件袋上有二维码（含 CID 料号与型号），扫码/手动录入库存，后续支持 BOM 表导入自动对比库存。

## 当前版本（第一阶段已完成）

- ✅ 元件列表：型号 / 分类 / 数量 / 位置 紧凑卡片展示，含库存统计栏
- ✅ 搜索：按型号、CID 模糊搜索
- ✅ 分类筛选：全部 / 电阻 / 电容 / IC / 二极管 / 三极管 / 连接器 / 晶振 / 其他
- ✅ 排序：缺货优先（数量升序）/ 最新录入（创建时间倒序）
- ✅ 手动添加 / 编辑 / 删除；CID 已存在时提示「合并数量 / 新增记录」
- ✅ 型号自动分类识别（输入型号实时推荐分类，可手动覆盖）
- ✅ 本地数据库 sqflite（Windows 端自动切换 sqflite_common_ffi 实现）

第二阶段（架构已预留）：

- ⏳ 扫码录入：`utils/qr_code_parser.dart` 二维码解析器已就绪
- ⏳ BOM 导入对比：`boms` / `bom_items` 表已建好，BOM 页面入口已挂载

## 环境要求

- Flutter SDK ≥ 3.10（Dart ≥ 3.0）
- Windows 端编译需要安装 Visual Studio「使用 C++ 的桌面开发」组件

## 快速开始

```bash
cd component_manager

# 首次运行：生成 windows / android 平台壳工程
# （flutter create 不会覆盖已存在的 lib/ 代码、pubspec.yaml 与 test/）
flutter create . --platforms=windows,android

flutter pub get
flutter run -d windows          # Windows 桌面端
flutter devices                 # 查看 Android 设备
flutter run -d <deviceId>       # Android 端
```

## 项目结构

```
lib/
├── main.dart                      # 入口：Windows 端数据库 FFI 初始化、Material 3 主题
├── models/
│   ├── component.dart             # 元件模型（components 表）
│   ├── bom.dart                   # BOM 模型（boms 表，第二阶段）
│   └── bom_item.dart              # BOM 明细模型（bom_items 表，第二阶段）
├── database/
│   └── database_helper.dart       # 数据库单例：建表 + 增删改查
├── screens/
│   ├── home_screen.dart           # 首页：列表 / 搜索 / 筛选 / 排序 / 统计
│   ├── add_component_dialog.dart  # 添加/编辑元件对话框（含 CID 合并/新增逻辑）
│   └── bom_import_screen.dart     # BOM 对比页（第二阶段占位）
├── widgets/
│   ├── component_card.dart        # 元件卡片
│   ├── component_search_bar.dart  # 搜索框
│   └── category_filter.dart       # 分类筛选下拉菜单
└── utils/
    ├── category_recognizer.dart   # 型号分类自动识别器（规则版，可扩展）
    └── qr_code_parser.dart        # 二维码内容解析器（第二阶段扫码用）
```

## 设计说明

- **CID 不设 UNIQUE 约束**：需求要求「CID 已存在时可选择合并或新增」，因此允许同一 CID
  存在多条记录（例如放在不同位置），重复检测在应用层完成（保存时弹窗询问 合并 / 新增）。
- **Windows 桌面端数据库**：sqflite 官方仅支持 Android/iOS，桌面端需 `sqflite_common_ffi`，
  已在 `main.dart` 中按平台自动初始化；数据库文件存放在系统应用支持目录。
- **分类识别**：规则按 电阻 → 电容 → IC → 二极管 → 三极管 → 连接器 → 晶振 的优先级依次匹配，
  关键词集中在 `category_recognizer.dart`，按需扩展即可。注意只对「型号」识别，勿用 CID 识别。
- **主题**：Material 3，主色蓝色系 #1565C0，紧凑视觉密度（信息密度高，适合开发者使用）。

## 常见问题

- **Windows 运行报找不到 sqlite3**：确认依赖中包含 `sqlite3_flutter_libs`（本项目已配置），
  并重新执行 `flutter pub get` 后再运行。
- **Android 端构建报 minSdkVersion 错误**：把 `android/app/build.gradle` 中的
  `minSdkVersion` 改为 21 及以上。
- **第二阶段扫码**：届时需在 `android/app/src/main/AndroidManifest.xml` 中添加 CAMERA 权限。
