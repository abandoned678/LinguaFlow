import InputCore
import SwiftUI

struct UsageGuide: View {
    let settings: InputSettings

    var body: some View {
        Form {
            Section("拼音选词") {
                Text("选择随键译，在「翻译」中选“中文 → 英文”。输入 nihao，按空格上屏高亮候选，也可点选候选或用数字键选择。")
                Text("每页可设 5～10 项，目前为 \(settings.candidatePageSize) 项。1～9 选对应编号；出现第十项时按 0。点击翻页箭头查看更多候选。")
                Text("组词时用左右方向键移动光标。想保留原样的拉丁字母，按 Return；没有组词时，Return 由当前应用处理。")
            }
            Section("中英文混输") {
                Text("输入技术词或一段英文时，可在「输入与候选」开启“单按 Shift 切换临时英文”。单按一次会提示“临时英文”并开始直输，再按一次会提示“中文拼音”；如果有未确认拼音，会先取消组词。翻译方向保持原设置。")
                Text("在输入法菜单或「翻译」中选择“英文 → 简体中文”即可直接输入英文整句。切换翻译方向会取消未上屏的拼音，已上屏文字保留。")
            }
            Section("预览和替换") {
                Text("停顿后会显示当前句译文。已上屏的句末标点会加快预览，单独输入一个句号也可预览。中文上屏后再按空格，即开始新的翻译上下文。")
                Text("在句尾等译文就绪，按 \(SentenceReplacementShortcut.label(for: settings.replacementKeyCode)) 或在输入法菜单选“用译文替换当前句”。按 ⌘Z 可在支持撤销的应用中恢复原文。")
                Text("在「翻译」中可以准备本地模型、调整速度，或单独关闭某个应用的预览。关闭预览后仍可正常选词。")
            }
            Section("常用词与按键") {
                Text("迁移已有词条时，打开「词典与短语 → 从文件导入」，选择来源和文件，核对条数后点「导入」。苹果选文本替换 plist，搜狗选自定义短语文本；带词频的词表单独导入。")
                Text("在「词典与短语」为人名或常用回复添加输入码。在「输入与候选」选择拼音方案、模糊音和词频学习，在「外观与操作」修改替换键和翻页键。")
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}
