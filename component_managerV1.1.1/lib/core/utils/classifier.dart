import '../config/constants.dart';

/// 根据型号关键字自动分类（纯 Dart，可单测）。
/// 返回值必须 ∈ [inventoryCategories]（有单测断言）。
/// 先跑特异性前置规则，再按优先级走主规则表，解决原始表格的排序冲突
/// （例如泛化的 IC 关键字 'U'/'STM' 放在 '单片机' 名牌 STM32 之前，会导致
/// STM32F103 被误判为 IC）。
String classify(String model) {
  final s = model.trim().toLowerCase();
  if (s.isEmpty) return defaultCategory;

  // ---- 前置 pass（特异性品牌/接口，优先于宽泛 IC）----
  if (_any(s, ['stm32', 'esp32', 'esp8266', 'atmega', 'pic', 'mcu'])) {
    return '单片机';
  }
  if (_any(s, ['rs232', 'rs485', 'can', 'max232', 'ch340', 'ftdi', 'uart'])) {
    return '接口芯片';
  }
  if (_any(s, ['dht', 'hc-sr', 'mpu', 'bmp', '超声波', 'sensor'])) {
    return '传感器';
  }

  // ---- 主规则（具体优先于泛化）----
  if (_any(s, ['led', '发光', 'rgb'])) return 'LED';
  // 电容先于电阻：'CL-0805-10uF' 这类型号必须归电容，不能被电阻的
  // '0805 封装编号' 启发抢走。电阻的封装编号启发只对非电容字样生效。
  if (_isCapacitor(s)) return '电容';
  if (_isResistor(s)) return '电阻';
  if (_any(s, ['ldo', 'buck', 'boost', 'tps', 'xl', 'mp', '电源'])) {
    return '电源管理';
  }
  if (_any(s, ['op', '运放', 'lm358', 'lm324', 'ne5532'])) return '放大器';
  if (_any(s, ['comparator', 'lm393', 'lm311'])) return '比较器';
  if (_any(s, ['74hc', '74ls', 'cd40', 'hef'])) return '逻辑门';
  if (_any(s, ['flash', 'eeprom', 'at24', 'w25q', 'sd', 'microsd'])) {
    return '存储器';
  }
  if (_any(s, ['rs232', 'rs485', 'can', 'ch340', 'ftdi', 'uart', 'max232'])) {
    return '接口芯片';
  }
  if (_any(s, ['usb', 'type-c', 'type c'])) {
    return _any(s, ['排针', '排母', 'header', '杜邦', 'xh', 'ph', 'zh', '连接器'])
        ? '连接器'
        : '接口芯片';
  }
  if (_any(s, ['pc', 'el', '光耦', 'optocoupler', 'tlp'])) return '光耦';
  if (_any(s, ['1n', 'ss', 'bat', '肖特基', '稳压', 'tvs', 'diode', '二极管'])) {
    return '二极管';
  }
  if (_any(s, ['s8050', 's8550', 'bc547', '2n', 'triode', '三极管'])) {
    return '三极管';
  }
  if (_any(s, ['mosfet', 'irf', 'aod', 'si', 'n沟道', 'p沟道'])) return '场效应管';
  if (_any(s, ['igbt', 'fga', 'g4pc'])) return 'IGBT';
  if (_any(s, ['relay', 'srd', 'hk', 'g5', '继电器'])) return '继电器';
  if (_any(s, ['transformer', '变压器', '电感耦合'])) return '变压器';
  if (_any(s, ['l_', 'inductor', '电感', '绕线'])) return '电感';
  if (_any(s, ['fuse', 'f_', '保险丝'])) return '保险丝';
  if (_any(s, ['button', 'switch', '按键', '开关', '轻触'])) return '按键开关';
  if (_any(s, ['battery', 'bt', 'cr', '锂电', '纽扣'])) return '电池';
  if (_any(s, ['连接器', 'header', '排针', '排母', '杜邦', 'xh', 'ph', 'zh', 'conn'])) {
    return _any(s, ['排针', '排母', 'pin header', 'female header'])
        ? '排针排母'
        : '连接器';
  }
  if (_any(s, ['x_', 'crystal', '晶振', '振荡器', 'mhz', 'khz'])) return '晶振';

  // ---- 泛化 IC 关键字放到最末尾，保证前面具体分类优先 ----
  if (_any(s, ['ic', '芯片', 'lm', 'max']) || _isSingleU(s)) return 'IC';

  return defaultCategory;
}

bool _any(String s, List<String> keys) => keys.any(s.contains);

bool _isCapacitor(String s) {
  if (_any(s, ['c_', 'cl_', 'capacitor', 'μf', 'uf', 'pf', 'nf', '电解'])) {
    return true;
  }
  // 以 C 开头 + 封装编号（如 C0805、C1206）也是电容
  if (RegExp(r'^c\d{4}').hasMatch(s) ) return true;
  return false;
}

bool _isResistor(String s) {
  if (_any(s, ['r_', 'rc_', 'resistor', '电阻'])) return true;
  // 含 'R' + 数字 + 'K'/'M'，如 rc0603fr-0710kl、r100k
  if (RegExp(r'(^|\D)r\d+\w*[km](\D|$)').hasMatch(s)) return true;
  // 封装编号 0603/0805/1206 + 数字（排除明显电容字样，交给 _isCapacitor）
  if (_any(s, ['0603', '0805', '1206', '2512', '0402']) &&
      !_any(s, ['uf', 'pf', 'nf', '电解'])) {
    return true;
  }
  return false;
}

bool _isSingleU(String s) {
  // 'U1'、'U_' 这样的位号前缀，单独出现且不是其它已知前缀
  return RegExp(r'(^|[^a-z])u[0-9_]').hasMatch(s);
}