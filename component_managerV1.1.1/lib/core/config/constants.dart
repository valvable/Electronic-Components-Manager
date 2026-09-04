/// 全局常量与分类表
///
/// 分类表：'全部' 仅作筛选哨兵，不存库。存储分类共 29 个。
/// classifier 的返回值必须 ∈ [inventoryCategories]（有单测断言）。
library;

/// 存储分类完整列表（含 USB、Type-C 两个独立类别）。
const List<String> inventoryCategories = [
  '电阻', '电容', 'IC', '二极管', '三极管', '场效应管', 'IGBT', '晶振',
  '连接器', '排针排母', 'USB', 'Type-C', 'LED', '光耦', '继电器',
  '变压器', '电感', '保险丝', '按键开关', '电池', '传感器', '存储器',
  '单片机', '电源管理', '放大器', '比较器', '逻辑门', '接口芯片', '其他',
];

/// 手动添加 / 扫码默认分类。
const String defaultCategory = '其他';

/// 默认数量（扫码、手动添加时）。
const int defaultQuantity = 1;

/// 局域网同步默认端口。
const int syncPort = 8321;

/// 局域网同步 UDP 自动发现端口（主机周期广播 + 客户端探测均用此端口）。
const int syncDiscoveryPort = 8322;

/// 广播地址（仅 IPv4 局域网）。
const String syncDiscoveryBroadcast = '255.255.255.255';

/// 数据库 schema 版本号（onCreate 建 v1；v2 起逐级 onUpgrade）。
/// v4：components 加 brand（品牌）列——同型号不同品牌分组展示的地基。
const int migrationVersion = 4;

/// 同步冲突判定窗口（两台设备 updated_at 差在此范围内且互不包含 → 判冲突）。
const int syncConflictWindowSeconds = 300; // 5 分钟

/// 同步协议版本（/manifest 协商用，不一致则提示升级）。
const int syncProtocolVersion = 1;

/// 同步 schema 名称（/manifest 协商，确认对方是同款应用而非其它服务）。
const String syncSchemaName = 'component_manager';

/// 默认同步令牌。明文局域网传输、弱校验，仅限可信网络（设置页可改）。
const String defaultSyncToken = 'cmp-sync-8321';

/// 单次 AI 请求总超时（秒）：连接 + 等待响应整体上限。超时抛
/// [AiTimeoutException]，UI 提示中止——避免服务端不回包时界面永久转圈。
const int aiRequestTimeoutSeconds = 90;