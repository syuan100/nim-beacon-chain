pipeline {
  /* By parametrizing this we can run the same Jenkinsfile or different platforms */
  agent { label getAgentLabel() }

  parameters {
    string(
      name: 'AGENT_LABEL',
      description: 'Label for targetted CI slave host: linux/macos'
    )
  }

  options {
    timestamps()
    /* Prevent Jenkins jobs from running forever */
    timeout(time: 60, unit: 'MINUTES')
    /* Limit builds retained */
    buildDiscarder(logRotator(
      numToKeepStr: '10',
      daysToKeepStr: '30',
      artifactNumToKeepStr: '10',
    ))
  }

  environment {
    NPROC = Runtime.getRuntime().availableProcessors()
    MAKEFLAGS = "-j${env.NPROC}"
  }

  stages {
    stage('Clone') {
      steps {
        checkout scm
        sh 'echo "$MAKEFLAGS"'
        /* we need to update the submodules before caching kicks in */
        sh 'git submodule update --init --recursive'
      }
    }

    stage('Build') {
      steps {
        cache(maxCacheSize: 250, caches: [
          [ $class: 'ArbitraryFileCache',
            includes: '**/*',
            path: "${WORKSPACE}/vendor/nimbus-build-system/vendor/Nim/bin" ],
          [ $class: 'ArbitraryFileCache',
            includes: '**/*',
            path: "${WORKSPACE}/jsonTestsCache" ],
        ]) {
          /* to allow a newer Nim version to be detected */
          sh 'make update'
          /* to allow the following parallel stages */
          sh 'make deps'
          sh 'V=1 ./scripts/setup_official_tests.sh jsonTestsCache'
        }
      }
    }

    stage('Tests') {
      parallel {
        stage('Tools') {
          steps {
            sh 'make'
            sh 'make beacon_node LOG_LEVEL=TRACE NIMFLAGS="-d:testnet_servers_image"'
          }
        }
        stage('Test suite') {
          steps {
            sh 'make test DISABLE_TEST_FIXTURES_SCRIPT=1'
          }
        }
      }
    }

    stage("testnet0 finalization") {
      when { expression { env.NODE_NAME ==~ /linux.*/ } }
      steps { script {
        launchLocalTestnet(testnetNum: 0, timeout: 10)
      } }
    }
    stage("testnet1 finalization") {
      when { expression { env.NODE_NAME ==~ /linux.*/ } }
      steps { script {
        launchLocalTestnet(testnetNum: 1, timeout: 40)
      } }
    }
  }
  post {
    always {
      cleanWs(
        disableDeferredWipeout: true,
        deleteDirs: true
      )
    }
  }
}

def getAgentLabel() {
    if (params.AGENT_LABEL) {
        return params.AGENT_LABEL
    } else {
        def tokens = env.JOB_NAME.split('/')
        def jobPath = tokens.take(tokens.size() - 1)
        if (jobPath.contains('linux')) {
            return 'linux'
        } else if (jobPath.contains('macos')) {
            return 'macos'
        }
    }
    throw new Exception('No agent provided or found in path!')
}

def launchLocalTestnet(Map params=[:]) {
  /* EXECUTOR_NUMBER will be 0 or 1, since we have 2 executors per node */
  def listenPort = 9000 + (env.EXECUTOR_NUMBER.toInteger() * 100)
  def metricsPort = 8008 + (env.EXECUTOR_NUMBER.toInteger() * 100)
  def flags = [
    "--nodes 4",
    "--log-level INFO",
    "--disable-htop",
    "--data-dir local_testnet0_data",
    "--base-port ${listenPort}",
    "--base-metrics-port ${metricsPort}",
    "-- --verify-finalization --stop-at-epoch=5"
  ]

  try {
    timeout(time: params.timeout, unit: 'MINUTES') {
      sh "./scripts/launch_local_testnet.sh --testnet ${params.testnetNum} ${flags.join(' ')}"
    }
  } catch(ex) {
    println("Failed the launch of local testnet${params.testnetNum}")
    println(ex.toString());
  } finally {
    /* Archive test results regardless of outcome */
    def dirName = "local_testnet${params.testnetNum}_data"
    sh "tar cjf ${dirName}.tar.bz2 ${dirName}/*.txt"
    archiveArtifacts("${dirName}.tar.bz2")
  }
}
