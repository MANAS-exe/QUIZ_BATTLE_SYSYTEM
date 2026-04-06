package main

import (
	"context"
	"log"
	"net"
	"os"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"quiz-battle/matchmaking/handlers"
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
		grpc.UnaryInterceptor(loggingInterceptor),
	)

	// Register matchmaking handler
	matchHandler := handlers.NewMatchmakingHandler(redisPool, publisher)
	matchHandler.Register(grpcServer)

	// Enable gRPC reflection (useful for tools like grpcurl / Postman)
	reflection.Register(grpcServer)

	log.Printf("🚀 Matchmaking gRPC server listening on %s", grpcAddr)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("❌ gRPC server error: %v", err)
	}
}

// loggingInterceptor logs every incoming unary RPC call
func loggingInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (interface{}, error) {
	log.Printf("→ gRPC call: %s", info.FullMethod)
	return handler(ctx, req)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}