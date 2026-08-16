import Foundation

/// A bundled cold-start prior derived from Unicode's ranked median emoji
/// frequency table. Unicode groups frequency into exponentially decreasing
/// tiers; only the high-signal tiers are retained here so older long-tail data
/// doesn't unfairly suppress emoji introduced after the table was assembled.
///
/// Source: https://www.unicode.org/emoji/frequency.html
/// Accessed: 2026-08-16
///
/// Unicode License V3 — Copyright © 1991-2026 Unicode, Inc.
/// Permission is hereby granted, free of charge, to any person obtaining a
/// copy of data files and any associated documentation to deal in the data
/// files without restriction, provided that this copyright and permission
/// notice appear with all copies or in associated documentation.
/// https://www.unicode.org/license.txt
enum EmojiGeneralFrequency {
    struct Rank: Equatable, Sendable {
        let tier: Int
        let order: Int
    }

    /// Unranked emoji share the next tier instead of sorting after every emoji
    /// in Unicode's older long tail.
    static let unrankedTier = tierCharacters.count

    static func rank(of character: String) -> Rank? {
        ranks[character]
    }

    private static let ranks: [String: Rank] = {
        var result: [String: Rank] = [:]
        for (tier, characters) in tierCharacters.enumerated() {
            for (order, character) in characters.split(separator: " ").enumerated() {
                result[String(character)] = Rank(tier: tier, order: order)
            }
        }
        return result
    }()

    private static let tierCharacters = [
        "😂 ❤️",
        "😍 🤣",
        "😊 🙏 💕 😭 😘",
        "👍 😅 👏 😁 ♥️ 🔥 💔 💖 💙 😢 🤔 😆 🙄 💪 😉 ☺️ 👌 🤗",
        "💜 😔 😎 😇 🌹 🤦 🎉 ‼️ 💞 ✌️ ✨ 🤷 😱 😌 🌸 🙌 😋 💗 💚 😏 💛 🙂 💓 🤩 😄 😀 🖤 😃 💯 🙈 👇 🎶 😒 🤭 ❣️",
        "❗ 😜 💋 👀 😪 😑 💥 🙋 😞 😩 😡 🤪 👊 ☀️ 😥 🤤 👉 💃 😳 ✋ 😚 😝 😴 🌟 😬 🙃 🍀 🌷 😻 😓 ⭐ ✅ 🌈 😈 🤘",
        "💦 ✔️ 😣 🏃 💐 ☹️ 🎊 💘 😠 ☝️ 😕 🌺 🎂 🌻 😐 🖕 💝 🙊 😹 🗣️ 💫 💀 👑 🎵 🤞 😛 🔴 😤 🌼 😫 ⚽ 🤙 ☕ 🏆 🧡 🎁 ⚡ 🌞 🎈 ❌ ✊ 👋 😲 🌿 🤫 👈 😮 🙆 🍻 🍃 🐶 💁 😰 🤨 😶 🤝 🚶 💰 🍓 💢",
        "🇺🇸 🤟 🙁 🚨 💨 🤬 ✈️ 🎀 🍺 🤓 😙 💟 🌱 😖 👶 ▶️ ➡️ ❓ 💎 💸 ⬇️ 😨 🌚 🦋 😷 🕺 ⚠️ 🙅 😟 😵 👎 🤲 🤠 🤧 📌 🔵 💅 🧐 🐾 🍒 😗 🤑 🚀 🌊 🤯 🐷 ☎️ 💧 😯 💆 👆 🎤 🙇 🍑 ❄️ 🌴 🇧🇷 💣 🐸 💌 📍 🥀 🤢 👅 💡 💩 ⁉️ 👐 📸 👻 🤐 🤮 🎼 ✍️ 🚩 🍎 🍊 👼 💍 📣 🥂 ⤵️ 📱 ☔ 🌙"
    ]
}
