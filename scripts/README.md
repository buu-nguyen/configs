# How to use
## Setup GitHub
```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/buu-nguyen/configs/HEAD/scripts/setup-github.sh)"
```

## Setup UPS
- Server
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/buu-nguyen/configs/HEAD/scripts/setup-ups.sh)" -- server
```

- Client
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/buu-nguyen/configs/HEAD/scripts/setup-ups.sh)" -- client --host 10.10.10.1
```
