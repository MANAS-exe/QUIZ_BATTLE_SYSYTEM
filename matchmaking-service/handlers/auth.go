package handlers

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"golang.org/x/crypto/bcrypt"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	quiz "github.com/yourorg/quiz-battle/proto/quiz"
)

// JWTSecret used to sign tokens. In production, load from env/secret manager.
var JWTSecret = []byte("quiz-battle-secret-key-change-in-prod")

const tokenExpiry = 24 * time.Hour

// User document stored in MongoDB.
type User struct {
	ID           primitive.ObjectID `bson:"_id,omitempty"`
	Username     string             `bson:"username"`
	PasswordHash string             `bson:"password_hash"`
	Rating       int                `bson:"rating"`
	CreatedAt    time.Time          `bson:"created_at"`
}

// AuthHandler implements quiz.AuthServiceServer.
type AuthHandler struct {
	quiz.UnimplementedAuthServiceServer
	users *mongo.Collection
}

func NewAuthHandler(mongoDB *mongo.Database) *AuthHandler {
	return &AuthHandler{
		users: mongoDB.Collection("users"),
	}
}

func (h *AuthHandler) RegisterService(s *grpc.Server) {
	quiz.RegisterAuthServiceServer(s, h)
	log.Println("✅ AuthService registered")
}

// ── Register ─────────────────────────────────────────────────

func (h *AuthHandler) Register(ctx context.Context, req *quiz.AuthRequest) (*quiz.AuthResponse, error) {
	if req.Username == "" || req.Password == "" {
		return nil, status.Error(codes.InvalidArgument, "username and password are required")
	}
	if len(req.Username) < 3 {
		return nil, status.Error(codes.InvalidArgument, "username must be at least 3 characters")
	}
	if len(req.Password) < 4 {
		return nil, status.Error(codes.InvalidArgument, "password must be at least 4 characters")
	}

	// Check if username already taken
	var existing User
	err := h.users.FindOne(ctx, bson.M{"username": req.Username}).Decode(&existing)
	if err == nil {
		return &quiz.AuthResponse{
			Success: false,
			Message: "Username already taken",
		}, nil
	}
	if err != mongo.ErrNoDocuments {
		return nil, status.Errorf(codes.Internal, "db lookup: %v", err)
	}

	// Hash password
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "hash password: %v", err)
	}

	user := User{
		Username:     req.Username,
		PasswordHash: string(hash),
		Rating:       1000,
		CreatedAt:    time.Now(),
	}

	result, err := h.users.InsertOne(ctx, user)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "insert user: %v", err)
	}

	userID := result.InsertedID.(primitive.ObjectID).Hex()
	token, err := generateToken(userID, req.Username)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "generate token: %v", err)
	}

	log.Printf("✅ New user registered: %s (%s)", req.Username, userID)

	return &quiz.AuthResponse{
		Success:  true,
		Token:    token,
		UserId:   userID,
		Username: req.Username,
		Rating:   1000,
		Message:  "Registration successful",
	}, nil
}

// ── Login ────────────────────────────────────────────────────

func (h *AuthHandler) Login(ctx context.Context, req *quiz.AuthRequest) (*quiz.AuthResponse, error) {
	if req.Username == "" || req.Password == "" {
		return nil, status.Error(codes.InvalidArgument, "username and password are required")
	}

	var user User
	err := h.users.FindOne(ctx, bson.M{"username": req.Username}).Decode(&user)
	if err == mongo.ErrNoDocuments {
		return &quiz.AuthResponse{
			Success: false,
			Message: "Invalid username or password",
		}, nil
	}
	if err != nil {
		return nil, status.Errorf(codes.Internal, "db lookup: %v", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		return &quiz.AuthResponse{
			Success: false,
			Message: "Invalid username or password",
		}, nil
	}

	userID := user.ID.Hex()
	token, err := generateToken(userID, user.Username)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "generate token: %v", err)
	}

	log.Printf("✅ User logged in: %s (%s)", user.Username, userID)

	return &quiz.AuthResponse{
		Success:  true,
		Token:    token,
		UserId:   userID,
		Username: user.Username,
		Rating:   int32(user.Rating),
		Message:  "Login successful",
	}, nil
}

// ── JWT helpers ──────────────────────────────────────────────

func generateToken(userID, username string) (string, error) {
	claims := jwt.MapClaims{
		"user_id":  userID,
		"username": username,
		"exp":      time.Now().Add(tokenExpiry).Unix(),
		"iat":      time.Now().Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(JWTSecret)
}

// ValidateToken parses and validates a JWT, returning (userID, username, error).
func ValidateToken(tokenStr string) (string, string, error) {
	token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return JWTSecret, nil
	})
	if err != nil {
		return "", "", err
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || !token.Valid {
		return "", "", fmt.Errorf("invalid token claims")
	}

	userID, _ := claims["user_id"].(string)
	username, _ := claims["username"].(string)
	if userID == "" {
		return "", "", fmt.Errorf("missing user_id in token")
	}

	return userID, username, nil
}
