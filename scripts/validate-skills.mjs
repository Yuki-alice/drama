#!/usr/bin/env node
// 校验 .agents/skills/ 下每个技能的完整性：
//   1. 存在 SKILL.md
//   2. frontmatter 有 name 和 description
//   3. 目录名与 frontmatter name 一致（仅警告）
// 用法: node scripts/validate-skills.mjs
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] || '.agents/skills');
const dirs = fs.readdirSync(root, { withFileTypes: true })
  .filter(d => d.isDirectory() || d.isSymbolicLink())
  .map(d => d.name)
  .sort();

let ok = 0;
const problems = [];
const warnings = [];

for (const d of dirs) {
  const f = path.join(root, d, 'SKILL.md');
  if (!fs.existsSync(f)) { problems.push(`${d} -> 缺少 SKILL.md`); continue; }
  const txt = fs.readFileSync(f, 'utf8');
  const m = txt.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) { problems.push(`${d} -> 无 YAML frontmatter`); continue; }
  const fm = m[1];
  const name = (fm.match(/^name:\s*(.+)$/m) || [])[1];
  const hasDesc = /^description:/m.test(fm);
  if (!name || !hasDesc) { problems.push(`${d} -> name=${name || '缺失'} / description=${hasDesc ? '有' : '缺失'}`); continue; }
  if (name.trim() !== d) warnings.push(`${d} -> frontmatter name 为 "${name.trim()}"`);
  ok++;
}

console.log(`技能目录: ${dirs.length}`);
console.log(`frontmatter 完整: ${ok}`);
if (warnings.length) {
  console.log(`\n名称不一致（仅警告，不影响使用）:`);
  warnings.forEach(w => console.log(`  ${w}`));
}
if (problems.length) {
  console.log(`\n❌ 问题项:`);
  problems.forEach(p => console.log(`  ${p}`));
  process.exit(1);
} else {
  console.log('\n✅ 全部通过');
}
