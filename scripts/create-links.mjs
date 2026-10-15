// 为 .agents/skills 下每个技能在目标目录创建链接（Windows: junction / Linux: symlink）
// 用法: node scripts/create-links.mjs .workbuddy/skills
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const src = path.join(root, '.agents', 'skills');
const rel = process.argv[2];
if (!rel) {
  console.error('用法: node scripts/create-links.mjs <目标目录，如 .workbuddy/skills>');
  process.exit(2);
}
if (!fs.existsSync(src)) {
  console.error('未找到 .agents/skills，请先运行 scripts/sync-skills.sh');
  process.exit(2);
}
const dst = path.join(root, rel);
fs.mkdirSync(dst, { recursive: true });

const type = process.platform === 'win32' ? 'junction' : 'dir';
let linked = 0, skipped = 0, failed = 0;

for (const name of fs.readdirSync(src)) {
  const t = path.join(src, name);
  const l = path.join(dst, name);
  try {
    const st = fs.lstatSync(l);
    if (st.isSymbolicLink()) {
      try { fs.rmdirSync(l); } catch { try { fs.unlinkSync(l); } catch {} }
    } else {
      console.log('SKIP (真实目录已存在，不覆盖):', name);
      skipped++;
      continue;
    }
  } catch { /* 不存在，直接创建 */ }
  try {
    fs.symlinkSync(t, l, type);
    linked++;
  } catch (e) {
    console.error('创建失败:', name, e.message);
    failed++;
  }
}
console.log(`链接已更新: ${rel} → .agents/skills  [${type}]  新建 ${linked} / 跳过 ${skipped} / 失败 ${failed}`);
if (failed > 0) process.exit(1);
