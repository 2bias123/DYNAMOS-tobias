package lib

import (
	"context"
	"io"
	"sync"
	"time"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
)

type MessageHandlerFunc func(ctx context.Context, grpcMsg *pb.SideCarMessage) error

func StartConsumingWithRetry(serviceName string, c pb.RabbitMQClient, queueName string, handler MessageHandlerFunc, maxRetries int, waitTime time.Duration, receiveMutex *sync.Mutex) {
	logger.Sugar().Info("Starting to consume with retry (StartConsumingWithRetry)")
	for i := range maxRetries {
		err := startConsuming(serviceName, c, queueName, handler, receiveMutex)
		if err == nil {
			return
		}

		logger.Sugar().Errorf("Failed to start consuming (attempt %d/%d): %v", i+1, maxRetries, err)

		// Wait for some time before retrying
		time.Sleep(waitTime)
	}
}

func startConsuming(serviceName string, c pb.RabbitMQClient, from string, handler MessageHandlerFunc, receiveMutex *sync.Mutex) error {
	logger.Sugar().Info("Starting to consume (startConsuming)")
	ctx := context.Background()
	stream, err := c.Consume(ctx, &pb.ConsumeRequest{QueueName: from, AutoAck: true})
	if err != nil {
		logger.Sugar().Errorf("Error on consume: %v", err)
		return err
	}

	for {
		receiveMutex.Lock()
		grpcMsg, err := stream.Recv()
		receiveMutex.Unlock()

		if err == io.EOF {
			logger.Sugar().Warnw("Stream has ended", "error", err)
			return nil
		}

		if err != nil {
			logger.Sugar().Warnw("Stream Recv failed; letting outer retry reconnect", "error", err)
			return err
		}

		if err := handler(ctx, grpcMsg); err != nil {
			logger.Sugar().Errorw("Handler failed on message; consumer continues", "error", err)
		}
	}
}
