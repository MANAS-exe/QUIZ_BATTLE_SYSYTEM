// Run with: mongosh mongodb://localhost:27017/quizdb speakx_questions.js

const db = connect("mongodb://localhost:27017/quizdb");

db.questions.insertMany([

  // ── EASY — Vocabulary ─────────────────────────────────────────
  {
    text: "Which word is a synonym of 'Happy'?",
    options: ["Angry", "Joyful", "Tired", "Sad"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7000
  },
  {
    text: "Which word is the antonym of 'Expand'?",
    options: ["Grow", "Stretch", "Shrink", "Widen"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7500
  },
  {
    text: "Choose the correct homophone: 'I could ___ the flowers from the garden.'",
    options: ["sea", "see", "si", "cel"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "homophones",
    avgResponseTimeMs: 8000
  },
  {
    text: "Which of these is a NOUN?",
    options: ["Quickly", "Beautiful", "Freedom", "Run"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "parts-of-speech",
    avgResponseTimeMs: 7000
  },
  {
    text: "Pick the correct article: '___ apple a day keeps the doctor away.'",
    options: ["A", "An", "The", "No article needed"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "articles",
    avgResponseTimeMs: 6500
  },

  // ── EASY — Real-life Conversation ─────────────────────────────
  {
    text: "You meet someone for the first time at work. What is the most polite greeting?",
    options: [
      "Hey, what's up?",
      "Pleased to meet you.",
      "Yeah, hi.",
      "What do you want?"
    ],
    correctIndex: 1,
    difficulty: "easy",
    topic: "conversation",
    avgResponseTimeMs: 9000
  },

  // ── MEDIUM — Grammar ──────────────────────────────────────────
  {
    text: "Choose the correct sentence:",
    options: [
      "She don't like coffee.",
      "She doesn't likes coffee.",
      "She doesn't like coffee.",
      "She not like coffee."
    ],
    correctIndex: 2,
    difficulty: "medium",
    topic: "grammar",
    avgResponseTimeMs: 12000
  },
  {
    text: "Which sentence uses the Present Perfect tense correctly?",
    options: [
      "I am eating breakfast already.",
      "I have already eaten breakfast.",
      "I already eat breakfast.",
      "I was eating breakfast already."
    ],
    correctIndex: 1,
    difficulty: "medium",
    topic: "grammar",
    avgResponseTimeMs: 13000
  },
  {
    text: "Fill in the blank: 'Neither the students nor the teacher ___ ready.'",
    options: ["were", "are", "was", "have been"],
    correctIndex: 2,
    difficulty: "medium",
    topic: "grammar",
    avgResponseTimeMs: 15000
  },

  // ── MEDIUM — Vocabulary & Idioms ──────────────────────────────
  {
    text: "What does the idiom 'bite the bullet' mean?",
    options: [
      "To eat something very hard",
      "To endure a painful situation with courage",
      "To make a quick decision",
      "To argue aggressively"
    ],
    correctIndex: 1,
    difficulty: "medium",
    topic: "idioms",
    avgResponseTimeMs: 14000
  },
  {
    text: "Which word correctly completes: 'The manager gave a ___ speech that inspired everyone.'",
    options: ["monotonous", "motivational", "murmuring", "misleading"],
    correctIndex: 1,
    difficulty: "medium",
    topic: "vocabulary",
    avgResponseTimeMs: 13000
  },
  {
    text: "Choose the sentence with correct punctuation:",
    options: [
      "However, she decided to stay.",
      "However she, decided to stay.",
      "However she decided, to stay.",
      "However she decided to, stay."
    ],
    correctIndex: 0,
    difficulty: "medium",
    topic: "punctuation",
    avgResponseTimeMs: 14000
  },

  // ── MEDIUM — Job Interview / Professional ─────────────────────
  {
    text: "In a job interview, which response best answers 'Tell me about yourself'?",
    options: [
      "I am a very hard-working person and I want money.",
      "I have 3 years of experience in sales and I recently led a team of 5 people.",
      "I don't know, I am just looking for a job.",
      "My name is Rahul and I live in Delhi."
    ],
    correctIndex: 1,
    difficulty: "medium",
    topic: "professional-english",
    avgResponseTimeMs: 18000
  },

  // ── HARD — Advanced Grammar ───────────────────────────────────
  {
    text: "Which sentence uses the subjunctive mood correctly?",
    options: [
      "I wish I was taller.",
      "I wish I were taller.",
      "I wish I am taller.",
      "I wish I would be taller."
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "grammar",
    avgResponseTimeMs: 20000
  },
  {
    text: "Identify the dangling modifier: which sentence has an error?",
    options: [
      "Walking to school, the birds were chirping.",
      "Walking to school, she heard the birds chirping.",
      "As she walked to school, she heard the birds.",
      "She walked to school while listening to birds."
    ],
    correctIndex: 0,
    difficulty: "hard",
    topic: "sentence-structure",
    avgResponseTimeMs: 22000
  },

  // ── HARD — Vocabulary ─────────────────────────────────────────
  {
    text: "Which pair are homophones?",
    options: [
      "Principle / Principal",
      "Accept / Except",
      "Desert / Dessert",
      "Affect / Effect"
    ],
    correctIndex: 0,
    difficulty: "hard",
    topic: "homophones",
    avgResponseTimeMs: 19000
  },
  {
    text: "What does 'perspicacious' mean?",
    options: [
      "Having a strong sense of smell",
      "Quick to notice and understand things",
      "Feeling very tired after hard work",
      "Prone to making mistakes"
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "vocabulary",
    avgResponseTimeMs: 22000
  },

  // ── HARD — Formal Writing ─────────────────────────────────────
  {
    text: "Which opening line is most appropriate for a formal complaint letter?",
    options: [
      "Hey, I am very angry about this.",
      "I am writing to express my dissatisfaction regarding...",
      "You guys messed up big time.",
      "This is to tell you that things went wrong."
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "formal-writing",
    avgResponseTimeMs: 20000
  },

  // ── HARD — Fluency / Pronunciation context ────────────────────
  {
    text: "Which word has the stress on the SECOND syllable?",
    options: ["Photograph", "Photography", "Photographic", "Photo"],
    correctIndex: 1,
    difficulty: "hard",
    topic: "pronunciation",
    avgResponseTimeMs: 21000
  },

  // ── HARD — Sentence Structure ─────────────────────────────────
  {
    text: "Choose the sentence that is in PASSIVE voice:",
    options: [
      "The chef cooked a delicious meal.",
      "A delicious meal was cooked by the chef.",
      "The chef is cooking a meal.",
      "The chef had cooked a meal."
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "sentence-structure",
    avgResponseTimeMs: 18000
  }

]);

print("✓ 20 SpeakX-style English questions inserted");

print("\n── Breakdown ──────────────────────────");
["easy","medium","hard"].forEach(d =>
  print("  " + d + ": " + db.questions.countDocuments({ difficulty: d }))
);
print("\n── By topic ───────────────────────────");
[
  "vocabulary","grammar","idioms","homophones",
  "parts-of-speech","articles","conversation",
  "punctuation","sentence-structure","pronunciation",
  "formal-writing","professional-english"
].forEach(t => {
  const n = db.questions.countDocuments({ topic: t });
  if (n > 0) print("  " + t + ": " + n);
});
print("\nTotal questions in DB: " + db.questions.countDocuments());