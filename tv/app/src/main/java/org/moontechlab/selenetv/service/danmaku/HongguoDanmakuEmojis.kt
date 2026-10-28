package org.moontechlab.selenetv.service.danmaku

/**
 * 红果短剧官方表情与弹幕标签解析器 (对齐手机端红果短剧规范)
 * 将 [爱慕]、［666］、[点赞] 等 150+ 种官方标签精准映射为原生彩色 Emoji 字符，
 * 并自动清洗控制字符与损坏的异常占位符。
 */
object HongguoDanmakuEmojis {

    val emojiMap: Map<String, String> = mapOf(
        // 喜爱 / 心动 / 爱慕 / 恋爱
        "爱慕" to "😍",
        "色" to "😍",
        "花痴" to "😍",
        "心动" to "💓",
        "喜欢" to "🥰",
        "心" to "❤️",
        "爱心" to "❤️",
        "红心" to "❤️",
        "比心" to "🫰",
        "比个心" to "🫰",
        "送心" to "💖",
        "飞吻" to "😘",
        "亲亲" to "😚",
        "吻" to "💋",
        "害羞" to "😳",
        "脸红" to "😳",
        "可爱" to "🥺",
        "可怜" to "🥺",
        "爱了爱了" to "🥰",

        // 开心 / 大笑 / 幽默
        "大笑" to "😄",
        "笑" to "😊",
        "哈哈" to "😄",
        "笑哭" to "😂",
        "笑翻" to "🤣",
        "笑cry" to "😂",
        "偷笑" to "🤭",
        "奸笑" to "😏",
        "坏笑" to "😈",
        "得意" to "😎",
        "酷" to "😎",
        "机智" to "🤓",
        "聪明" to "🤓",
        "捂脸" to "🤦",
        "打脸" to "😣",
        "尬笑" to "😅",
        "调皮" to "😜",
        "憨笑" to "😄",
        "愉快" to "😊",
        "开心" to "😃",

        // 悲伤 / 感动 / 哭泣
        "流泪" to "😭",
        "泪奔" to "😭",
        "泣不成声" to "😭",
        "哭" to "😭",
        "快哭了" to "🥲",
        "泪" to "😢",
        "难过" to "🥺",
        "委屈" to "🥺",
        "绝望" to "😩",
        "吐血" to "🩸",
        "心碎" to "💔",
        "感动" to "🥹",
        "逞强落泪" to "🥲",

        // 震惊 / 惊讶 / 无语
        "震惊" to "😱",
        "惊恐" to "😱",
        "惊呆" to "😲",
        "惊讶" to "😲",
        "发呆" to "😳",
        "翻白眼" to "🙄",
        "白眼" to "🙄",
        "无语" to "😑",
        "汗" to "😅",
        "冷汗" to "😅",
        "尴尬" to "😅",
        "抓狂" to "😫",
        "黑线" to "😓",
        "石化" to "🗿",
        "晕" to "😵",
        "撇嘴" to "😒",
        "鄙视" to "😒",
        "呆住" to "😶",

        // 赞同 / 互动 / 点赞
        "赞" to "👍",
        "点赞" to "👍",
        "强" to "👍",
        "棒" to "👍",
        "真棒" to "👍",
        "太棒了" to "👏",
        "给力" to "💪",
        "加油" to "💪",
        "踩" to "👎",
        "弱" to "👎",
        "鼓掌" to "👏",
        "掌声" to "👏",
        "握手" to "🤝",
        "抱拳" to "🤜🤛",
        "拥抱" to "🤗",
        "抱抱" to "🤗",
        "抱抱你" to "🤗",
        "祈祷" to "🙏",
        "保佑" to "🙏",
        "拜托" to "🙏",
        "求求了" to "🙏",
        "双手合十" to "🙏",
        "击掌" to "🙌",
        "OK" to "👌",
        "ok" to "👌",
        "好的" to "👌",
        "耶" to "✌️",
        "胜利" to "✌️",
        "666" to "🤙",
        "双击666" to "🤙",
        "6" to "🤙",
        "牛" to "🐂",
        "牛逼" to "🐂",
        "100" to "💯",
        "100分" to "💯",
        "秀儿" to "🎭",
        "还得是你" to "🤝",
        "打call" to "📣",
        "加鸡腿" to "🍗",

        // 思考 / 吃瓜 / 状态
        "看" to "👀",
        "观察" to "👀",
        "瞅瞅" to "👀",
        "暗中观察" to "🕵️",
        "吃瓜" to "🍉",
        "吃瓜群众" to "🍉",
        "思考" to "🤔",
        "想" to "🤔",
        "嘘" to "🤫",
        "困" to "🥱",
        "打哈欠" to "🥱",
        "哈欠" to "🥱",
        "睡" to "😴",
        "睡觉" to "😴",
        "打瞌睡" to "😴",
        "闭嘴" to "🤐",
        "再见" to "👋",
        "拜拜" to "👋",
        "互关" to "🤝",
        "互粉" to "🤝",
        "关注我" to "🔔",

        // 愤怒 / 情绪
        "愤怒" to "😡",
        "生气" to "😡",
        "发怒" to "😡",
        "怒" to "💢",
        "傲慢" to "😤",
        "哼" to "😤",
        "左哼哼" to "😤",
        "右哼哼" to "😤",
        "别发癫了" to "🙄",
        "别说了" to "🤫",

        // 物品 / 符号 / 趣味
        "火" to "🔥",
        "点火" to "🔥",
        "续火花" to "✨",
        "礼物" to "🎁",
        "玫瑰" to "🌹",
        "送花" to "🌹",
        "鲜花" to "💐",
        "干杯" to "🍻",
        "啤酒" to "🍺",
        "咖啡" to "☕",
        "蛋糕" to "🎂",
        "太阳" to "☀️",
        "月亮" to "🌙",
        "钱" to "💰",
        "发财" to "💰",
        "爱钱" to "💰",
        "锦鲤" to "🐟",
        "便便" to "💩",
        "炸弹" to "💣",
        "烟花" to "🎆",
        "庆祝" to "🎉",
        "狗头" to "🐶",
        "菜狗" to "🐶",
        "猪头" to "🐷",
        "柠檬" to "🍋",
        "酸" to "🍋",
        "我酸了" to "🍋",
        "疑问" to "❓",
        "感叹" to "❗️",
        "问号" to "❓",
        "叹号" to "❗️",
        "What" to "❓",
        "红包" to "🧧",
        "贴贴" to "🫂",
        "裂开" to "💔",
        "绝了" to "💯"
    )

    private val EMOJI_REGEX = Regex("(\\[|［)\\s*([^\\[\\]［］]{1,16}?)\\s*(\\]|］)")

    /**
     * 将包含 [爱慕]、［666］、[点赞] 等表情标签的短剧弹幕文本转换为生动 Emoji 字符
     */
    fun formatHongguoDanmakuText(input: String): String {
        if (input.isEmpty()) return input

        // 1. 清理控制字符与行隔离符
        val cleaned = input.replace(Regex("[\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029]"), " ").trim()

        // 2. 匹配中英文方括号内的标签并替换: 53个官方原版高清WebP表情规范保留为标准标签供Canvas绘制Bitmap，其余收录标签转为原生Unicode Emoji
        return EMOJI_REGEX.replace(cleaned) { matchResult ->
            val key = matchResult.groupValues[2].trim()
            if (key.isEmpty() || key == "\$key" || key == "key") {
                ""
            } else if (HongguoEmojiManager.codeToFileMap.containsKey(key) || HongguoEmojiManager.codeToFileMap.containsKey("[$key]")) {
                "[$key]"
            } else {
                emojiMap[key] ?: matchResult.value
            }
        }
    }
}
