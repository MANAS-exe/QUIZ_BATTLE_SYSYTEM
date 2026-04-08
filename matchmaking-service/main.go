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
	"quiz-battle/matchmaking/middleware"
	"quiz-battle/matchmaking/rabbitmq"
	rdb "quiz-battle/matchmaking/redis"
)

func main() {
	// ── Config (env vars with sensible defaults) ──────────────
	grpcAddr  := getEnv("GRPC_ADDR",     ":50051")
	redisAddr := getEnv("REDIS_ADDR",    "localhost:6379")
	amqpURL   := getEnv("RABBITMQ_URL",  "amqp://guest:guest@localhost:5672/")

	// ── Redis ─────────────────────────────────────────────────
	redisPool := rdb.NewPool(redisAddr)
	defer redisPool.Close()

	// Ping Redis to confirm connection on startup
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
	authHandler.RegisterService(grpcServer)

	// Register matchmaking handler
	matchHandler := handlers.NewMatchmakingHandler(redisPool, mongoDB, publisher)
	matchHandler.Register(grpcServer)

	// Register quiz handler (game rounds + answer submission)
	quizHandler := handlers.NewQuizServiceHandler(redisPool, mongoDB, publisher)
	quizHandler.Register(grpcServer)

	// Enable gRPC reflection (useful for tools like grpcurl / Postman)
	reflection.Register(grpcServer)

	// ── gRPC-Web HTTP server (for Flutter Web / Chrome) ──────
	// Wraps the gRPC server with a grpc-web handler so browsers can call it.
	// Flutter Web uses GrpcWebClientChannel on port 8080.
	// Native (iOS/Android/macOS) continues to use port 50051 directly.
	grpcWebAddr := getEnv("GRPC_WEB_ADDR", ":8080")
	wrappedGrpc := grpcweb.WrapServer(grpcServer,
		grpcweb.WithOriginFunc(func(origin string) bool { return true }), // allow all origins in dev
	)
	go func() {
		log.Printf("🌐 gRPC-Web server listening on %s", grpcWebAddr)
		if err := http.ListenAndServe(grpcWebAddr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if wrappedGrpc.IsGrpcWebRequest(r) || wrappedGrpc.IsAcceptableGrpcCorsRequest(r) {
				wrappedGrpc.ServeHTTP(w, r)
				return
			}
			http.NotFound(w, r)
		})); err != nil {
			log.Printf("❌ gRPC-Web server error: %v", err)
		}
	}()

	// ── Answer consumer ───────────────────────────────────────
	consumer, err := rabbitmq.NewConsumer(amqpURL, redisPool, mongoDB)
	if err != nil {
		log.Fatalf("❌ Cannot start answer consumer: %v", err)
	}
	defer consumer.Close()

	// Run consumer in the background — processes answer.submitted events
	go func() {
		if err := consumer.Start(context.Background()); err != nil {
			log.Printf("❌ Consumer stopped: %v", err)
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