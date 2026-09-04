/// 扫码解析结果。
///
/// [cid]/[model]/[qty] 解析失败时可为 null；UI 层按需求兜底：\n/// qty 缺省时默认 1，cid 缺省时可让用户手动补填。
library;

class ScannedQr {
  final String? cid;
  final String? model;
  final int? qty;

  const ScannedQr({this.cid, this.model, this.qty});
}