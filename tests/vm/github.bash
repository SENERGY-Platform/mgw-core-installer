# Copyright (c) 2026 InfAI (CC SES)

# Starts and stops the caching GitHub mock (github_mock.py) for a test file. The cache stays on the VM
# between runs, outside the repository copy that tests/vm/run.sh replaces each time.

MGW_TEST_CACHE="${MGW_TEST_CACHE:-/var/tmp/mgw-test-cache}"

# starts the mock and exports MGW_TEST_GITHUB_API; call in setup_file
startGithubMock() {
  local port_file="$BATS_FILE_TMPDIR/github_mock.port" i=0
  python3 "$BATS_TEST_DIRNAME/github_mock.py" "$port_file" "$MGW_TEST_CACHE" &
  export GITHUB_MOCK_PID=$!
  while [ ! -s "$port_file" ]; do
    sleep 0.05
    i=$((i + 1))
    [ "$i" -lt 100 ] || return 1
  done
  export MGW_TEST_GITHUB_API="http://127.0.0.1:$(cat "$port_file")"
}

# call in teardown_file
stopGithubMock() {
  kill "$GITHUB_MOCK_PID" 2> /dev/null || true
}
