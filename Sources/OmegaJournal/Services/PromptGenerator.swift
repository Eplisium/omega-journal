import Foundation

// MARK: - Daily Prompt Generator

enum PromptGenerator {
    private static let prompts: [String] = [
        // Gratitude & positivity
        "What are you grateful for today?",
        "Describe a small moment that made you smile.",
        "What's a kindness someone showed you?",
        "What made you feel proud recently?",
        "What's a win you're celebrating?",
        "What made you laugh today?",
        "What brings you peace?",
        "What's something you appreciate about yourself?",
        "Name three things that went well today.",
        "What's the best compliment you've received?",

        // Reflection
        "What's been on your mind lately?",
        "What did you learn today?",
        "What would you tell your past self?",
        "What does success mean to you?",
        "What's a memory you never want to forget?",
        "How have you changed in the past year?",
        "What's something you've been avoiding?",
        "What's weighing on your heart today?",
        "What would your life look like without fear?",
        "What's a belief you've outgrown?",

        // Future & goals
        "Write about something you're looking forward to.",
        "Describe your perfect day.",
        "Write a letter to your future self.",
        "Describe a goal and the first step toward it.",
        "What's a dream you're nurturing?",
        "What does a good day look like to you?",
        "Where do you see yourself in five years?",
        "What's one thing you'd change about your routine?",
        "What would make today count?",
        "What's a risk worth taking?",

        // People & relationships
        "Who inspires you, and why?",
        "Describe a person who changed your life.",
        "Who would you thank if you could?",
        "What does friendship mean to you?",
        "Describe a conversation that stuck with you.",
        "Who makes you feel safe?",
        "What's the best advice someone gave you?",
        "Describe someone you admire from afar.",
        "What's a relationship you want to invest in?",
        "How do you show love?",

        // Self-care & wellbeing
        "What does self-care look like for you?",
        "What's a habit you want to build?",
        "What's a boundary you need to set?",
        "What's a fear you want to overcome?",
        "Describe a place that makes you feel calm.",
        "What drains your energy?",
        "What recharges you?",
        "How do you handle stress?",
        "What's your body telling you today?",
        "What would you do with an extra hour?",

        // Creativity & curiosity
        "What's something you're curious about?",
        "Describe a recent adventure, big or small.",
        "What's something new you tried recently?",
        "Describe your ideal weekend.",
        "What's a skill you'd love to learn?",
        "If you could live anywhere, where would it be?",
        "What book or movie changed your perspective?",
        "Describe a favorite smell and the memory it brings.",
        "What's something beautiful you noticed today?",
        "If you could have dinner with anyone, who?",

        // Deeper prompts
        "What are your top three priorities right now?",
        "What do you want more of in your life?",
        "What do you want less of?",
        "What's something you forgive yourself for?",
        "What does home mean to you?",
        "What's a pattern you keep repeating?",
        "What would you do if you knew you couldn't fail?",
        "What's the hardest decision you've made?",
        "What's a truth you're avoiding?",
        "What does freedom mean to you?",

        // Seasonal & timely
        "What's your favorite season and why?",
        "Describe the view outside your window right now.",
        "What's a tradition you love?",
        "What's something you want to accomplish this month?",
        "How did you take care of yourself this week?",
        "What's a small pleasure you enjoyed today?",
        "Describe your morning routine.",
        "What's a song that matches your mood?",
        "What color represents your day?",
        "If today were a chapter in your life, what's the title?",

        // Gratitude deep dive
        "What's a failure you're grateful for?",
        "What's a challenge you're facing right now?",
        "What's something difficult that made you stronger?",
        "What's a privilege you don't think about often?",
        "What made today different from yesterday?",
        "What's a simple pleasure you overlooked recently?",
        "Who deserves a thank-you from you?",
        "What's something you're looking forward to this week?",
        "What would make tomorrow even better?",
        "End this sentence: Today I am..."
    ]

    static func today() -> String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return prompts[(day - 1) % prompts.count]
    }

    static func random() -> String {
        prompts.randomElement() ?? prompts[0]
    }
}
