module quiz-battle/matchmaking

go 1.25.0

require (
	github.com/gomodule/redigo v1.9.2
	github.com/google/uuid v1.6.0
	github.com/rabbitmq/amqp091-go v1.9.0
	github.com/yourorg/quiz-battle/proto/quiz v0.0.0
	go.mongodb.org/mongo-driver v1.17.9
	google.golang.org/grpc v1.68.0
)

replace github.com/yourorg/quiz-battle/proto/quiz => ../proto

require (
	github.com/cenkalti/backoff/v4 v4.1.1 // indirect
	github.com/desertbit/timer v0.0.0-20180107155436-c41aec40b27f // indirect
	github.com/golang-jwt/jwt/v5 v5.3.1 // indirect
	github.com/golang/snappy v0.0.4 // indirect
	github.com/improbable-eng/grpc-web v0.15.0 // indirect
	github.com/klauspost/compress v1.16.7 // indirect
	github.com/montanaflynn/stats v0.7.1 // indirect
	github.com/rs/cors v1.7.0 // indirect
	github.com/xdg-go/pbkdf2 v1.0.0 // indirect
	github.com/xdg-go/scram v1.1.2 // indirect
	github.com/xdg-go/stringprep v1.0.4 // indirect
	github.com/youmark/pkcs8 v0.0.0-20240726163527-a2c0da244d78 // indirect
	golang.org/x/crypto v0.49.0 // indirect
	golang.org/x/net v0.51.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.42.0 // indirect
	golang.org/x/text v0.35.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240903143218-8af14fe29dc1 // indirect
	google.golang.org/protobuf v1.36.0 // indirect
	nhooyr.io/websocket v1.8.6 // indirect
)
