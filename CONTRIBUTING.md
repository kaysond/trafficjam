# Contributing
Pull requests are welcome. Please submit them to the `develop` branch, and ensure you're rebased to the latest changes in the repo.

Consider familiarizing yourself with trafficjam's [architecture](ARCHITECTURE.md) before getting started.

Please run the tests before submitting a PR. There are two dependencies for testing: [`bats`](https://github.com/bats-core/bats-core) (v1.2.1) and [`shellcheck`](https://github.com/koalaman/shellcheck) (v0.7.0 is used in CI, but newer versions are fine too). The tests can be run with `bats test/test.bats`

For information on how `trafficjam` and its tests are structured, please see [ARCHITECTURE.md](architecture.md)

## Style
Please follow the coding style that is used. Since this is a bash script, use tabs for indentation. For readability and ease of understanding, use long forms of arguments where possible.