# multicommerce-setup

Public bootstrap script for [MultiCommerce](https://github.com/tonykieu/multicommerce) Linux servers.

```sh
curl -fsSL https://raw.githubusercontent.com/tonykieu/multicommerce-setup/main/setup-server.sh | bash -s -- --dir /opt/multicommerce --start
```

The script clones the private MultiCommerce repo — configure GitHub access on the server (SSH deploy key or HTTPS credential) before running.

See `setup-server.sh --help` for options.
