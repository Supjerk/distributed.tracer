#!/usr/bin/env bash

[ $# -ne 6 ] && { echo "Usage: $0 [binary-id] [runs] [cores] [benchmark-runs] [(no)rebuild] [genetic]"; exit 1; }
read binary_id runs cores benchmark_runs rebuild  genetic<<<$@

DRIVER_DIR=$(pwd)
GRIVER=$DRIVER_DIR/river.genetic
TRACER_NODE=$DRIVER_DIR/tracer.node
PROCESS_MANAGER=$DRIVER_DIR/process.manager
NODE_RIVER=$TRACER_NODE/deps/node-river
FUZZER_PATH=$TRACER_NODE/$binary_id/fuzzer

CONFIG_PATH=$(readlink -f config.json)

DB_NAME="tests_$binary_id"

ID_LOGS_DIR=$(pwd)/$binary_id
LOGS_DIR=$ID_LOGS_DIR/logs
GRIVER_LOG_FILE=$LOGS_DIR/griver.log
RESULTS_DIR=$ID_LOGS_DIR/results

MONGO_URL="mongodb://worker:workwork@10.18.0.32:27017/test?authSource=admin"

NO_TESTCASES=0

start_tracer() {
  # start the desired number of node river running processes
  echo -e "\033[0;32m[DRIVER] Starting $cores processes of node RIVER ..."; echo -e "\033[0m"
  cd $PROCESS_MANAGER
  node ./pmcli.js start tracer.node $binary_id $cores

  cd -
}

stop_tracer() {
  echo -e "\033[0;32m[DRIVER] Stopping processes of node RIVER ..."; echo -e "\033[0m"
  cd $PROCESS_MANAGER

  node ./pmcli.js stop tracer.node $binary_id
  cd -
}

stop_fuzzers() {
  echo -e "\033[0;32m[DRIVER] Stopping fuzzers ..."; echo -e "\033[0m"
  cd $PROCESS_MANAGER
  node ./pmcli.js stop basic.fuzzer $binary_id
  node ./pmcli.js stop fast.fuzzer $binary_id
  node ./pmcli.js stop eval.fuzzer $binary_id
  cd -
}

cleanup() {
  # clean the DRIVER build and stop node
  echo -e "\033[0;32m[DRIVER] Cleaning DRIVER environment ..."; echo -e "\033[0m"
  stop_tracer
  stop_fuzzers
  if [ "$genetic" == "genetic" ]; then
    killall -9 python3
  fi

  if [ "$rebuild" == "rebuild" ]; then
    cd $TRACER_NODE && rm -rf build && npm install
    cd $TRACER_NODE && rm -rf node_modules/node-river/ && npm install
  fi

  services="mongod.service rabbitmq-server.service mongo.rabbit.bridge.service"

  for s in $services; do
    active=$(sudo systemctl status $s | grep "active (running)");
    if [ "$active" == "" ]; then
      sudo systemctl restart $s;
    fi
  done

  # drop $DB_NAME mongo db
  mongo $MONGO_URL --eval "db.$DB_NAME.drop()"

  # purge rabbit queues
  sudo rabbitmqctl purge_queue driver.newtests.$binary_id
  sudo rabbitmqctl purge_queue driver.tracedtests.$binary_id

  # remove results dumped to disk
  if [ -d $RESULTS_DIR ]; then
    rm -rf $RESULTS_DIR
  fi
}

sigint_handler()
{
  echo -e "\033[0;32m[DRIVER] Received SIGINT. Cleaning DRIVER environment ..."; echo -e "\033[0m"
  evaluate_new_corpus

  sudo systemctl stop mongo.rabbit.bridge
  stop_tracer
  stop_fuzzers
  killall -9 python3

  exit 1
}

generate_testcases() {
  # generate testcases
  echo -e "\033[0;32m[DRIVER] Generating testcases using $FUZZER_PATH ..."; echo -e "\033[0m"

  while true; do
    if [ ! -f $FUZZER_PATH ]; then
      sleep 1
      continue
    fi
    busy=$(lsof $FUZZER_PATH 2> /dev/null )
    if [ "$busy" == "" ]; then
      break
    fi
    sleep 1
  done

  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
  if [ ! -d "$RESULTS_DIR/results" ]; then
    mkdir -p "$RESULTS_DIR/results"
  fi

  cd $PROCESS_MANAGER
  node ./pmcli.js start fast.fuzzer $binary_id 1
  cd -

  echo -e "\033[0;32m[DRIVER] Started fuzzer to generate interesting testcases for genetic river ..."; echo -e "\033[0m"
}

griver_environment() {
  ## genetic alg setup
  ## TODO get rid of this stuff
  export SPARK_HOME=/data/spark/spark-2.0.1-bin-hadoop2.7
  export PYSPARK_PYTHON=python3
  export PYSPARK_DRIVER_PYTHON=python3
  export PYTHONPATH=$SPARK_HOME/python:$SPARK_HOME/python/lib/py4j-0.10.3-src.zip
  export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk-amd64
  export SPARK_WORKER_DIR=/data/spark_worker_dir
  export SPARK_EXECUTOR_INSTANCES=2
  export SCALA_HOME=/usr/share/scala/lib
  export SPARK_LOCAL_IP=10.18.0.32

  export PYTHONUNBUFFERED=1
  export SIMPLETRACERLOGSPATH=$RESULTS_DIR
  #export LD_LIBRARY_PATH=/data/simpletracer/build-river-tools/lib
  #export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/simpletracer/river.sdk/lin/lib
  #export SIMPLETRACERPATH=/data/simpletracer/build-river-tools/bin/simple_tracer
}

start_griver() {
  echo -e "\033[0;32m[DRIVER] Starting river genetic for $binary_id executable..."; echo -e "\033[0m"
  cd $GRIVER
  griver_environment
  ( python3 ./genetic_code/main.py --testsFolderCount 10 --numTasks 1 \
      --isParallelExecution 0 --populationSize 10 --numberOfIterations 10 \
      --config $CONFIG_PATH --driver 1  --isDebugEnabled 1 \
      --executableId $binary_id > $GRIVER_LOG_FILE 2>&1 &)
}

wait_for_termination() {
  while true; do
    left=$( mongo $MONGO_URL --eval "db.$DB_NAME.find({state : \"traced\"}).count()" 2> /dev/null | tail -n1; \
      exitcode=${PIPESTATUS[0]}; if test $exitcode -ne 0; then echo -n -1; fi )
    if [ $left -lt 0 ]; then
      echo -e "\033[0;32m[DRIVER] Mongo could not connect. Exiting...."; echo -e "\033[0m"
      sleep 120
      break
    fi
    cd $PROCESS_MANAGER
    fuzzers_running=$(node ./pmcli.js status fast.fuzzer | grep "fast.fuzzer:" | awk '{print $2}')
    cd -
    if [ $fuzzers_running == 0 ]; then
      echo -e "\033[0;32m[DRIVER] Source fuzzer exited. Exiting...."; echo -e "\033[0m"
      break
    fi
    sleep 20 #todo fix this
    echo "pulse: Tracing progress: found [$left] testcases traced."
  done
}


evaluate_new_corpus() {
  ## Driver is a system that uses testcases in order to generate new ones.
  ## First set of testcases is generated by a raw fuzzer.
  ## These testcases are traced by river and all traces go in mongo.
  ## A special component will retrieve all traced testcases from mongo
  ##  and will generate new testcases based on the distribution of
  ##  cold spots and hot spots in traced testcases.
  ##
  ## This function evaluates the new corpus generated in $RESULTS_DIR
  ## The result is a set of (testcaseId, coverage) dumped in csv

  ## run all testcases and do not add anything new

  cd $PROCESS_MANAGER
  node ./pmcli.js start eval.fuzzer $binary_id 1
  cd -

  cd $PROCESS_MANAGER
  while true; do
    fuzzers_running=$(node ./pmcli.js status eval.fuzzer | grep "eval.fuzzer:" | awk '{print $2}')
    if [ $fuzzers_running == 0 ]; then
      break
    fi
    sleep 5
  done
  cd -
}

main() {

  [ ! -d $CORPUS_TESTER ] && { echo "Wrong $0 script call. Please chdir to distributed.tracer"; exit 1; }

  if [ ! -d $LOGS_DIR ]; then
    mkdir -p $LOGS_DIR
  fi

  echo
  echo "River running $benchmark_runs benchmarks on http-parser"
  echo "======================================================="

  for i in $(seq $benchmark_runs); do
    cleanup
    start_tracer
    if [ "$genetic" == "genetic" ]; then
      start_griver
    fi
    generate_testcases
    wait_for_termination
    evaluate_new_corpus

    ## cleanup
    stop_tracer
    stop_fuzzers
    killall -9 python3
    sudo systemctl stop mongo.rabbit.bridge

  done
}

trap sigint_handler SIGINT
main
