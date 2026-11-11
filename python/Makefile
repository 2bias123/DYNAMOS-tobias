SHELL := /usr/bin/env bash
# took out to test: sql-query ml-differential-privacy ml-model-training ml-merge-datasets ml-anonymize-dataset ml-synthetic-dataset-generation
targets := test-microservice vfl-train-model vfl-train vfl-train-demo vfl-train-model-demo anonymize-test differential-p-test aggregate-demo
datasets := "../configuration/datasets/"
branch_name := $(shell git rev-parse --abbrev-ref HEAD)
dockerhub_account := tamjiyan
PUSH ?= 0  # <-- Add this line; default is 1 (do push)

.PHONY: proto $(targets) dynamos

proto:
	@python3 -m grpc_tools.protoc -I../proto-files --python_out=./dynamos-python-lib/protofiles --grpc_python_out=./dynamos-python-lib/protofiles ../proto-files/*.proto

dynamos:
	(cd ./dynamos-python-lib && python3 setup.py bdist_wheel)

# Set PYTHONPATH to protofiles directory for includes to GRPC code to work
$(targets):
	cp Dockerfile ./$@

	# Build the wheel for the local package
	(cd ./dynamos-python-lib && python3 setup.py bdist_wheel)

	# Copy the wheel to the target directory
	cp ./dynamos-python-lib/dist/*.whl ./$@
	cp -r ./dynamos-python-lib/protofiles ./$@

    # create empty folder
	mkdir -p ./$@/data

	# Only for ml-merge-datasets, copy extra files to ./data
	if [ "$@" = "ml-merge-datasets" ]; then \
		mkdir -p ./$@/data; \
		cp ./datasets/yearly_weather.csv ./$@/data/; \
		cp ./datasets/yearly_building.csv ./$@/data/; \
	fi

	# Only for aggregate-demo, copy the client datasets to ./data
	# (from vfl-train-demo/data, the tracked copies; ./datasets is gitignored)
	if [ "$@" = "aggregate-demo" ]; then \
		mkdir -p ./$@/data; \
		cp ./vfl-train-demo/data/clientoneData.csv ./$@/data/; \
		cp ./vfl-train-demo/data/clienttwoData.csv ./$@/data/; \
		cp ./vfl-train-demo/data/clientthreeData.csv ./$@/data/; \
	fi

	@trap 'rm -f ./$@/Dockerfile; rm -rf ./$@/*.whl; rm -rf ./$@/datasets; rm -rf ./$@/protofiles' EXIT;  \
	WHEEL_NAME=$$(ls ./$@/*.whl); \
	BASE=$$(basename $$WHEEL_NAME); \
	docker build --build-arg NAME=$@ -t $(dockerhub_account)/$@:$(branch_name) --build-arg WHEEL_NAME=$$BASE -t $(dockerhub_account)/$@:latest ./$@/
	if [ "$(PUSH)" = "1" ]; then \
		docker push $(dockerhub_account)/$@:$(branch_name); \
		docker push $(dockerhub_account)/$@:latest; \
	fi
all: all $(targets)
