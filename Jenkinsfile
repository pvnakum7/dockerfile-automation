// Jenkins pipeline: runs docker-update.sh directly on the Jenkins server, then email-sent-python.py.
// Agent needs: bash 4.3+, git, curl, jq, awk, sed, base64, python3 (3.8+). docker is optional (DOCKER_CHECK).
//
// Token credentials: map the ENVIRONMENT VARIABLE NAME used in the Token_Name column of config/repositories.csv
// (GIT_TOKEN, GIT_TOKEN2, ...) to the ID of a Jenkins "Secret text" credential. Only list credentials that exist.
def GIT_TOKEN_CREDENTIALS = [
    GIT_TOKEN : 'github-token-1',
    GIT_TOKEN2: 'github-token-2',
    // GIT_TOKEN3: 'github-token-3',
]

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 4, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
    }

    // triggers { cron('H 2 * * *') }   // uncomment for a nightly run

    parameters {
        string(name: 'REPOSITORIES', defaultValue: '', description: 'Repo_Name values to process, comma separated. Empty = every row of config/repositories.csv')
        choice(name: 'STRATEGY', choices: ['both', 'same_major', 'new_major'], description: 'Which upgrades to evaluate')
        booleanParam(name: 'DRY_RUN', defaultValue: true, description: 'Report only - never modify a Dockerfile')
        booleanParam(name: 'COMMIT_PUSH', defaultValue: false, description: 'Commit to a new branch and push (needs DRY_RUN=false and write-capable tokens)')
        booleanParam(name: 'CREATE_PR', defaultValue: false, description: 'Also open a pull request (needs DRY_RUN=false)')
        booleanParam(name: 'TEST_MODE', defaultValue: true, description: 'Run everything but do NOT push, do NOT open PRs and do NOT send e-mails')
        booleanParam(name: 'SEND_EMAIL', defaultValue: true, description: 'Send the report e-mails (in TEST_MODE the mailer only prints what it would send)')
    }

    environment {
        STRATEGY    = "${params.STRATEGY}"
        DRY_RUN     = "${params.DRY_RUN}"
        COMMIT_PUSH = "${params.COMMIT_PUSH && !params.DRY_RUN}"
        CREATE_PR   = "${params.CREATE_PR && !params.DRY_RUN}"
        TEST_MODE   = "${params.TEST_MODE}"
        REPOSITORIES = "${params.REPOSITORIES}"
    }

    stages {
        stage('Validate') {
            steps {
                script {
                    if (params.REPOSITORIES && !(params.REPOSITORIES ==~ /^[A-Za-z0-9._, -]*$/)) {
                        error 'REPOSITORIES contains unsupported characters'
                    }
                }
                sh '''
                    set -eu
                    missing=""
                    for c in bash git curl jq awk sed base64 python3; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
                    if [ -n "$missing" ]; then echo "Missing tools on this agent:$missing" >&2; exit 2; fi
                    bash -c 'test "${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}" -ge 43' || { echo "bash 4.3+ required" >&2; exit 2; }
                    test -f config/repositories.csv
                    chmod +x docker-update.sh
                    rm -rf repos reports && mkdir -p repos reports
                '''
            }
        }

        stage('Clone and update Docker images') {
            steps {
                script {
                    def bindings = GIT_TOKEN_CREDENTIALS.collect { envName, credId -> string(credentialsId: credId, variable: envName) }
                    withCredentials(bindings) {
                        // exit 1 = some repositories failed -> UNSTABLE (reports are still produced); anything else > 0 = FAILED
                        def rc = sh(returnStatus: true, script: './docker-update.sh')
                        if (rc == 1) {
                            unstable('Some repositories failed - see the per-repository reports in reports/')
                        } else if (rc != 0) {
                            error "docker-update.sh failed or is misconfigured (exit code ${rc})"
                        }
                    }
                }
            }
        }

        stage('Send e-mail reports') {
            when { expression { params.SEND_EMAIL } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'smtp-credentials', usernameVariable: 'SMTP_USERNAME', passwordVariable: 'SMTP_PASSWORD')]) {
                    withEnv(["SMTP_SERVER=${env.SMTP_SERVER ?: 'smtp.example.com'}",
                             "SMTP_PORT=${env.SMTP_PORT ?: '587'}",
                             "EMAIL_FROM=${env.EMAIL_FROM ?: 'devops-automation@example.com'}"]) {
                        script {
                            def rc = sh(returnStatus: true, script: 'python3 email-sent-python.py')
                            if (rc == 1) { unstable('One or more e-mails could not be sent') }
                            else if (rc != 0) { error "email-sent-python.py failed (exit code ${rc})" }
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/*.txt', allowEmptyArchive: true, fingerprint: true
        }
        cleanup {
            // the clones are only needed during the run; remove the code so nothing stays on the Jenkins server
            sh 'rm -rf repos && mkdir -p repos'
        }
    }
}
