// 把《高性价比人生指南》的 34 个正文 md 解析成 items.json，再生成嵌进 appex 的 Swift 常量。
//
//   1. ./tools/embed.mjs book/          —— 从指定书籍目录解析
//   2. ./tools/embed.mjs                —— 用仓库里 book/ 的快照
//
// 正文格式（每条）：
//   ### <节号>.<条号> <标题>
//   <!-- 成本标签: 钱=0 时间=少 毅力=否 收益=大 口径=死亡率 -->
//   - 成本：…
//   - 说人话：…
//   - 收益：…
//   - 证据等级：A
//   - 来源：…
//   - 备注：…            （可选）
//
// 只做提取和规整，不改一个字。

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const bookDir = process.argv[2] ? resolve(process.argv[2]) : resolve(ROOT, 'book');

// MARK: 解析

/// 从 <!-- 成本标签: 钱=0 时间=少 ... --> 里取出键值对。
function parseTags(comment) {
  const out = {};
  for (const part of comment.replace(/^成本标签[:：]\s*/, '').split(/\s+/)) {
    const m = part.match(/^([^=]+)=(.+)$/);
    if (m) out[m[1].trim()] = m[2].trim();
  }
  return out;
}

/// 章节文件名 01-不要早死.md → { num: 1, title: '不要早死' }
function parseChapterFile(name) {
  const m = basename(name, '.md').match(/^(\d+)-(.+)$/);
  if (!m) return null;
  return { num: Number(m[1]), title: m[2] };
}

function parseBook(dir) {
  const files = readdirSync(dir)
    .filter(f => f.endsWith('.md'))
    .filter(f => parseChapterFile(f))
    .sort((a, b) => parseChapterFile(a).num - parseChapterFile(b).num);

  const items = [];
  const problems = [];

  for (const file of files) {
    const chapter = parseChapterFile(file);
    const text = readFileSync(resolve(dir, file), 'utf8').replace(/\r\n/g, '\n');
    // 用 ^### 切块，第一块是节首导语，丢掉
    const blocks = text.split(/^### /m).slice(1);

    for (const block of blocks) {
      const lines = block.split('\n');
      const head = lines[0].trim();
      const hm = head.match(/^(\d+)\.\s*(.+)$/);
      if (!hm) { problems.push(`${file}: 标题行不认识 → ${head}`); continue; }

      const body = lines.slice(1).join('\n');
      const tagMatch = body.match(/<!--\s*成本标签[:：]([^>]*?)-->/);
      const tags = tagMatch ? parseTags(tagMatch[1]) : {};
      if (!tagMatch) problems.push(`${file} 第 ${hm[1]} 条: 没有成本标签`);

      // 字段：- 名字：值，值可以跨行（续行不以 "- " 开头）
      const fields = {};
      for (const line of body.split('\n')) {
        const fm = line.match(/^- (备注|成本|来源|收益|说人话|证据等级)[:：]\s?(.*)$/);
        if (fm) {
          fields[fm[1]] = fm[2];
        } else if (line.startsWith('- ')) {
          // 新字段但名字不在表里 —— 书里加了新字段，别静默吞掉
          problems.push(`${file} 第 ${hm[1]} 条: 未知字段 → ${line.slice(0, 40)}`);
        } else if (line.trim() && Object.keys(fields).length) {
          // 续行，接到上一个字段
          const last = Object.keys(fields).pop();
          fields[last] += '\n' + line.trim();
        }
      }

      const item = {
        id: items.length,
        ch: chapter.num,
        chTitle: chapter.title,
        no: Number(hm[1]),
        title: hm[2].trim(),
        cost: fields['成本'] ?? '',
        plain: fields['说人话'] ?? '',
        gain: fields['收益'] ?? '',
        evidence: (fields['证据等级'] ?? '').trim(),
        source: fields['来源'] ?? '',
        note: fields['备注'] ?? '',
        tags,
      };

      if (!item.plain) problems.push(`${file} 第 ${hm[1]} 条: 没有「说人话」`);
      if (!item.evidence) problems.push(`${file} 第 ${hm[1]} 条: 没有「证据等级」`);

      items.push(item);
    }
  }

  return { items, problems };
}

// MARK: 规整

/// 来源里一串 <https://…> 拆成域名数组，够 widget 显示。
/// 按出现顺序去重：一条里常常引同一篇文献的 doi 和摘要页，显示两遍没意义。
function sources(item) {
  const out = [];
  for (const m of item.source.matchAll(/<(https?:\/\/[^>]+)>/g)) {
    let host;
    try {
      host = new URL(m[1]).hostname.replace(/^www\./, '');
    } catch { continue; }
    if (!out.includes(host)) out.push(host);
  }
  return out;
}

/// 收益里常有一长串数字。widget 放不下全文，取前几句。
function brief(text, max = 120) {
  const t = text.replace(/\n/g, ' ').trim();
  if (t.length <= max) return t;
  // 在句号处断，断不了就硬截
  const cut = t.slice(0, max);
  const lastStop = Math.max(cut.lastIndexOf('。'), cut.lastIndexOf('；'));
  return lastStop > max * 0.5 ? cut.slice(0, lastStop + 1) : cut + '…';
}

// MARK: 输出

const { items, problems } = parseBook(bookDir);

if (problems.length) {
  console.error(`⚠️  ${problems.length} 处异常：`);
  for (const p of problems.slice(0, 20)) console.error('   ' + p);
  if (problems.length > 20) console.error(`   …还有 ${problems.length - 20} 处`);
}

/// 证据等级原值有 A / B / C，也带后缀：「A（争议）」「B（指南强推荐，但底层证据等级低）」。
/// 拆成基等级 + 修饰，widget 大字显示 A/B/C，修饰另起一个小角标。
function parseEvidence(raw) {
  const t = raw.trim();
  const m = t.match(/^([ABC])\s*(?:[（(](.+?)[）)])?\s*$/);
  if (!m) return { grade: t.slice(0, 1), qualifier: t.slice(1).replace(/[（）()]/g, '') };
  return { grade: m[1], qualifier: m[2] ?? '' };
}

/// 修饰太长就压成关键词，widget 里只放得下几个字
function shortQualifier(q) {
  if (!q) return '';
  if (q.includes('争议')) return '有争议';
  if (q.includes('指南')) return '指南强推';
  return q.length > 6 ? q.slice(0, 6) + '…' : q;
}

const slim = items.map(it => ({
  i: it.id,
  c: it.ch,
  ct: it.chTitle,
  n: it.no,
  t: it.title,
  k: it.cost,
  p: it.plain,
  g: brief(it.gain),
  e: parseEvidence(it.evidence).grade,
  q: shortQualifier(parseEvidence(it.evidence).qualifier),
  s: sources(it),
  // 成本标签压成短码，widget 直接显示
  m: [
    it.tags['钱'] ? `钱${it.tags['钱']}` : null,
    it.tags['时间'] ? `时${it.tags['时间']}` : null,
    it.tags['毅力'] === '是' ? '要毅力' : null,
    it.tags['收益'] ? `收益${it.tags['收益']}` : null,
  ].filter(Boolean).join(' · '),
}));

const chapters = [...new Map(items.map(it => [it.ch, it.chTitle])).entries()]
  .sort((a, b) => a[0] - b[0])
  .map(([num, title]) => ({ num, title, count: items.filter(i => i.ch === num).length }));

const payload = {
  title: '高性价比人生指南',
  repo: 'https://github.com/eternity4719/HowToLiveBetter',
  license: 'CC BY 4.0',
  count: slim.length,
  chapters,
  items: slim,
};

const jsonPath = resolve(ROOT, 'data/items.json');
// data/ 是生成目录、不进仓库，新克隆下来时不存在
mkdirSync(dirname(jsonPath), { recursive: true });
writeFileSync(jsonPath, JSON.stringify(payload, null, 1));
console.log(`✅ ${slim.length} 条 → ${jsonPath}`);

// MARK: 生成 Swift 常量
//
// 数据直接编译进 appex，不依赖任何文件 —— 小组件被强制沙盒，
// 少一个运行时依赖就少一个静默失败的理由。

const json = JSON.stringify(payload);
// Swift 多行字符串里 $ 不用转义，但 " 和 \ 要；用 #""" 原始字符串连 \ 都不用转义，
// 只要内容里不出现 "# 序列。
if (json.includes('"#')) throw new Error('JSON 里含 "# 序列，会撞上 Swift 原始字符串分隔符');

const swift = `// 本文件由 tools/embed.mjs 生成，不要手改。
//
// 数据源：${payload.repo}（${payload.license}）
// 共 ${slim.length} 条，编译自 book/ 的 ${chapters.length} 个章节。

import Foundation

enum BookData {
    /// 全书 JSON。直接编译进二进制，小组件不读文件也能出内容。
    static let json = #"""
${json}
"""#

    static let repoURL = URL(string: "${payload.repo}")!
    static let bookTitle = "${payload.title}"
    static let itemCount = ${slim.length}
}
`;

const swiftPath = resolve(ROOT, 'Widget/BookData.swift');
writeFileSync(swiftPath, swift);
console.log(`✅ Swift 常量 → ${swiftPath}`);
console.log(`   章节 ${chapters.length} 个，条目 ${slim.length} 条`);
console.log(`   样本：第 ${slim[0].c} 节第 ${slim[0].n} 条「${slim[0].t}」`);
