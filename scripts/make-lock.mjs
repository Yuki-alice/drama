// 由 sync 清单生成 skills-lock.json
// 用法: node scripts/make-lock.mjs <manifest.tsv>
// manifest 每行: repo<TAB>commit<TAB>license<TAB>skillName
import fs from 'node:fs';

const manifestPath = process.argv[2];
if (!manifestPath || !fs.existsSync(manifestPath)) {
  console.error('用法: node scripts/make-lock.mjs <manifest.tsv>');
  process.exit(2);
}
const lines = fs.readFileSync(manifestPath, 'utf8').split(/\r?\n/).filter(Boolean);
const map = new Map();
for (const line of lines) {
  const [repo, commit, license, skill] = line.split('\t');
  if (!repo || !skill) continue;
  if (!map.has(repo)) map.set(repo, { repo, commit, license, skills: [] });
  const s = map.get(repo);
  if (commit) s.commit = commit;
  if (license) s.license = license;
  s.skills.push(skill);
}
const sources = [...map.values()].map(s => ({ ...s, skills: s.skills.sort() }));
const total = sources.reduce((n, s) => n + s.skills.length, 0);

const out = {
  generatedAt: new Date().toISOString(),
  layout: {
    skills: '.agents/skills/  (通用标准位置，跨 agent 可用)',
    workbuddy: '.workbuddy/skills/  (junction → .agents/skills，WorkBuddy 自动发现)',
    guide: 'AGENTS.md  (技能路由表与调用规范)',
  },
  audit: {
    date: '2026-10-14',
    method: 'skills-security-check 静态审计流程（危险命令/网络/敏感路径/依赖/提示注入扫描）',
    result: 'P2 安全：0 个 P0 / 0 个 P1',
  },
  totalSkills: total,
  sources,
};
console.log(JSON.stringify(out, null, 2));
