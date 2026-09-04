# 电子元件管家（Component Manager）

基于 Flutter 的电子元件库存管理软件（**Windows 桌面端 + Android**），面向立创商城购件场景：
元件袋二维码含 CID 料号与型号，扫码/手动录入库存，BOM 表导入自动对比库存并生成缺料采购清单，
手机与电脑在同一局域网内可互相同步库存。

当前版本 **v1.1.1**（开源正式版）。

修复了手机无法保存表格文件的问题


## 功能一览

### 库存管理
- 元件列表：型号 / 分类 / 数量 / 位置 紧凑卡片，含库存统计栏（种类 / 总数 / 缺货数）
- 搜索（型号、CID 模糊）+ 分类筛选 + 分类管理（自定义分类增删改）
- 排序：缺货优先 / 最新录入；型号自动归类识别
- 手动添加 / 编辑 / 删除（软删除回收站）；CID 重复时可选「合并数量 / 新增记录」
- 立创商城资料查询：按 C 号抓取商品页参数（数据源为国际站页面解析，改版可能失效）

### 扫码入库
- `mobile_scanner` 摄像头扫描元件袋二维码，解析出 CID / 型号 / 数量 / 封装
- 无摄像头时可「从剪贴板粘贴二维码内容」

### BOM 库存对比
- 导入 CSV / XLSX BOM：表头自动识别 + 列映射手动调整
- 逐行三态对比：库存充足 / 缺货（差多少）/ 待采购（无库存命中）
- 导出 **BOM 对比报告（TXT）** 与 **缺料采购清单（CSV，UTF-8 BOM 防中文乱码）**
- 缺料替代推荐：本地库存离线粗筛 + AI 推荐（电气参数对比页、批量替代）

### 立创购物车导入
- 导入立创商城购物车导出文件（CSV / XLSX），按 **C 号** 为唯一键：
  新行入库、已有行仅累加数量、自动恢复回收站同名记录
- 可选 AI 把购物车「名称」整表规范成标准厂商型号并补品牌

### 局域网同步
- 一端开启同步服务（本机 `HttpServer`），另一端 UDP 广播自动发现
- 按 token 鉴权，`ustamp` 逻辑时钟做增量合并，冲突逐条人工裁决
- 数据不出局域网

### 数据安全
- 全量备份 / 恢复：JSON 文件导出导入（含软删元件与 BOM）
- 文件保存 / 选择均走系统对话框（Windows 原生保存框；Android SAF 另存为）

## 环境要求

- Flutter SDK ≥ 3.13（Dart ≥ 3.0）
- Windows 端编译需 Visual Studio「使用 C++ 的桌面开发」组件
- Android 端构建需 Android SDK

## 快速开始

```bash
cd component_manager

# 首次运行：生成/补齐 windows / android 平台壳工程
# （flutter create 不会覆盖已存在的 lib/ 代码、pubspec.yaml 与 test/）
flutter create . --platforms=windows,android

flutter pub get
flutter analyze
flutter test              # 40 个测试文件，290+ 用例

flutter run -d windows         # Windows 桌面端
flutter build apk --release    # Android 安装包
```

### Release 签名

复制 `android/key.properties.example` 为 `android/key.properties` 并填入你自己的
keystore 信息；没有该文件时 release 构建回退 debug 签名（可安装、非发布签名）。
`key.properties` 与 `*.jks` 已在 `.gitignore` 中，切勿入库。

## 项目结构

```
lib/
├── main.dart                      # 入口：桌面端数据库 FFI 初始化、全局 AppState、主题
├── core/
│   ├── config/constants.dart      # 分类集合、同步端口/token 等常量
│   ├── database/                  # 建库与版本迁移（app_database / migration）
│   ├── services/                  # 仓储与跨平台服务：
│   │   ├── component_repository / bom_repository       # 库存与 BOM 增删改查
│   │   ├── import_parser / cart_parser / bom_compare   # 文件解析与对比（纯逻辑可单测）
│   │   ├── export_service         # 报告/清单文本构建 + 跨平台落盘（桌面保存框 / Android SAF）
│   │   ├── ai_client / ai_substitute_batch             # OpenAI 兼容接口（可选，用户自备）
│   │   ├── lcsc_lookup            # 立创国际站商品页参数抓取
│   │   ├── sync_service / merge_engine / sync_codec    # 局域网同步（HTTP + 增量合并）
│   │   ├── lan_discovery          # UDP 广播发现
│   │   └── settings_store         # 本地设置（主题、AI、同步主机记忆）
│   └── utils/                     # 分类器、二维码解析、型号分组、CID 模糊匹配等
├── models/                        # Component / Bom / BomItem / ScanResult
├── screens/                       # 首页、分类、扫码、BOM 导入对比、购物车导入、
│   │                              # 替代对比、同步、设置等页面
├── widgets/                       # 卡片、搜索框、数量徽章、冲突条目等
└── database/ utils/               # 第一阶段兼容层
```

## 设计说明

- **sqflite 双实现**：Android 用官方 sqflite；Windows 桌面端在 `main.dart` 中
  自动切换 `sqflite_common_ffi`，数据库文件放在应用支持目录。
- **CID 不设 UNIQUE**：允许同一 C 号多条记录（不同位置），重复检测在应用层完成。
- **文件选择跨平台**：`pickImportFile()` 桌面保留扩展名过滤；Android 放开为全部文件
  （系统选择器按 MIME 过滤会隐藏微信/QQ 等渠道收到的错误 MIME 文件），由解析端校验格式。
- **AI 功能全部可选**：不配置接口则 AI 入口自动禁用或降级为本地逻辑，
  核心库存与 BOM 功能完全离线可用。
- **隐私边界**：数据仅存本机 SQLite；局域网同步限于同一内网并带 token 鉴权；
  立创查询与 AI 调用仅按需发起，无任何遥测上报。
- **纯逻辑层可单测**：解析、对比、分类、合并、备份均为无 UI 依赖函数，集中在 `core/`。

## 常见问题

- **Windows 运行报找不到 sqlite3**：确认依赖含 `sqflite_common_ffi` +
  `sqlite3_flutter_libs`（本项目已配置），`flutter pub get` 后重新运行。
- **Android 构建报 minSdkVersion**：`android/app/build.gradle.kts` 中调 `minSdk`。
- **手机端导出报告/选不到购物车文件**：v1.1.0 及以前 Android 保存走应用私有目录、
  文件选择按 MIME 过滤导致；v1.1.1 已改为系统「另存为」+ 放开选择过滤。

## 许可

本项目为个人开源，欢迎在此基础上修改使用。立创商城、LCSC 为其各自所有者商标；
本软件与之无隶属关系，商品参数抓取仅用于个人库存管理场景。
