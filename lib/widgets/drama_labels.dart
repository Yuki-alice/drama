/// 剧集状态的展示文案，与领域模型解耦。
String releaseLabelOf(String releaseStatus) => switch (releaseStatus) {
  'finished' || 'completed' => '已完结',
  'ongoing' => '连载中',
  _ => '状态未知',
};
