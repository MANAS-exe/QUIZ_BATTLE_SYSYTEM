// Run with: mongosh mongodb://localhost:27017/quizdb speakx_questions.js

const db = connect("mongodb://localhost:27017/quizdb");

db.questions.insertMany([

  // ── EASY — Vocabulary ─────────────────────────────────────────
  {
    question_id: "q_001",
    text: "Which word is a synonym of 'Happy'?",
    options: ["Angry", "Joyful", "Tired", "Sad"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7000
  },
  {
    question_id: "q_002",
    text: "Which word is the antonym of 'Expand'?",
    options: ["Grow", "Stretch", "Shrink", "Widen"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7500
  },
  {
    question_id: "q_003",
    text: "Choose the correct homophone: 'I could ___ the flowers from the garden.'",
    options: ["sea", "see", "si", "cel"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "homophones",
    avgResponseTimeMs: 8000
  },
  {
    question_id: "q_004",
    text: "Which of these is a NOUN?",
    options: ["Quickly", "Beautiful", "Freedom", "Run"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "parts-of-speech",
    avgResponseTimeMs: 7000
  },
  {
    question_id: "q_005",
    text: "Pick the correct article: '___ apple a day keeps the doctor away.'",
    options: ["A", "An", "The", "No article needed"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "articles",
    avgResponseTimeMs: 6500
  },

  // ── EASY — Real-life Conversation ─────────────────────────────
  {
    question_id: "q_006",
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
    question_id: "q_007",
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
    question_id: "q_008",
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
    question_id: "q_009",
    text: "Fill in the blank: 'Neither the students nor the teacher ___ ready.'",
    options: ["were", "are", "was", "have been"],
    correctIndex: 2,
    difficulty: "medium",
    topic: "grammar",
    avgResponseTimeMs: 15000
  },

  // ── MEDIUM — Vocabulary & Idioms ──────────────────────────────
  {
    question_id: "q_010",
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
    question_id: "q_011",
    text: "Which word correctly completes: 'The manager gave a ___ speech that inspired everyone.'",
    options: ["monotonous", "motivational", "murmuring", "misleading"],
    correctIndex: 1,
    difficulty: "medium",
    topic: "vocabulary",
    avgResponseTimeMs: 13000
  },
  {
    question_id: "q_012",
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
    question_id: "q_013",
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
    question_id: "q_014",
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
    question_id: "q_015",
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
    question_id: "q_016",
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
    question_id: "q_017",
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
    question_id: "q_018",
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
    question_id: "q_019",
    text: "Which word has the stress on the SECOND syllable?",
    options: ["Photograph", "Photography", "Photographic", "Photo"],
    correctIndex: 1,
    difficulty: "hard",
    topic: "pronunciation",
    avgResponseTimeMs: 21000
  },

  // ── HARD — Sentence Structure ─────────────────────────────────
  {
    question_id: "q_020",
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
  },

  // ── EASY — Vocabulary (q_021–q_024) ─────────────────────────
  {
    question_id: "q_021",
    text: "Which word means the opposite of 'Ancient'?",
    options: ["Old", "Modern", "Historical", "Classic"],
    correctIndex: 1,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7000
  },
  {
    question_id: "q_022",
    text: "What does 'Frequently' mean?",
    options: ["Rarely", "Never", "Often", "Sometimes"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "vocabulary",
    avgResponseTimeMs: 7500
  },
  {
    question_id: "q_023",
    text: "Which sentence is grammatically correct?",
    options: [
      "He go to school every day.",
      "He goes to school every day.",
      "He going to school every day.",
      "He gone to school every day."
    ],
    correctIndex: 1,
    difficulty: "easy",
    topic: "grammar",
    avgResponseTimeMs: 8000
  },
  {
    question_id: "q_024",
    text: "Which word is an ADJECTIVE?",
    options: ["Run", "Slowly", "Beautiful", "Sing"],
    correctIndex: 2,
    difficulty: "easy",
    topic: "parts-of-speech",
    avgResponseTimeMs: 7000
  },

  // ── MEDIUM — Grammar & Idioms (q_025–q_027) ─────────────────
  {
    question_id: "q_025",
    text: "What does the idiom 'spill the beans' mean?",
    options: [
      "To make a mess while cooking",
      "To reveal a secret",
      "To waste food",
      "To be careless"
    ],
    correctIndex: 1,
    difficulty: "medium",
    topic: "idioms",
    avgResponseTimeMs: 13000
  },
  {
    question_id: "q_026",
    text: "Choose the correct sentence:",
    options: [
      "If I would have time, I will help you.",
      "If I have time, I will help you.",
      "If I have time, I would helped you.",
      "If I had time, I will help you."
    ],
    correctIndex: 1,
    difficulty: "medium",
    topic: "grammar",
    avgResponseTimeMs: 14000
  },
  {
    question_id: "q_027",
    text: "Which word best fills the blank: 'The report was ___ because it lacked evidence.'",
    options: ["convincing", "compelling", "inconclusive", "definitive"],
    correctIndex: 2,
    difficulty: "medium",
    topic: "vocabulary",
    avgResponseTimeMs: 15000
  },

  // ── HARD — Advanced (q_028–q_030) ────────────────────────────
  {
    question_id: "q_028",
    text: "Which sentence contains a split infinitive?",
    options: [
      "She decided to leave early.",
      "She wanted to boldly go where no one had gone.",
      "She asked him to stay.",
      "She tried leaving early."
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "grammar",
    avgResponseTimeMs: 22000
  },
  {
    question_id: "q_029",
    text: "What does 'equivocate' mean?",
    options: [
      "To speak clearly and directly",
      "To use vague language to avoid commitment",
      "To translate between languages",
      "To repeat oneself unnecessarily"
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "vocabulary",
    avgResponseTimeMs: 22000
  },
  {
    question_id: "q_030",
    text: "Which is the correct use of a semicolon?",
    options: [
      "I love reading; books.",
      "She was tired; however, she kept working.",
      "He runs; fast.",
      "They ate; and drank."
    ],
    correctIndex: 1,
    difficulty: "hard",
    topic: "punctuation",
    avgResponseTimeMs: 20000
  }

]);

print("✓ 30 SpeakX-style English questions inserted");

// ── Create indexes ──────────────────────────────────────────
db.users.createIndex({ username: 1 }, { unique: true });
db.users.createIndex({ email: 1 }, { sparse: true });
db.questions.createIndex({ difficulty: 1 });
db.questions.createIndex({ topic: 1 });
db.match_history.createIndex({ "players.userId": 1 });
db.match_history.createIndex({ createdAt: -1 });

// Payments & subscriptions
db.payments.createIndex({ order_id: 1 }, { unique: true });
db.payments.createIndex({ user_id: 1 });
db.subscriptions.createIndex({ user_id: 1 });
db.subscriptions.createIndex({ expires_at: 1 });

// Device tokens index — fast lookup by user_id, unique so each user has one token
db.device_tokens.createIndex({ user_id: 1 }, { unique: true });

// Referral system indexes
// sparse: true means documents WITHOUT referral_code (old users before the system)
// are not indexed, so the unique constraint doesn't reject them.
db.users.createIndex({ referral_code: 1 }, { unique: true, sparse: true });

// referrals collection: fast lookup by referrer (for /referral/history)
// and unique constraint on referee (each user can only be referred once).
db.referrals.createIndex({ referrer_id: 1 });
db.referrals.createIndex({ referee_id: 1 }, { unique: true });

// Tournament indexes
db.tournaments.createIndex({ status: 1, starts_at: 1 });
db.tournaments.createIndex({ "participants.user_id": 1 });

// ── Seed tournaments ─────────────────────────────────────
const now = new Date();
const in3Hours   = new Date(now.getTime() + 3 * 60 * 60 * 1000);
const tomorrow   = new Date(now.getTime() + 24 * 60 * 60 * 1000);
const in3Days    = new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000);
const nextWeek   = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
const in10Days   = new Date(now.getTime() + 10 * 24 * 60 * 60 * 1000);
const yesterday  = new Date(now.getTime() - 24 * 60 * 60 * 1000);

db.tournaments.deleteMany({});
db.tournaments.insertMany([
  {
    name: "Today's Flash Cup",
    description: "A short burst tournament — 5 rounds, top 3 win big! Starts in 3 hours.",
    type: "flash",
    status: "upcoming",
    starts_at: in3Hours,
    ends_at: new Date(in3Hours.getTime() + 45 * 60 * 1000),
    max_participants: 30,
    entry_fee: 50,
    premium_only: false,
    prizes: { first: 500, second: 250, third: 100 },
    rounds: 5,
    difficulty: "easy",
    participants: [],
    created_at: now
  },
  {
    name: "Weekly Challenge",
    description: "Compete against the best players this week. Top 3 win coins!",
    type: "weekly",
    status: "upcoming",
    starts_at: tomorrow,
    ends_at: new Date(tomorrow.getTime() + 2 * 60 * 60 * 1000),
    max_participants: 50,
    entry_fee: 0,
    premium_only: true,
    prizes: { first: 1000, second: 500, third: 250 },
    rounds: 10,
    difficulty: "mixed",
    participants: [],
    created_at: now
  },
  {
    name: "Beginner's Blitz",
    description: "Easy questions, big fun. Perfect for new players — no entry fee!",
    type: "special",
    status: "upcoming",
    starts_at: in3Days,
    ends_at: new Date(in3Days.getTime() + 90 * 60 * 1000),
    max_participants: 100,
    entry_fee: 0,
    premium_only: false,
    prizes: { first: 300, second: 150, third: 75 },
    rounds: 8,
    difficulty: "easy",
    participants: [],
    created_at: now
  },
  {
    name: "Speed Demon Sprint",
    description: "10 hard questions, 15 seconds each. Only the fastest survive!",
    type: "special",
    status: "upcoming",
    starts_at: nextWeek,
    ends_at: new Date(nextWeek.getTime() + 1 * 60 * 60 * 1000),
    max_participants: 20,
    entry_fee: 100,
    premium_only: false,
    prizes: { first: 2000, second: 1000, third: 500 },
    rounds: 10,
    difficulty: "hard",
    participants: [],
    created_at: now
  },
  {
    name: "Grand Masters Invitational",
    description: "Elite PRO-only event. 15 rounds of the hardest questions — legends only.",
    type: "invitational",
    status: "upcoming",
    starts_at: in10Days,
    ends_at: new Date(in10Days.getTime() + 3 * 60 * 60 * 1000),
    max_participants: 16,
    entry_fee: 500,
    premium_only: true,
    prizes: { first: 5000, second: 2500, third: 1000 },
    rounds: 15,
    difficulty: "hard",
    participants: [],
    created_at: now
  },
  {
    name: "Last Week's Showdown",
    description: "The results are in! Check out who won.",
    type: "weekly",
    status: "completed",
    starts_at: yesterday,
    ends_at: new Date(yesterday.getTime() + 2 * 60 * 60 * 1000),
    max_participants: 50,
    entry_fee: 0,
    premium_only: true,
    prizes: { first: 1000, second: 500, third: 250 },
    rounds: 10,
    difficulty: "mixed",
    participants: [
      { user_id: "seed_alice", username: "alice", score: 1850, rank: 1 },
      { user_id: "seed_bob", username: "bob", score: 1720, rank: 2 },
      { user_id: "seed_charlie", username: "charlie", score: 1650, rank: 3 },
    ],
    winner: "seed_alice",
    created_at: new Date(yesterday.getTime() - 7 * 24 * 60 * 60 * 1000)
  }
]);

print("✓ 6 tournaments seeded (5 upcoming, 1 completed)");

print("✓ Indexes created:");
print("  users: username (unique), email (sparse), referral_code (unique sparse)");
print("  questions: difficulty, topic");
print("  match_history: players.userId, createdAt");
print("  payments: order_id (unique), user_id");
print("  subscriptions: user_id, expires_at");
print("  device_tokens: user_id (unique)");
print("  referrals: referrer_id, referee_id (unique)");

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