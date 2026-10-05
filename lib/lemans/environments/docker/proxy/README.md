# Allowlist proxy

This is an HTTP proxy that lets clients reach the allowed hosts only. The Docker backend runs it for the `allowlist` network mode.

The proxy supports two request types:

- `CONNECT host:port` tunnels (https).
- Absolute-form requests (`GET http://host/path`) for plain http.

The proxy refuses a host that is not on the list with `403 Forbidden`. Host names must match exactly. IP ranges are not supported.

## How the Docker backend uses it

1. Lemans puts the task container on an internal network. An internal network has no route out.
2. Lemans connects the proxy container to the internal network and to `bridge`.
3. Lemans sets `http_proxy` and `https_proxy` for each command in the task container.

A tool that ignores the proxy variables cannot reach the network.

When the allowed hosts change, lemans replaces the proxy container.

## Run it standalone

Build the image:

```sh
docker build --tag lemans-proxy lib/lemans/environments/docker/proxy
```

Start the proxy. Give the allowed hosts as arguments:

```sh
docker run --rm --publish 3128:3128 lemans-proxy rubygems.org index.rubygems.org
```

Send requests through it:

```sh
curl --proxy http://localhost:3128 https://rubygems.org   # allowed
curl --proxy http://localhost:3128 https://example.com    # 403 Forbidden
```

To run it without Docker, use Ruby 3.4 or later:

```sh
ruby lib/lemans/environments/docker/proxy/server.rb rubygems.org
```

The `PORT` variable changes the listen port. The default port is 3128.
