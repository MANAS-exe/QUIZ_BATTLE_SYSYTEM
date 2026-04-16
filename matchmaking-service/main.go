package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/improbable-eng/grpc-web/go/grpcweb"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"quiz-battle/matchmaking/handlers"
	"quiz-battle/matchmaking/rabbitmq"
	rdb "quiz-battle/matchmaking/redis"
	"quiz-battle/shared/middleware"
)

func main() {
	grpcAddr := getEnv("GRPC_ADDR", ":50051")
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	amqpURL := getEnv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")

	// ── Redis ─────────────────────────────────────────────────
	redisPool := rdb.NewPool(redisAddr)
	defer redisPool.Close()

	conn := redisPool.Get()
	if _, err := conn.Do("PING"); err != nil {
		log.Fatalf("❌ Cannot connect to Redis at %s: %v", redisAddr, err)
	}
	conn.Close()
	log.Printf("✅ Redis connected: %s", redisAddr)

	// ── RabbitMQ ──────────────────────────────────────────────
	publisher, err := rabbitmq.NewPublisher(amqpURL)
	if err != nil {
		log.Fatalf("❌ Cannot connect to RabbitMQ at %s: %v", amqpURL, err)
	}
	defer publisher.Close()
	log.Printf("✅ RabbitMQ connected: %s", amqpURL)

	// ── gRPC server ───────────────────────────────────────────
	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("❌ Failed to listen on %s: %v", grpcAddr, err)
	}

	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(middleware.AuthUnaryInterceptor),
		grpc.StreamInterceptor(middleware.AuthStreamInterceptor),
	)

	// ── MongoDB ───────────────────────────────────────────────
	mongoURI := getEnv("MONGO_URI", "mongodb://localhost:27017")
	mongoClient, err := mongo.Connect(context.Background(), options.Client().ApplyURI(mongoURI))
	if err != nil {
		log.Fatalf("❌ Cannot connect to MongoDB at %s: %v", mongoURI, err)
	}
	defer mongoClient.Disconnect(context.Background()) //nolint:errcheck
	log.Printf("✅ MongoDB connected: %s", mongoURI)

	mongoDB := mongoClient.Database("quizdb")

	// Register auth handler
	authHandler := handlers.NewAuthHandler(mongoDB)
	authHandler.SetRedisPool(redisPool)
	authHandler.RegisterService(grpcServer)

	// Register matchmaking handler
	matchHandler := handlers.NewMatchmakingHandler(redisPool, publisher)
	matchHandler.SetMongoDB(mongoDB)
	matchHandler.Register(grpcServer)

	reflection.Register(grpcServer)

	// ── gRPC-Web HTTP server (for Flutter Web / Chrome) ──────
	// Also mounts REST endpoints for OAuth flows that don't fit gRPC:
	//   POST /auth/google  — Google Sign-In ID token verification + user upsert
	grpcWebAddr := getEnv("GRPC_WEB_ADDR", ":8080")
	wrappedGrpc := grpcweb.WrapServer(grpcServer,
		grpcweb.WithOriginFunc(func(origin string) bool { return true }),
	)

	googleAuthHandler := handlers.NewGoogleAuthHandler(mongoDB)
	googleAuthHandler.SetRedisPool(redisPool)
	leaderboardHandler := handlers.NewLeaderboardHTTPHandler(mongoDB)
	referralHandler := handlers.NewReferralHandler(mongoDB)
	referralHandler.SetRedisPool(redisPool)
	deviceTokenHandler := handlers.NewDeviceTokenHandler(mongoDB)
	userStatsHandler := handlers.NewUserStatsHandler(mongoDB)
	tournamentHandler := handlers.NewTournamentHandler(mongoDB)
	changePasswordHandler := handlers.NewChangePasswordHandler(mongoDB)

	mux := http.NewServeMux()
	mux.Handle("/leaderboard", leaderboardHandler)
	mux.HandleFunc("/auth/google", func(w http.ResponseWriter, r *http.Request) {
		// CORS preflight
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		googleAuthHandler.ServeHTTP(w, r)
	})

	// ── Referral endpoints ────────────────────────────────────────
	// All require JWT authentication (Authorization: Bearer <token>).
	// OPTIONS preflight is handled inline for Flutter Web compatibility.
	mux.HandleFunc("/referral/code", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		referralHandler.GetCode(w, r)
	})
	mux.HandleFunc("/referral/apply", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		referralHandler.ApplyCode(w, r)
	})
	mux.HandleFunc("/referral/claim", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		referralHandler.ClaimRewards(w, r)
	})
	mux.HandleFunc("/referral/history", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		referralHandler.History(w, r)
	})

	// ── Device token registration ─────────────────────────────────
	// POST /device/token — stores FCM token for the authenticated user.
	mux.HandleFunc("/device/token", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		deviceTokenHandler.ServeHTTP(w, r)
	})

	// ── Tournament endpoints ─────────────────────────────────────
	mux.HandleFunc("/tournament/list", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		tournamentHandler.List(w, r)
	})
	mux.HandleFunc("/tournament/detail", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		tournamentHandler.Detail(w, r)
	})
	mux.HandleFunc("/tournament/join", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		tournamentHandler.Join(w, r)
	})

	// ── User stats endpoint ──────────────────────────────────────
	// GET /user/stats — returns persistent stats (played, won, coins, streak) from MongoDB.
	mux.HandleFunc("/user/stats", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		userStatsHandler.ServeHTTP(w, r)
	})

	// ── Change password endpoint ─────────────────────────────────
	// POST /user/change-password — requires JWT, updates password_hash in MongoDB.
	mux.HandleFunc("/user/change-password", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		changePasswordHandler.ServeHTTP(w, r)
	})

	go func() {
		log.Printf("🌐 HTTP server listening on %s (gRPC-Web + REST auth)", grpcWebAddr)
		if err := http.ListenAndServe(grpcWebAddr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if wrappedGrpc.IsGrpcWebRequest(r) || wrappedGrpc.IsAcceptableGrpcCorsRequest(r) {
				wrappedGrpc.ServeHTTP(w, r)
				return
			}
			mux.ServeHTTP(w, r)
		})); err != nil {
			log.Printf("❌ HTTP server error: %v", err)
		}
	}()

	log.Printf("🚀 Matchmaking gRPC server listening on %s", grpcAddr)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("❌ gRPC server error: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
