#!/usr/bin/env node
// 生成 Metadata.appintents，让小组件上的「换一条」按钮真的能派发。
//
// 为什么需要它：macOS 14+ 的交互式小组件按钮，点击后不是就地跑代码 ——
// chronod 先把这次点击交给 linkd，linkd 按 **intent 的类型名**去查一份元数据，
// 查到才去调 perform()。这份元数据正常由 Xcode 的 appintentsmetadataprocessor
// 在构建时生成，而那个工具只在 Xcode 里，Command Line Tools 没有 ——
// 所以这里手工生成一份等价物。
//
// 不生成的话，点击会在 chronod 里直接失败：
//   WFLinkActionWorkflowRunnerClientErrorDomain Code=1
//   "There is no metadata for ShuffleIntent in com.local.lifewidget"
// 表现就是「按钮点得动，小组件永远不变」，而 perform() 一次都不会被调用。
//
// 关键约束：mangledTypeNameV2 必须和 appex 二进制里的符号逐字一致。
// 可以这样核对（两边应当一模一样）：
//   nm .../LifeWidgetExtension | grep -o '\$s19LifeWidgetExtension13ShuffleIntentV'

import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')

// 模块名 = appex 的产物名。改了 build.sh 里的 WIDGET_NAME 这里也要跟着改，
// 否则 mangled name 对不上，退回「点得动但没反应」。
const MODULE = 'LifeWidgetExtension'

/// Swift 的 mangling：<长度><名字>，长度是字节数（中文模块名会不一样，这里都是 ASCII）。
/// 结构体最后那个 V 是类型标记（enum 是 O、class 是 C）：`mangledTypeNameV2` 跟它是同一个
/// 字符串。漏掉它不会报任何错，只会让 linkd 查不到类型 —— 也就是按钮没反应。
const mangle = (name) => `${MODULE.length}${MODULE}${name.length}${name}V`

/// 目标 appex 的 Resources 目录。build.sh 传进来；缺省是本地 build 目录。
const appexResources =
  process.argv[2] || join(root, 'build', 'LifeWidget.app', 'Contents', 'PlugIns', `${MODULE}.appex`, 'Contents', 'Resources')

/// 按 Calculator 的 appintents 元数据逐字段对齐。
///
/// 保留那些看着像空壳的字段（mangledTypeNameByBundleIdentifier、assistantDefinedSchemas
/// 之类）：它们是 linkd 反序列化时期望存在的键，删掉有风险，留着没成本。
/// 值为空的集合就照抄空集合，不猜语义。
function action({ identifier, title, description, mangled, fullyQualified }) {
  return {
    availabilityAnnotations: { LNPlatformNameWildcard: { introducedVersion: '*' } },
    isAuthPolExplicit: true,
    presentationStyle: 0,
    mangledTypeNameV2: mangled,
    // false = 点击不把宿主 app 拽到前台。小组件上换个条不该弹窗，
    // 何况这是个 LSUIElement 的菜单栏 app，本来就没有窗口。
    openAppWhenRun: false,
    authenticationPolicy: 0,
    identifier,
    effectiveBundleIdentifiers: [],
    parameters: [],
    systemProtocols: [],
    assistantDefinedSchemaTraits: [],
    systemProtocolMetadataV2: [],
    fullyQualifiedTypeName: fullyQualified,
    isDiscoverable: true,
    descriptionMetadata: {
      searchKeywords: [],
      // 硬编码的中文字面量，不是本地化 key —— 不带 table，直接给文本
      descriptionText: { alternatives: [], key: description },
    },
    mangledTypeNameByBundleIdentifier: {},
    visibilityMetadata: { isDiscoverable: true, assistantOnly: false },
    outputFlags: 0,
    assistantDefinedSchemas: [],
    mangledTypeNameByBundleIdentifierV2: {},
    title: { alternatives: [], key: title },
    systemProtocolMetadata: [],
    typeSpecificMetadata: [],
    requiredCapabilities: [],
    mangledTypeName: mangled,
  }
}

const shuffle = 'ShuffleIntent'
const shufflemangled = mangle(shuffle)

const payload = {
  actions: {
    [shuffle]: action({
      identifier: shuffle,
      title: '换一条',
      description: '跳过今天这条，看下一条',
      mangled: shufflemangled,
      fullyQualified: `${MODULE}.${shuffle}`,
    }),
  },
  assistantIntentNegativePhrases: [],
  version: 1,
  entities: {},
  negativePhrases: [],
  generator: { name: 'life-widget-tools', version: '1' },
  enums: [],
  queries: {},
  assistantEntities: [],
  assistantIntents: [],
  autoShortcuts: [],
  shortcutTileColor: 14,
}

const dir = join(appexResources, 'Metadata.appintents')
mkdirSync(dir, { recursive: true })

// extract.actionsdata 是**无换行**的紧凑 JSON（系统的也是，
// file(1) 报 "ASCII text, with very long lines, with no line terminators"）
writeFileSync(join(dir, 'extract.actionsdata'), JSON.stringify(payload))

// version.json 是给人/工具看的两字段清单，格式与系统一致
writeFileSync(join(dir, 'version.json'), JSON.stringify({ toolsVersion: '16E6052g', version: '3.0' }, null, 2) + '\n')

// 生成完自检：mangled name 必须真的在二进制里出现过。
// 这一步是防呆 —— 写错了不会有任何报错，只会静默退回「按钮没反应」。
// appex 结构：Contents/Resources ← 这里，二进制在 Contents/MacOS
const binary = join(dirname(appexResources), 'MacOS', MODULE)
if (existsSync(binary)) {
  const symbols = readFileSync(binary, 'latin1')
  if (!symbols.includes(`${shufflemangled}10AppIntents`)) {
    console.error(`❌ 元数据里的 mangledTypeName "${shufflemangled}" 在 ${MODULE} 二进制里找不到。`)
    console.error('   按钮会静默失效。检查 MODULE 是否与 appex 产物名一致。')
    process.exit(1)
  }
  console.log(`   已核对：${shufflemangled} 与二进制符号一致`)
} else {
  console.log(`   （跳过核对：${binary} 还不存在）`)
}

console.log(`==> 生成 Metadata.appintents（${shuffle}）`)
console.log(`    ${dir}`)
