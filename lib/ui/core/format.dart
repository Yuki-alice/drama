/// 字节数 → 人类可读串（1024 进制；未知量算作 0 字节）。
///
/// 下载 / 缓存 / 搬迁等场景共用同一套单位口径，避免各处自己拼导致
/// 「下载页 MB、设置页 MiB」这种不一致。读屏能念出单位，不是一串裸数字。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // 整数单位（B）不留小数，其余保留一位：精度与可读性的折中点。
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// 字节/秒 → 速率串（例如 `1.2 MB/s`）；无速率时返回空串，让调用方省略这一段。
@pragma('vm:prefer-inline')
String formatSpeed(int bytesPerSecond) =>
    bytesPerSecond > 0 ? '${formatBytes(bytesPerSecond)}/s' : '';
