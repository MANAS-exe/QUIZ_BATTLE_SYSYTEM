package middleware

import (
	"context"
	"log"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"quiz-battle/matchmaking/handlers"
)

// Methods that don't require authentication.
var publicMethods = map[string]bool{
	"/quiz.AuthService/Register": true,
	"/quiz.AuthService/Login":    true,
}

type contextKey string

const (
	UserIDKey   contextKey = "auth_user_id"
	UsernameKey contextKey = "auth_username"
)

// AuthUnaryInterceptor validates JWT tokens on gRPC unary calls.
func AuthUnaryInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (interface{}, error) {
	// Skip auth for public methods
	if publicMethods[info.FullMethod] {
		log.Printf("→ gRPC call (public): %s", info.FullMethod)
		return handler(ctx, req)
	}

	ctx, err := authenticate(ctx)
	if err != nil {
		return nil, err
	}

	log.Printf("→ gRPC call (authed as %s): %s", ctx.Value(UsernameKey), info.FullMethod)
	return handler(ctx, req)
}

// AuthStreamInterceptor validates JWT tokens on gRPC streaming calls.
func AuthStreamInterceptor(
	srv interface{},
	ss grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) error {
	// Skip auth for public methods
	if publicMethods[info.FullMethod] {
		log.Printf("→ gRPC stream (public): %s", info.FullMethod)
		return handler(srv, ss)
	}

	ctx, err := authenticate(ss.Context())
	if err != nil {
		return err
	}

	log.Printf("→ gRPC stream (authed as %s): %s", ctx.Value(UsernameKey), info.FullMethod)
	return handler(srv, &authenticatedStream{ss, ctx})
}

func authenticate(ctx context.Context) (context.Context, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing metadata")
	}

	vals := md.Get("authorization")
	if len(vals) == 0 {
		return nil, status.Error(codes.Unauthenticated, "missing authorization token")
	}

	token := vals[0]
	// Strip "Bearer " prefix if present
	token = strings.TrimPrefix(token, "Bearer ")

	userID, username, err := handlers.ValidateToken(token)
	if err != nil {
		return nil, status.Errorf(codes.Unauthenticated, "invalid token: %v", err)
	}

	ctx = context.WithValue(ctx, UserIDKey, userID)
	ctx = context.WithValue(ctx, UsernameKey, username)
	return ctx, nil
}

// authenticatedStream wraps a ServerStream with an authenticated context.
type authenticatedStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *authenticatedStream) Context() context.Context {
	return s.ctx
}
