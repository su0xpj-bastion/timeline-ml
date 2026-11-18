// timeline-ml on a macOS agent labelled 'xcode'. Run `tml authorize` once on the agent (logged-in
// session) so the transcript gates run instead of skipping.
pipeline {
  agent { label 'xcode' }
  options { timestamps(); timeout(time: 60, unit: 'MINUTES') }
  stages {
    stage('Toolchain') { steps { sh 'sw_vers && swift --version' } }
    stage('Gates') { steps { sh 'scripts/ci/gates.sh' } }
  }
  post { always { archiveArtifacts allowEmptyArchive: true, artifacts: 'build/reports/**' } }
}
